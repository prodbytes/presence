import 'dart:async';

import 'camera_source.dart';

/// A single recording in progress.
abstract class PoolRecorder {
  /// When recording actually began.
  DateTime get startedAt;

  /// Stops recording and returns a URL for the finished file.
  Future<String> finish();

  /// Stops recording and throws the data away.
  void discard();
}

/// Keeps a camera always recording, so a clip can include the moments
/// before it was requested.
///
/// Browser recordings can't be trimmed or joined, so the pool overlaps
/// several recorders instead: a new one starts every [preRoll] / 2, and each
/// is discarded after 2 × [preRoll]. At any moment at least two recorders
/// are older than [preRoll]. A clip request stops one of them, which gives
/// the "before" video immediately, and holds another until the "after"
/// period ends, which gives the whole clip as one continuous file. Clips are
/// cut to the exact window by seeking, using the recorded start times.
///
/// Call [tick] regularly (about once a second).
class RecorderPool {
  RecorderPool({
    required this._startRecorder,
    required this._preRoll,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final PoolRecorder Function() _startRecorder;
  final Duration Function() _preRoll;
  final DateTime Function() _now;

  final List<_Entry> _entries = [];
  DateTime? _lastStart;
  bool _closed = false;

  /// Number of recorders currently running (for tests and diagnostics).
  int get activeCount => _entries.length;

  Duration get _startInterval => _preRoll() ~/ 2;
  Duration get _maxAge => _preRoll() * 2;

  void tick() {
    if (_closed) return;
    final now = _now();

    for (final entry in List.of(_entries)) {
      final hold = entry.holdUntil;
      if (hold != null) {
        if (!now.isBefore(hold)) _release(entry);
      } else if (now.difference(entry.recorder.startedAt) > _maxAge) {
        _entries.remove(entry);
        entry.recorder.discard();
      }
    }

    final last = _lastStart;
    if (last == null || now.difference(last) >= _startInterval) {
      _entries.add(_Entry(_startRecorder()));
      _lastStart = now;
    }
  }

  ClipCapture requestClip({required Duration before, required Duration after}) {
    if (_closed || _entries.isEmpty) return ClipCapture.unsupported;
    final now = _now();
    final windowStart = now.subtract(before);
    final windowEnd = now.add(after);

    // Oldest first.
    final byAge = List.of(_entries)
      ..sort((a, b) => a.recorder.startedAt.compareTo(b.recorder.startedAt));
    bool coversWindow(_Entry e) => !e.recorder.startedAt.isAfter(windowStart);

    // The full clip comes from the oldest recorder, which covers the most
    // history. It may already be held by an earlier clip; holds just extend.
    final full = byAge.first;
    final fullCompleter = Completer<ClipMedia?>();
    full.pending.add(
      _Pending(fullCompleter, windowStart: windowStart, windowEnd: windowEnd),
    );
    final hold = full.holdUntil;
    if (hold == null || hold.isBefore(windowEnd)) full.holdUntil = windowEnd;

    // The immediate "before" preview comes from another recorder that isn't
    // held: preferably the youngest one that still covers the whole window.
    final free = byAge.where((e) => e != full && e.holdUntil == null).toList();
    final covering = free.where(coversWindow).toList();
    final preview = covering.isNotEmpty
        ? covering.last
        : (free.isNotEmpty ? free.first : null);

    Future<ClipMedia?> past;
    if (preview == null) {
      past = Future.value();
    } else {
      _entries.remove(preview);
      final startedAt = preview.recorder.startedAt;
      past = preview.recorder.finish().then(
        (url) => ClipMedia(
          url: url,
          start: _offset(startedAt, windowStart),
          end: _offset(startedAt, now),
        ),
      );
    }

    return ClipCapture(past: past, full: fullCompleter.future);
  }

  /// Stops every recorder. Pending clips are finished with what was recorded.
  void close() {
    _closed = true;
    for (final entry in List.of(_entries)) {
      if (entry.pending.isEmpty) {
        _entries.remove(entry);
        entry.recorder.discard();
      } else {
        _release(entry);
      }
    }
  }

  void _release(_Entry entry) {
    _entries.remove(entry);
    final startedAt = entry.recorder.startedAt;
    entry.recorder.finish().then(
      (url) {
        for (final p in entry.pending) {
          p.completer.complete(
            ClipMedia(
              url: url,
              start: _offset(startedAt, p.windowStart),
              end: _offset(startedAt, p.windowEnd),
            ),
          );
        }
      },
      onError: (Object e, StackTrace s) {
        for (final p in entry.pending) {
          p.completer.completeError(e, s);
        }
      },
    );
  }

  /// Offset of [t] into a recording that began at [startedAt], never negative.
  static Duration _offset(DateTime startedAt, DateTime t) {
    final d = t.difference(startedAt);
    return d.isNegative ? Duration.zero : d;
  }
}

class _Entry {
  _Entry(this.recorder);

  final PoolRecorder recorder;
  DateTime? holdUntil;
  final List<_Pending> pending = [];
}

class _Pending {
  _Pending(
    this.completer, {
    required this.windowStart,
    required this.windowEnd,
  });

  final Completer<ClipMedia?> completer;
  final DateTime windowStart;
  final DateTime windowEnd;
}
