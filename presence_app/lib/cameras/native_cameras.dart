import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../clips.dart';
import 'camera_source.dart';

/// The Android camera layer (`PresenceCamerasPlugin` in Kotlin): each camera
/// is always recording into an in-memory ring buffer, and clips are written
/// from it as MP4 files.
const _channel = MethodChannel('presence/cameras');

/// The phone's cameras, one open at a time (most phones can't run two),
/// each always recording.
class DeviceCameras implements CameraBackend {
  @override
  Future<List<CameraDevice>> listCameras() async {
    final permissions = Map<String, Object?>.from(
      await _channel.invokeMethod<Map<Object?, Object?>>(
            'requestPermissions',
          ) ??
          const {},
    );
    if (permissions['camera'] != true) throw const CameraAccessDenied();

    final listed = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listCameras',
    );
    return [
      for (final raw in listed ?? const <Map<Object?, Object?>>[])
        CameraDevice(
          id: raw['id']! as String,
          label: raw['label']! as String,
          facing: raw['front'] == true ? CameraFacing.front : CameraFacing.back,
        ),
    ];
  }

  @override
  Future<CameraSource> open(
    CameraDevice device,
    Duration Function() preRoll,
  ) async {
    final opened = await _channel.invokeMapMethod<String, Object?>('open', {
      'id': device.id,
      'preRollMs': preRoll().inMilliseconds,
    });
    return _AndroidCameraSource(device.id, device.label, opened!, preRoll);
  }
}

class CameraAccessDenied implements Exception {
  const CameraAccessDenied();

  @override
  String toString() => 'Camera permission was denied. Allow it in Settings.';
}

class _AndroidCameraSource implements CameraSource {
  _AndroidCameraSource(
    this.id,
    this.label,
    Map<String, Object?> opened,
    this._preRoll,
  ) : _textureId = opened['textureId']! as int,
      _width = opened['width']! as int,
      _height = opened['height']! as int,
      _sensorOrientation = opened['sensorOrientation']! as int,
      _lastPreRoll = _preRoll() {
    // Keep the ring buffer's history in step with the settings.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final preRoll = _preRoll();
      if (preRoll != _lastPreRoll) {
        _lastPreRoll = preRoll;
        _invoke<void>('setPreRoll', {'preRollMs': preRoll.inMilliseconds});
      }
    });
  }

  @override
  final String id;

  @override
  final String label;

  final int _textureId;
  final int _width;
  final int _height;
  final int _sensorOrientation;
  final Duration Function() _preRoll;
  Duration _lastPreRoll;
  late final Timer _ticker;

  @override
  bool get supportsVideo => true;

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?> args = const {},
  ]) => _channel.invokeMethod<T>(method, {'id': id, ...args});

  @override
  Widget buildPreview(BuildContext context) {
    // Camera frames arrive in sensor orientation; turn them upright for a
    // phone held in its natural (portrait) orientation.
    final turns = _sensorOrientation ~/ 90;
    final aspect = turns.isOdd ? _height / _width : _width / _height;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: RotatedBox(
          quarterTurns: turns,
          child: Texture(textureId: _textureId),
        ),
      ),
    );
  }

  @override
  Future<void> setBrightness(double ev) =>
      _invoke<void>('setBrightness', {'ev': ev});

  @override
  Future<Uint8List?> captureFrame() async {
    try {
      return await _invoke<Uint8List>('captureFrame');
    } on PlatformException {
      return null;
    }
  }

  @override
  ClipCapture requestClip({required Duration before, required Duration after}) {
    final token = _invoke<int>('requestClip', {
      'beforeMs': before.inMilliseconds,
      'afterMs': after.inMilliseconds,
    });
    Future<ClipMedia?> part(String method) async {
      final t = await token;
      if (t == null) return null;
      final written = await _channel.invokeMapMethod<String, Object?>(method, {
        'id': id,
        'token': t,
      });
      if (written == null) return null;
      return ClipMedia(
        url: written['path']! as String,
        start: Duration(milliseconds: written['startMs']! as int),
        end: Duration(milliseconds: written['endMs']! as int),
        mimeType: written['mimeType'] as String? ?? 'video/mp4',
      );
    }

    return ClipCapture(past: part('clipPast'), full: part('clipFull'));
  }

  @override
  Future<void> dispose() async {
    _ticker.cancel();
    // Replies once the camera is fully closed, so the next can open.
    await _invoke<void>('close');
  }
}

