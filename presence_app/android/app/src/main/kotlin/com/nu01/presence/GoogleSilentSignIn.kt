package com.nu01.presence

import android.content.Context
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException

/**
 * Signs a known Google account back in with no UI, for the unattended
 * phone: after a restart, and to refresh its ID token.
 *
 * Credential Manager's quiet check (what `google_sign_in` uses) shows
 * Google's account chooser as soon as more than one account on the phone
 * has signed in to the app, and nobody is there to tap it. So the app
 * remembers which account signed in ([remember], cleared by [forget] on
 * sign-out) and asks Play services' sign-in for that account only
 * ([signIn]): it returns a fresh ID token, without UI, while the account
 * still grants the app.
 */
@Suppress("DEPRECATION") // The legacy client is the only one that can name the account.
object GoogleSilentSignIn {
    /** Play services' CommonStatusCodes.SIGN_IN_REQUIRED. */
    const val SIGN_IN_REQUIRED = 4

    private const val PREFS = "presence"
    private const val ACCOUNT = "googleAccount"

    /** The email of the account that last signed in, or null. */
    fun remembered(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(ACCOUNT, null)

    fun remember(context: Context, email: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(ACCOUNT, email).apply()
    }

    /** Forgets the account here and in Play services' sign-in. */
    fun forget(context: Context, serverClientId: String?, done: () -> Unit) {
        val email = remembered(context)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(ACCOUNT).apply()
        if (email == null || serverClientId.isNullOrEmpty()) {
            done()
            return
        }
        client(context, email, serverClientId).signOut().addOnCompleteListener { done() }
    }

    /**
     * Signs [email] in without UI, with an ID token for [serverClientId];
     * [done] gets the account (id, email, displayName, photoUrl, idToken),
     * or, when it can't, `{failure: <Play services status code>}` (-1 when
     * there's none): 4 (SIGN_IN_REQUIRED) means the account must sign in
     * with UI; anything else (a network or internal error) may pass on a
     * retry. Never logs the token.
     */
    fun signIn(
        context: Context,
        email: String,
        serverClientId: String,
        done: (Map<String, String?>?) -> Unit,
    ) {
        val task = try {
            client(context, email, serverClientId).silentSignIn()
        } catch (e: Exception) {
            FileLog.w("silent Google sign-in of $email could not start", e)
            done(mapOf("failure" to "-1"))
            return
        }
        task.addOnCompleteListener { t ->
            val account: GoogleSignInAccount? = if (t.isSuccessful) t.result else null
            val token = account?.idToken
            if (account == null || token == null || account.id == null) {
                val code = (t.exception as? ApiException)?.statusCode
                FileLog.w("silent Google sign-in of $email failed (status $code)")
                done(mapOf("failure" to "${code ?: -1}"))
                return@addOnCompleteListener
            }
            if (!account.email.equals(email, ignoreCase = true)) {
                // Never sign in as anyone else than the account asked for.
                FileLog.w("silent Google sign-in of $email returned another account")
                done(mapOf("failure" to "$SIGN_IN_REQUIRED"))
                return@addOnCompleteListener
            }
            FileLog.i("silent Google sign-in of $email succeeded")
            done(
                mapOf(
                    "id" to account.id,
                    "email" to account.email,
                    "displayName" to account.displayName,
                    "photoUrl" to account.photoUrl?.toString(),
                    "idToken" to token,
                ),
            )
        }
    }

    private fun client(context: Context, email: String, serverClientId: String) =
        GoogleSignIn.getClient(
            context,
            GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
                .requestIdToken(serverClientId)
                .requestEmail()
                .setAccountName(email)
                .build(),
        )
}
