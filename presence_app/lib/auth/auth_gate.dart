import 'package:flutter/material.dart';

import 'auth_service.dart';

/// What the app shows depends on sign-in: while the launch check runs, a
/// splash; signed in, the app ([signedIn]); signed out, only the sign-in
/// screen.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.auth, required this.signedIn});

  final AuthService auth;
  final Widget signedIn;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (auth.user != null) return signedIn;
        if (auth.checking) return const _Splash();
        return SignInScreen(auth: auth);
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(
    key: Key('auth-checking'),
    body: Center(child: _Logo()),
  );
}

/// The only screen while signed out: the app's name and a Google sign-in
/// button (Google's own on web).
class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = auth.error;
    return Scaffold(
      key: const Key('sign-in-screen'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _Logo(),
                  const SizedBox(height: 24),
                  Text(
                    'Presence',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in to continue',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  if (!auth.available)
                    Text(
                      auth.unavailableReason ?? 'Sign-in is unavailable.',
                      key: const Key('sign-in-unavailable'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    )
                  else
                    auth.buildSignInButton() ??
                        FilledButton.icon(
                          key: const Key('google-sign-in'),
                          icon: const Icon(Icons.login),
                          label: const Text('Sign in with Google'),
                          onPressed: auth.signIn,
                        ),
                  if (error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: Image.asset('assets/icon/icon.png', width: 112, height: 112),
  );
}