/// Plays a clip: the "before" recording first, then, once it has been
/// recorded, continues into the full clip at the moment of the press.
/// Mirrors the web player, on `video_player` (ExoPlayer).
class ClipPlayerView extends StatefulWidget {
  const ClipPlayerView({super.key, required this.clip});

  final VideoClip clip;

  @override
  State<ClipPlayerView> createState() => _ClipPlayerViewState();
}

class _ClipPlayerViewState extends State<ClipPlayerView> {
  static const _endSlack = Duration(milliseconds: 30);

  VideoPlayerController? _controller;
  ClipMedia? _current;
  bool _onFull = false;
  bool _waiting = false;
  bool _loadFailed = false;

  VideoClip get _clip => widget.clip;

  @override
  void initState() {
    super.initState();
    _clip.addListener(_onClipChanged);
    _start();
  }

  void _start() {
    final full = _clip.full;
    final past = _clip.past;
    if (full != null) {
      _load(full, full.start, onFull: true);
    } else if (past != null) {
      _load(past, past.start, onFull: false);
    } else {
      setState(() => _waiting = true);
    }
  }

  Future<void> _load(
    ClipMedia media,
    Duration at, {
    required bool onFull,
  }) async {
    setState(() {
      _current = media;
      _onFull = onFull;
      _waiting = false;
    });
    final VideoPlayerController controller;
    try {
      final path = await media.resolveUrl();
      controller = VideoPlayerController.file(File(path));
      await controller.initialize();
    } catch (_) {
      if (mounted && _current == media) setState(() => _loadFailed = true);
      return;
    }
    if (!mounted || _current != media) {
      controller.dispose();
      return;
    }
    final old = _controller;
    await controller.seekTo(at);
    controller.addListener(_onTick);
    await controller.play();
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _controller = controller);
    old?.removeListener(_onTick);
    old?.dispose();
  }

  void _onTick() {
    final controller = _controller;
    final media = _current;
    if (controller == null || media == null) return;
    final value = controller.value;
    if (value.isPlaying &&
        (value.position >= media.end - _endSlack || value.isCompleted)) {
      _reachedEnd();
    }
    // Rebuild for the play/pause overlay.
    if (mounted) setState(() {});
  }

  void _reachedEnd() {
    final controller = _controller!;
    if (_onFull) {
      controller
        ..pause()
        ..seekTo(_current!.end);
      return;
    }
    if (_waiting) return;
    final full = _clip.full;
    if (full != null) {
      _continueIntoFull(full);
    } else {
      controller.pause();
      setState(() => _waiting = true);
    }
  }

  void _continueIntoFull(ClipMedia full) {
    final playedBefore = _clip.past?.length ?? _clip.before;
    _load(full, full.start + playedBefore, onFull: true);
  }

  void _onClipChanged() {
    final full = _clip.full;
    if (_current == null && !_onFull) {
      if (full != null || _clip.past != null) _start();
    } else if (_waiting && full != null) {
      _continueIntoFull(full);
    }
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    final media = _current;
    if (controller == null || media == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      // Replaying after the end starts the clip over.
      if (_onFull && controller.value.position >= media.end - _endSlack) {
        await controller.seekTo(media.start);
      }
      await controller.play();
    }
  }

  @override
  void dispose() {
    _clip.removeListener(_onClipChanged);
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null && controller.value.isInitialized)
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
          if (controller != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlay,
                child: AnimatedOpacity(
                  opacity: controller.value.isPlaying ? 0 : 1,
                  duration: const Duration(milliseconds: 150),
                  child: const Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      size: 64,
                      color: Color(0xFFFABD2F),
                    ),
                  ),
                ),
              ),
            ),
          if (_loadFailed)
            const Center(
              child: Text(
                "Couldn't load this clip",
                style: TextStyle(color: Color(0xFFFB4934)),
              ),
            ),
          if (_waiting)
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Recording the next ${_clip.after.inSeconds} s…',
                  style: const TextStyle(color: Color(0xFFEBDBB2)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
