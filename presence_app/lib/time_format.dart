/// The app's short time and date formats, in one place.
library;

/// [n] with a leading zero below 10 ("07").
String twoDigits(int n) => n.toString().padLeft(2, '0');

/// The time of day with seconds, "14:05:09": on event cards, log lines and
/// health checks.
String formatEventTime(DateTime t) =>
    '${twoDigits(t.hour)}:${twoDigits(t.minute)}:${twoDigits(t.second)}';

/// The time of day without seconds, "14:05".
String formatHourMinute(DateTime t) =>
    '${twoDigits(t.hour)}:${twoDigits(t.minute)}';

/// The date, "2026-10-06".
String formatDate(DateTime t) =>
    '${t.year}-${twoDigits(t.month)}-${twoDigits(t.day)}';

/// [seconds] as minutes and seconds, "4:59" or "0:42".
String formatMinutesSeconds(int seconds) =>
    '${seconds ~/ 60}:${twoDigits(seconds % 60)}';
