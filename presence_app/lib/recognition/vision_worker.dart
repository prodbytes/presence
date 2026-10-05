import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'image.dart';
import 'runtime_native.dart';
import 'vision.dart';

/// Opens the models in the worker, from the file of each of
/// [VisionModels.assets] (by asset). A top-level or static function: it's
/// sent to the worker.
typedef VisionOpener = Future<Vision> Function(Map<String, String> files);

/// [Vision] in one long-lived background isolate that owns the models: it
/// loads them, resizes each frame to each model's input, runs them and
/// decodes their outputs, so the app's isolate only sends frames and gets
/// back who's on them. Started on the first frame, and stopped (its memory
/// freed) after [idleTimeout] without one, or on [release].
class WorkerVision extends Vision {
  WorkerVision({
    Future<Map<String, String>> Function()? files,
    this.open = openVisionModels,
    this.idleTimeout = defaultIdleTimeout,
  }) : _files = files ?? modelFiles;

  static const Duration defaultIdleTimeout = Duration(seconds: 60);

  final Future<Map<String, String>> Function() _files;

  /// Opens the models, in the worker.
  final VisionOpener open;
  final Duration idleTimeout;

  Future<_Worker>? _worker;
  Timer? _idle;
  int _busy = 0;

  /// Whether the worker is up (or starting).
  bool get running => _worker != null;

  /// Starts the worker, if it isn't already. Throws if the models can't
  /// load.
  Future<void> start() async {
    await _start();
    _idleLater();
  }

  Future<_Worker> _start() {
    final current = _worker;
    if (current != null) return current;
    final worker = _worker = _Worker.spawn(_files, open);
    // A worker that failed to start is tried again next time.
    worker.then(
      (_) {},
      onError: (Object _) {
        if (identical(_worker, worker)) _worker = null;
      },
    );
    return worker;
  }

  @override
  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    bool faces = true,
    bool subjects = true,
    Set<SeenKind>? kinds,
    int? maxSeen,
  }) async {
    _idle?.cancel();
    _busy++;
    try {
      final worker = await _start();
      return await worker.analyse(
        image,
        faces: faces,
        subjects: subjects,
        kinds: kinds,
        maxSeen: maxSeen,
      );
    } finally {
      _busy--;
      _idleLater();
    }
  }

  void _idleLater() {
    _idle?.cancel();
    if (_busy == 0) _idle = Timer(idleTimeout, release);
  }

  /// Stops the worker, freeing the models' memory; the next frame starts
  /// it again. Frames being analysed fail.
  @override
  void release() {
    _idle?.cancel();
    _idle = null;
    final worker = _worker;
    _worker = null;
    worker?.then((w) => w.close(), onError: (Object _) {});
  }

  static Future<Map<String, String>>? _modelFiles;

  /// The models' assets as files (`models/` in the app's support
  /// directory, rewritten if their size changed; checked once per run of
  /// the app): LiteRT maps a file, where it would keep a copy of bytes for
  /// good.
  static Future<Map<String, String>> modelFiles() =>
      _modelFiles ??= _copyModels()
        // Tried again next time if it failed.
        ..then((_) {}, onError: (Object _) => _modelFiles = null);

  static Future<Map<String, String>> _copyModels() async {
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/models',
    );
    await dir.create(recursive: true);
    final files = <String, String>{};
    for (final asset in VisionModels.assets) {
      final data = await rootBundle.load(asset);
      final file = File('${dir.path}/${asset.split('/').last}');
      if (!await file.exists() || await file.length() != data.lengthInBytes) {
        // Whole or not at all: written aside, then moved in place.
        final part = File('${file.path}.part');
        await part.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        await part.rename(file.path);
      }
      files[asset] = file.path;
    }
    return files;
  }
}

/// The real models, with LiteRT, in the worker.
Future<Vision> openVisionModels(Map<String, String> files) {
  final runtime = PlatformRuntime();
  return VisionModels.open((asset) async => runtime.loadFile(files[asset]!));
}

/// The app's side of one worker isolate.
class _Worker {
  _Worker._(this._port, this._inbox, this._events) {
    _events.listen(
      _onMessage,
      onDone: () => _failAll(StateError('Recognition worker stopped')),
    );
  }

  final SendPort _port;
  final ReceivePort _inbox;
  final Stream<Object?> _events;
  final _pending = <int, Completer<FrameAnalysis>>{};
  var _next = 0;
  var _closed = false;

  static Future<_Worker> spawn(
    Future<Map<String, String>> Function() files,
    VisionOpener open,
  ) async {
    // Found here: assets need the app's isolate.
    final paths = await files();
    final inbox = ReceivePort('recognition');
    final events = inbox.asBroadcastStream();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        (inbox.sendPort, paths, open),
        debugName: 'recognition',
        onExit: inbox.sendPort,
        onError: inbox.sendPort,
      );
    } catch (_) {
      inbox.close();
      rethrow;
    }
    final first = await events.first;
    if (first is SendPort) return _Worker._(first, inbox, events);
    inbox.close();
    isolate.kill(priority: Isolate.immediate);
    throw StateError('Recognition models failed to load: ${_error(first)}');
  }

  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    required bool faces,
    required bool subjects,
    Set<SeenKind>? kinds,
    int? maxSeen,
  }) {
    if (_closed) return Future.error(StateError('Recognition worker stopped'));
    final id = _next++;
    final done = _pending[id] = Completer<FrameAnalysis>();
    _port.send((
      id,
      TransferableTypedData.fromList([image.pixels]),
      image.width,
      image.height,
      faces,
      subjects,
      kinds,
      maxSeen,
    ));
    return done.future;
  }

  void _onMessage(Object? message) {
    switch (message) {
      case (final int id, final FrameAnalysis analysis, null):
        _pending.remove(id)?.complete(analysis);
      case (final int id, null, final String error):
        _pending.remove(id)?.completeError(StateError(error));
      default:
        // It exited (null) or crashed ([error, stack]).
        close();
        _failAll(StateError('Recognition worker stopped: ${_error(message)}'));
    }
  }

  void _failAll(Object error) {
    for (final done in _pending.values) {
      done.completeError(error);
    }
    _pending.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // Asks it to free the models (native memory, which killing it would
    // leak) and exit, once done with any frame it's on.
    _port.send(null);
    _inbox.close();
    _failAll(StateError('Recognition worker stopped'));
  }

  static String _error(Object? message) => switch (message) {
    null => 'exited',
    [final error, _] => '$error',
    _ => '$message',
  };
}

/// The worker isolate: opens the models, then analyses each frame sent
/// until told to stop (null).
Future<void> _workerMain(
  (SendPort, Map<String, String>, VisionOpener) args,
) async {
  final (host, files, open) = args;
  final Vision vision;
  try {
    vision = await open(files);
  } catch (e) {
    host.send('$e');
    return;
  }
  final inbox = ReceivePort();
  host.send(inbox.sendPort);
  await for (final message in inbox) {
    if (message case (
      final int id,
      final TransferableTypedData pixels,
      final int width,
      final int height,
      final bool faces,
      final bool subjects,
      final Set<SeenKind>? kinds,
      final int? maxSeen,
    )) {
      try {
        final analysis = await vision.analyse(
          RgbaImage(width, height, pixels.materialize().asUint8List()),
          faces: faces,
          subjects: subjects,
          kinds: kinds,
          maxSeen: maxSeen,
        );
        host.send((id, analysis, null));
      } catch (e) {
        host.send((id, null, '$e'));
      }
    } else {
      break;
    }
  }
  inbox.close();
  if (vision is VisionModels) vision.dispose();
  vision.release();
}
