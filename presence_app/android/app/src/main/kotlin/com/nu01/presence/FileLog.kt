package com.nu01.presence

import android.content.Context
import android.os.Process
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * The app's log, kept in files on the phone so it can be read after the
 * fact (the logcat buffer only holds minutes to hours): every message the
 * app logs (Dart's, through `presence/device` `log`, and the native side's)
 * goes to logcat and to `logs/presence-YYYY-MM-DD.log` (secrets blanked:
 * [redact]) in the app's
 * external files directory, which adb can read without root:
 * `/sdcard/Android/data/com.nu01.presence/files/logs/` (see
 * `scripts/android-log.sh --pull`). The latest [KEEP_DAYS] days are kept.
 *
 * At each start it also saves what logcat still holds of the app (Android
 * shows an app only its own lines), `logcat-before-<time>.txt`, so the
 * minutes before a crash or kill survive the restart.
 */
object FileLog {
    private const val TAG = "Presence"
    private const val KEEP_DAYS = 7
    private const val KEEP_LOGCATS = 5

    private val writer = Executors.newSingleThreadExecutor()
    private val day = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    private val time = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)

    @Volatile private var dir: File? = null

    /** Where the files go; null until [init]. */
    val directory: File? get() = dir

    /** Opens the log directory, once per process, and saves logcat's lines. */
    @Synchronized
    fun init(context: Context, startedBy: String) {
        if (dir != null) return
        val logs = File(context.getExternalFilesDir(null) ?: context.filesDir, "logs")
        logs.mkdirs()
        dir = logs
        i("process ${Process.myPid()} started ($startedBy)")
        writer.execute {
            prune(logs)
            saveLogcat(logs)
        }
    }

    fun i(message: String) = write('I', message, null)

    fun w(message: String, error: Throwable? = null) = write('W', message, error)

    fun e(message: String, error: Throwable? = null) = write('E', message, error)

    /** A line from Dart's log (already in logcat, as tag `flutter`). */
    fun fromDart(message: String, error: Boolean) =
        append(line(if (error) 'E' else 'I', "[dart] $message"))

    /**
     * Writes [message] at once, on this thread: for a crash, when the
     * process is about to die and queued writes would be lost.
     */
    fun now(message: String, error: Throwable) {
        Log.e(TAG, message, error)
        val text = line('E', "$message\n${Log.getStackTraceString(error)}")
        runCatching { file()?.appendText(text) }
    }

    private fun write(level: Char, message: String, error: Throwable?) {
        when (level) {
            'E' -> Log.e(TAG, message, error)
            'W' -> Log.w(TAG, message, error)
            else -> Log.i(TAG, message)
        }
        val text = if (error == null) message else "$message\n${Log.getStackTraceString(error)}"
        append(line(level, text))
    }

    private fun line(level: Char, text: String) =
        synchronized(time) { "${time.format(Date())} $level ${redact(text)}\n" }

    /**
     * Secrets an error message may carry (a presigned URL's signature and
     * session token, a bearer token), blanked: on Android 9 other apps with
     * the storage permission can read these files.
     */
    private val secrets = Regex(
        "((?:X-Amz-[A-Za-z-]+|[A-Za-z]*[Tt]oken|[Ss]ignature|[Cc]redential|[Kk]ey)=)[^&\\s\"']+|(Bearer )\\S+",
    )

    fun redact(text: String) = secrets.replace(text) { m ->
        (m.groups[1]?.value ?: m.groups[2]?.value ?: "") + "…"
    }

    private fun append(text: String) {
        writer.execute { runCatching { file()?.appendText(text) } }
    }

    private fun file(): File? {
        val logs = dir ?: return null
        return File(logs, "presence-${synchronized(day) { day.format(Date()) }}.log")
    }

    private fun prune(logs: File) {
        val files = logs.listFiles() ?: return
        files.filter { it.name.startsWith("presence-") }
            .sortedByDescending { it.name }
            .drop(KEEP_DAYS)
            .forEach { it.delete() }
        files.filter { it.name.startsWith("logcat-before-") }
            .sortedByDescending { it.name }
            .drop(KEEP_LOGCATS - 1)
            .forEach { it.delete() }
    }

    /** What logcat holds of this app, from before this process started. */
    private fun saveLogcat(logs: File) {
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val out = File(logs, "logcat-before-$stamp.txt")
        runCatching {
            val process = ProcessBuilder(
                "logcat", "-d", "-v", "threadtime", "-b", "main,system,crash", "-t", "20000",
            ).redirectErrorStream(true).start()
            out.bufferedWriter().use { w ->
                process.inputStream.bufferedReader().forEachLine { w.write(redact(it)); w.newLine() }
            }
            process.waitFor()
        }.onFailure { Log.w(TAG, "Presence: could not save logcat: $it") }
    }
}
