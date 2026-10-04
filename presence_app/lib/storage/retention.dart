import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';

/// Deletes events older than the History setting (`HistoryConfig.keep`, two
/// weeks by default) from this device: once when the app loads, after the
/// saved history is restored, and then every [every] (3 h).
///
/// A changed setting applies on the next run, not while its slider is
/// dragged, so passing over "1 day" deletes nothing.
class EventRetention {
  EventRetention({
    required this.delete,
    required this.config,
    DateTime Function()? now,
    this.every = defaultEvery,
  }) : _now = now ?? DateTime.now;

  static const Duration defaultEvery = Duration(hours: 3);

  /// Deletes the events from before a cutoff, returning how many went
  /// (`Persistence.deleteEventsBefore`).
  final Future<int> Function(DateTime cutoff) delete;
  final ConfigController config;
  final Duration every;
  final DateTime Function() _now;

  Timer? _timer;
  Future<int>? _running;

  /// Runs now, then every [every].
  void start() {
    _timer?.cancel();
    run().ignore();
    _timer = Timer.periodic(every, (_) => run().ignore());
  }

  /// Deletes the events from before now minus the setting; one run at a
  /// time. Returns how many went.
  Future<int> run() {
    if (_running case final running?) return running;
    final running = _run();
    _running = running;
    running.whenComplete(() {
      if (identical(_running, running)) _running = null;
    }).ignore();
    return running;
  }

  Future<int> _run() async {
    try {
      final cutoff = _now().subtract(config.config.history.keep);
      return await delete(cutoff);
    } catch (e) {
      debugPrint('Presence: could not delete old events: $e');
      return 0;
    }
  }

  void dispose() => _timer?.cancel();
}
