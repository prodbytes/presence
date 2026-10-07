import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../clips.dart';
import 'camera_source.dart';
import 'clip_player_controller.dart';

/// The native camera layer, `PresenceCamerasPlugin` in Kotlin (Android) and
/// Swift (iOS), with the same channel API: each camera is always recording
/// into an in-memory ring buffer, and clips are written from it as MP4 files.
const _channel = MethodChannel('presence/cameras');

/// 64×48 luma frames from every open camera, as `{id, luma}`.
final Stream<Map<Object?, Object?>> _motion = const EventChannel(
  'presence/motion',
).receiveBroadcastStream().cast<Map<Object?, Object?>>().asBroadcastStream();

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
    return _NativeCameraSource(device.id, device.label, opened!, preRoll);
  }
}

class CameraAccessDenied extends CameraUnavailable {
  const CameraAccessDenied()
    : super('Camera permission was denied. Allow it in Settings.');
}

class _NativeCameraSource implements CameraSource {
  _NativeCameraSource(
    this.id,
    this.label,
    Map<String, Object?> opened,
    this._preRoll,
  ) : _textureId = opened['textureId']! as int,
      _width = opened['width']! as int,
      _height = opened['height']! as int,
      _sensorOrientation = opened['sensorOrientation']! as int,
      _hasMotion = opened['motion'] == true,
      _mirror = opened['mirror'] == true,
      _lastPreRoll = _preRoll() {
    _lostEvents = _motion
        .where((e) => e['id'] == id && e['lost'] != null)
        .listen((e) {
          if (!_lost.isCompleted) _lost.complete(e['lost']! as String);
        });
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
  final bool _hasMotion;

  /// Mirror the preview (iOS front camera; Android's transform already does).
  final bool _mirror;

  @override
  Stream<Uint8List>? get motionFrames => _hasMotion
      ? _motion
            .where((e) => e['id'] == id && e['luma'] != null)
            .map((e) => e['luma']! as Uint8List)
      : null;

  final _lost = Completer<String>();
  late final StreamSubscription<Object?> _lostEvents;

  @override
  Future<String> get lost => _lost.future;
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
    // Camera2 sets a transform on the preview SurfaceTexture that turns the
    // image upright for the phone's natural (portrait) orientation, and
    // Flutter's Texture applies it: don't rotate again. Only the aspect
    // ratio needs swapping, since the buffers are in sensor orientation.
    // (Recordings don't get that transform; they carry a rotation flag.)
    final sideways = _sensorOrientation % 180 != 0;
    return Center(
      child: AspectRatio(
        aspectRatio: sideways ? _height / _width : _width / _height,
        child: Transform.flip(
          flipX: _mirror,
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
    _lostEvents.cancel();
    // Replies once the camera is fully closed, so the next can open.
    await _invoke<void>('close');
  }
}

/// Plays a clip: the full clip once it's recorded, and until then the
/// preview (the "before" part), on its own. When the full clip arrives it
/// replaces the preview at the same moment of the clip. Mirrors the web
/// player, on `video_player` (ExoPlayer).
class ClipPlayerView extends StatefulWidget {
  const ClipPlayerView({
    super.key,
    required this.clip,
    this.controller,
    this.startAt,
  });

  final VideoClip clip;

  /// Serves frame grabs (for tagging) while this player is mounted.
  final ClipPlayerController? controller;

  /// Opens paused at this point of the recording (as tags' `frameMs` are)
  /// instead of playing from the start.
  final Duration? startAt;

  @override
  State<ClipPlayerView> createState() => _ClipPlayerViewState();
}

class _ClipPlayerViewState extends State<ClipPlayerView> {
  static const _endSlack = Duration(milliseconds: 30);

  VideoPlayerController? _controller;

  /// The file [_controller] plays.
  String? _path;

  /// Counts loads: one finishing after a newer one began is stale.
  int _loadGeneration = 0;
  ClipMedia? _current;
  bool _onFull = false;
  bool _waiting = false;
  bool _loadFailed = false;

  /// Getting the recording ready: downloading it from the cloud when it
  /// hasn't come down yet.
  bool _loading = false;

  VideoClip get _clip => widget.clip;

  @override
  void initState() {
    super.initState();
    _clip.addListener(_onClipChanged);
    widget.controller?.attach(_captureFrame);
    _start();
  }

  /// Pauses, then asks the platform for the frame at the current position
  /// of the file being played (MediaMetadataRetriever / AVAssetImageGenerator).
  Future<CapturedFrame?> _captureFrame() async {
    final controller = _controller;
    final path = _path;
    if (controller == null || path == null) return null;
    await controller.pause();
    final position = controller.value.position;
    final jpeg = await _channel.invokeMethod<Uint8List>('frameAt', {
      'path': path,
      'ms': position.inMilliseconds,
      'maxWidth': ClipPlayerController.maxFrameWidth,
    });
    return jpeg == null ? null : CapturedFrame(jpeg: jpeg, position: position);
  }

  void _start() {
    final full = _clip.full;
    final past = _clip.past;
    final at = widget.startAt;
    if (full != null) {
      _load(full, startPosition(full, at), onFull: true, play: at == null);
    } else if (past != null) {
      _load(past, startPosition(past, at), onFull: false, play: at == null);
    } else {
      setState(() => _waiting = true);
    }
  }

  Future<void> _load(
    ClipMedia media,
    Duration at, {
    required bool onFull,
    bool play = true,
  }) async {
    setState(() {
      _current = media;
      _onFull = onFull;
      _waiting = false;
      _loading = true;
      _loadFailed = false;
    });
    // A newer load (or closing the player) makes this one stale: what it
    // made is disposed, and it changes nothing.
    final generation = ++_loadGeneration;
    bool stale() => !mounted || generation != _loadGeneration;
    VideoPlayerController? opening;
    final String path;
    try {
      path = await media.resolveUrl();
      if (stale()) return;
      opening = VideoPlayerController.file(File(path));
      await opening.initialize();
    } catch (_) {
      opening?.dispose();
      if (!stale()) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
      return;
    }
    final controller = opening;
    if (stale()) {
      controller.dispose();
      return;
    }
    setState(() => _loading = false);
    await controller.seekTo(at);
    if (stale()) {
      controller.dispose();
      return;
    }
    controller.addListener(_onTick);
    if (play) await controller.play();
    if (stale()) {
      controller
        ..removeListener(_onTick)
        ..dispose();
      return;
    }
    final old = _controller;
    setState(() {
      _controller = controller;
      _path = path;
    });
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
    controller
      ..pause()
      ..seekTo(_current!.end);
    // The preview is over; the full clip shows as soon as it's recorded.
    if (!_onFull && _clip.full == null) setState(() => _waiting = true);
  }

  /// Replaces the preview with the full clip, at the same moment of the
  /// clip. It plays on if the preview was playing, or had played to its end
  /// and was waiting for it.
  void _showFull(ClipMedia full) {
    final preview = _current;
    final value = _controller?.value;
    var into = preview == null || value == null
        ? Duration.zero
        : value.position - preview.start;
    if (into.isNegative) into = Duration.zero;
    if (into > full.length) into = full.length;
    _load(
      full,
      full.start + into,
      onFull: true,
      play: _waiting || (value?.isPlaying ?? true),
    );
  }

  void _onClipChanged() {
    final full = _clip.full;
    if (_current == null) {
      if (full != null || _clip.past != null) _start();
    } else if (!_onFull && full != null) {
      _showFull(full);
    }
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    final media = _current;
    if (controller == null || media == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      // Replaying after the end starts it over.
      if (controller.value.position >= media.end - _endSlack) {
        await controller.seekTo(media.start);
      }
      await controller.play();
    }
  }

  @override
  void dispose() {
    widget.controller?.detach(_captureFrame);
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
              child: LayoutBuilder(
                builder: (context, box) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _togglePlay,
                  // A tap plays and pauses; a long press tags whoever is there.
                  onLongPressStart: widget.controller?.onPictureTap == null
                      ? null
                      : (d) {
                          final fraction = ClipPlayerController.pictureFraction(
                            d.localPosition,
                            box.biggest,
                            controller.value.size,
                          );
                          if (fraction != null) {
                            widget.controller!.pictureTapped(fraction);
                          }
                        },
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
            ),
          if (_loading && !_loadFailed)
            const Center(
              key: Key('clip-loading'),
              child: CircularProgressIndicator(color: Color(0xFFFABD2F)),
            ),
          if (_loadFailed)
            const Center(
              child: Text(
                "Couldn't load this clip",
                style: TextStyle(color: Color(0xFFFB4934)),
              ),
            ),
          if (_current != null && !_onFull && !_waiting)
            const Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Preview',
                  key: Key('clip-preview'),
                  style: TextStyle(color: Color(0xFFEBDBB2)),
                ),
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
