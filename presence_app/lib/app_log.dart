import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One line of the [AppLog].
class LogEntry {
  const LogEntry(this.time, this.message, {this.error = false});

  final DateTime time;
  final String message;

  /// An uncaught error or a Flutter error, rather than a message.
  final bool error;
}

/// The app's latest log messages, kept in memory for the **Log** panel at
/// the end of Settings: every `debugPrint` and `print`, Flutter errors and
/// uncaught errors, once [capture] is installed.
class AppLog extends ChangeNotifier {
  AppLog({this.capacity = 500, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// The app's log, which [capture] writes to.
  static final AppLog instance = AppLog();

  /// How many entries are kept; older ones are dropped.
  final int capacity;

  final DateTime Function() _now;
  final _entries = ListQueue<LogEntry>();

  /// Oldest first.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Also called with every entry, to keep it beyond the app's memory (on
  /// Android, the log files on the phone: [persistToDevice]).
  void Function(LogEntry entry)? persist;

  void add(String message, {bool error = false}) {
    final entry = LogEntry(_now(), message, error: error);
    _entries.addLast(entry);
    persist?.call(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    // Messages can come mid-build (a debugPrint in a build method): tell
    // the listeners after the frame rather than during it.
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      notifyListeners();
    });
  }

  bool _scheduled = false;

  /// On Android, also writes every entry, from now and already logged, to
  /// the app's log files on the phone (`presence/device` `log`), which
  /// outlast restarts and crashes; `scripts/android-log.sh --pull` fetches
  /// them. Elsewhere, nothing changes. Needs the Flutter binding.
  void persistToDevice() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    const channel = MethodChannel('presence/device');
    void send(LogEntry e) => channel
        .invokeMethod<void>('log', {'message': e.message, 'error': e.error})
        .catchError((Object _) {});
    _entries.forEach(send);
    persist = send;
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// Runs [body] (the app) with everything it logs also added to
  /// [instance]: `debugPrint`, `print` (through the zone), Flutter errors
  /// and errors nothing caught. Each still goes where it went before.
  static void capture(void Function() body) {
    final log = instance;
    final printed = debugPrint;
    var reporting = false;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && !reporting) log.add(message);
      // Out of the zone, so its own `print` isn't logged twice.
      Zone.root.run(() => printed(message, wrapWidth: wrapWidth));
    };
    runZoned(
      () {
        final flutterError = FlutterError.onError;
        FlutterError.onError = (details) {
          log.add(
            '${details.exceptionAsString()}\n${details.stack ?? ''}'.trim(),
            error: true,
          );
          // Its report goes through debugPrint: already logged above.
          reporting = true;
          try {
            flutterError?.call(details);
          } finally {
            reporting = false;
          }
        };
        final platformError = PlatformDispatcher.instance.onError;
        PlatformDispatcher.instance.onError = (error, stack) {
          log.add('Uncaught: $error\n$stack'.trim(), error: true);
          return platformError?.call(error, stack) ?? false;
        };
        body();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          log.add(line);
          parent.print(zone, line);
        },
      ),
    );
  }
}
