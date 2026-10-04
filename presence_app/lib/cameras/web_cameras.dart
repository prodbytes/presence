import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../clips.dart';
import '../motion.dart';
import 'camera_source.dart';
import 'clip_player_controller.dart';
import 'recorder_pool.dart';
import 'webm_trim.dart';

/// The browser's cameras, one open at a time, each always recording.
class DeviceCameras implements CameraBackend {
  /// Whether microphone permission was granted; recordings then have audio.
  bool _microphone = false;

  @override
  Future<List<CameraDevice>> listCameras() async {
    final media = await _mediaDevices();
    // Browsers hide device labels (and sometimes devices) until the page has
    // permission, so ask once up front: camera and microphone together, so
    // there's a single prompt. Without a microphone, record video only.
    web.MediaStream probe;
    try {
      probe = await media
          .getUserMedia(
            web.MediaStreamConstraints(video: true.toJS, audio: true.toJS),
          )
          .toDart;
    } catch (_) {
      try {
        probe = await media
            .getUserMedia(web.MediaStreamConstraints(video: true.toJS))
            .toDart;
      } catch (e) {
        throw cameraUnavailable(e);
      }
    }
    _microphone = probe.getAudioTracks().toDart.isNotEmpty;
    // The browser's default camera is the one the probe opened: list it first.
    final defaultId = probe
        .getVideoTracks()
        .toDart
        .firstOrNull
        ?.getSettings()
        .deviceId;
    for (final track in probe.getTracks().toDart) {
      track.stop();
    }

    final devices = (await media.enumerateDevices().toDart).toDart
        .where((d) => d.kind == 'videoinput' && d.deviceId.isNotEmpty)
        .map(
          (d) => CameraDevice(
            id: d.deviceId,
            label: d.label.trim().isEmpty ? 'Camera' : d.label,
            facing: _facingFromLabel(d.label),
          ),
        )
        .toList();
    devices.sort(
      (a, b) => (a.id == defaultId ? 0 : 1) - (b.id == defaultId ? 0 : 1),
    );
    return devices;
  }

  @override
  Future<CameraSource> open(
    CameraDevice device,
    Duration Function() preRoll,
  ) async {
    final media = await _mediaDevices();
    web.MediaStreamConstraints constraints({required bool audio}) =>
        web.MediaStreamConstraints(
          video: web.MediaTrackConstraints(
            deviceId: {'exact': device.id}.jsify()!,
            // Up to 30 fps, allowed down to 10 in low light, like Android and
            // iOS. A hint: browsers pick what the camera supports.
            frameRate: {'ideal': 30, 'min': 10}.jsify()!,
          ),
          audio: audio.toJS,
        );
    web.MediaStream stream;
    try {
      try {
        stream = await media
            .getUserMedia(constraints(audio: _microphone))
            .toDart;
      } catch (_) {
        if (!_microphone) rethrow;
        // Microphone busy or gone: record video only.
        stream = await media.getUserMedia(constraints(audio: false)).toDart;
      }
    } catch (e) {
      throw cameraUnavailable(e);
    }
    return WebCameraSource(device.id, device.label, stream, preRoll);
  }

  /// The page's `navigator.mediaDevices`, after checking the camera can be
  /// asked for at all. Browsers leave it undefined on pages that aren't
  /// secure (plain HTTP other than localhost), which would otherwise surface
  /// as a TypeError. A camera permission the user already denied is
  /// reported without prompting.
  static Future<web.MediaDevices> _mediaDevices() async {
    final navigator = web.window.navigator as JSObject;
    if (!web.window.isSecureContext || !navigator.has('mediaDevices')) {
      throw const CameraUnavailable(
        'The camera only works on a secure page. Open Presence over HTTPS.',
      );
    }
    if (await _cameraPermission() == 'denied') {
      throw const CameraUnavailable(_blocked);
    }
    return web.window.navigator.mediaDevices;
  }

  /// "granted", "denied" or "prompt"; null where the browser can't say
  /// (no Permissions API, or it doesn't know the "camera" name).
  static Future<String?> _cameraPermission() async {
    try {
      if (!(web.window.navigator as JSObject).has('permissions')) return null;
      final status = await web.window.navigator.permissions
          .query({'name': 'camera'}.jsify()! as JSObject)
          .toDart;
      return status.state;
    } catch (_) {
      return null;
    }
  }

  static const _blocked =
      'Camera access is blocked for this site. Allow the camera in the '
      'browser\'s site settings, then retry.';

  /// A browser error from `getUserMedia`, in words for the user. Browsers
  /// reject with a DOMException whose name says what happened; its text
  /// starts with that name on every compiler.
  @visibleForTesting
  static CameraUnavailable cameraUnavailable(Object error) {
    final name = RegExp(r'^\w+Error').firstMatch('$error')?.group(0);
    final message = switch (name) {
      'NotAllowedError' ||
      'PermissionDeniedError' ||
      'SecurityError' => _blocked,
      'NotFoundError' ||
      'OverconstrainedError' ||
      'DevicesNotFoundError' => 'No camera was found. Connect one, then retry.',
      'NotReadableError' || 'TrackStartError' || 'AbortError' =>
        'The camera is in use by another app, or couldn\'t start. Close '
            'other apps using it, then retry.',
      _ => 'Something went wrong while starting the camera.',
    };
    debugPrint('Presence: could not open the camera: $error');
    return CameraUnavailable(message, error);
  }

  /// Browsers don't say which way a camera faces, but labels often do.
  static CameraFacing _facingFromLabel(String label) {
    final l = label.toLowerCase();
    if (l.contains('front') || l.contains('user') || l.contains('facetime')) {
      return CameraFacing.front;
    }
    if (l.contains('back') || l.contains('rear') || l.contains('environment')) {
      return CameraFacing.back;
    }
    return CameraFacing.unknown;
  }
}

/// Recording format for a stream, cheapest to encode first: each camera runs
/// several recorders at once.
String? _mimeTypeFor(web.MediaStream stream) {
  final hasAudio = stream.getAudioTracks().toDart.isNotEmpty;
  return [
    if (hasAudio) ...[
      'video/webm;codecs=vp8,opus',
      'video/webm;codecs=vp9,opus',
    ],
    'video/webm;codecs=vp8',
    'video/webm;codecs=vp9',
    'video/webm',
    'video/mp4',
  ].where((m) => web.MediaRecorder.isTypeSupported(m)).firstOrNull;
}

int _nextViewId = 0;

/// Registers [element] as a platform view and returns its view type.
String _registerView(web.HTMLElement element) {
  final viewType = 'presence-view-${_nextViewId++}';
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => element);
  return viewType;
}

class WebCameraSource implements CameraSource {
  WebCameraSource(
    this.id,
    this.label,
    this._stream,
    Duration Function() preRoll,
  ) : _mimeType = _mimeTypeFor(_stream) {
    _video
      ..autoplay = true
      // The live preview stays muted so the microphone doesn't feed back.
      ..muted = true
      ..playsInline = true
      ..srcObject = _stream;
    _video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain';
    _viewType = _registerView(_video);

    _pool = RecorderPool(
      startRecorder: () => _WebRecorder(_stream, _mimeType!),
      preRoll: preRoll,
      // Each clip's file is cut to its window, so it's as long as the clip.
      trim: _trimWebm,
    )..tick();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _pool.tick());
  }

  @override
  final String id;

  @override
  final String label;

  final web.MediaStream _stream;
  final String? _mimeType;
  final _video = web.HTMLVideoElement();
  late final String _viewType;
  late final RecorderPool _pool;
  late final Timer _ticker;
  final List<Timer> _releaseTimers = [];

  @override
  bool get supportsVideo => _mimeType != null;

  @override
  Widget buildPreview(BuildContext context) =>
      HtmlElementView(viewType: _viewType);

  @override
  Future<Uint8List?> captureFrame() async {
    final width = _video.videoWidth;
    final height = _video.videoHeight;
    if (width == 0 || height == 0) return null;

    // Thumbnails don't need full resolution.
    final scale = width > 480 ? 480 / width : 1.0;
    final canvas = web.HTMLCanvasElement()
      ..width = (width * scale).round()
      ..height = (height * scale).round();
    (canvas.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(
      _video,
      0,
      0,
      canvas.width,
      canvas.height,
    );

    final blob = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? b) => blob.complete(b)).toJS,
      'image/jpeg',
      0.8.toJS,
    );
    final result = await blob.future;
    if (result == null) return null;
    return (await result.arrayBuffer().toDart).toDart.asUint8List();
  }

  late final StreamController<Uint8List> _motion =
      StreamController<Uint8List>.broadcast(
        onListen: () => _motionTimer = Timer.periodic(
          const Duration(milliseconds: 200),
          (_) => _sampleMotion(),
        ),
        onCancel: () => _motionTimer?.cancel(),
      );
  Timer? _motionTimer;
  web.HTMLCanvasElement? _motionCanvas;

  @override
  Stream<Uint8List> get motionFrames => _motion.stream;

  /// Draws the live video into a tiny canvas and emits its luma.
  void _sampleMotion() {
    if (_video.videoWidth == 0) return;
    final canvas = _motionCanvas ??= web.HTMLCanvasElement()
      ..width = motionFrameWidth
      ..height = motionFrameHeight;
    final ctx =
        canvas.getContext('2d', {'willReadFrequently': true}.jsify())!
            as web.CanvasRenderingContext2D;
    ctx.drawImage(_video, 0, 0, motionFrameWidth, motionFrameHeight);
    final rgba = ctx
        .getImageData(0, 0, motionFrameWidth, motionFrameHeight)
        .data
        .toDart;
    _motion.add(lumaFromRgba(Uint8List.view(rgba.buffer)));
  }

  /// Browsers expose exposure compensation (Image Capture) only on some
  /// cameras; elsewhere this quietly does nothing.
  @override
  Future<void> setBrightness(double ev) async {
    final track = _stream.getVideoTracks().toDart.firstOrNull;
    if (track == null) return;
    try {
      await track
          .applyConstraints(
            {
                  'advanced': [
                    {'exposureCompensation': ev},
                  ],
                }.jsify()!
                as web.MediaTrackConstraints,
          )
          .toDart;
    } catch (_) {
      // Not supported by this camera or browser.
    }
  }

  @override
  ClipCapture requestClip({required Duration before, required Duration after}) {
    if (!supportsVideo) return ClipCapture.unsupported;
    final capture = _pool.requestClip(before: before, after: after);
    // Release the held recorder right at the end of the clip instead of on
    // the next once-a-second tick, so the file doesn't run long.
    _releaseTimers
      ..removeWhere((t) => !t.isActive)
      ..add(Timer(after, _pool.tick));
    return capture;
  }

  @override
  Future<void> dispose() async {
    _motionTimer?.cancel();
    _motion.close();
    _ticker.cancel();
    for (final t in _releaseTimers) {
      t.cancel();
    }
    _pool.close();
    for (final track in _stream.getTracks().toDart) {
      track.stop();
    }
  }
}

/// Cuts finished WebM recordings down to their clips' windows (`cutWebm`):
/// one download of the shared file, then a new file per clip. The shared
/// file is released once every clip has its own; one that can't be cut
/// keeps it.
Future<List<ClipMedia>> _trimWebm(List<ClipMedia> media) async {
  final source = media.firstOrNull?.liveUrl;
  if (source == null || !media.first.mimeType.contains('webm')) return media;
  final response = await web.window.fetch(source.toJS).toDart;
  final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
  var allCut = true;
  final out = [
    for (final m in media)
      if (cutWebm(bytes, m.start, m.end) case final cut?)
        ClipMedia(
          url: web.URL.createObjectURL(
            web.Blob(
              [cut.bytes.toJS].toJS,
              web.BlobPropertyBag(type: m.mimeType),
            ),
          ),
          start: cut.start,
          end: cut.end,
          mimeType: m.mimeType,
        )
      else
        (() {
          allCut = false;
          return m;
        })(),
  ];
  if (allCut) web.URL.revokeObjectURL(source);
  return out;
}

class _WebRecorder implements PoolRecorder {
  _WebRecorder(web.MediaStream stream, this.mimeType)
    : _recorder = web.MediaRecorder(
        stream,
        web.MediaRecorderOptions(
          mimeType: mimeType,
          // A keyframe every 5 s, so clips can be cut close to their start
          // without re-encoding (browsers that don't know it ignore it).
          videoKeyFrameIntervalDuration: 5000,
        ),
      ) {
    _recorder
      ..addEventListener(
        'dataavailable',
        (web.BlobEvent e) {
          if (!_discarded && e.data.size > 0) _chunks.add(e.data);
        }.toJS,
      )
      ..addEventListener(
        'start',
        // More accurate than the constructor time: recording can start a
        // few frames later.
        (web.Event _) {
          startedAt = DateTime.now();
        }.toJS,
      )
      ..addEventListener(
        'stop',
        (web.Event _) {
          _stopped.complete();
        }.toJS,
      )
      ..start();
  }

  final web.MediaRecorder _recorder;

  @override
  final String mimeType;
  final List<web.Blob> _chunks = [];
  final _stopped = Completer<void>();
  bool _discarded = false;

  @override
  DateTime startedAt = DateTime.now();

  @override
  Future<String> finish() async {
    if (_recorder.state != 'inactive') _recorder.stop();
    await _stopped.future;
    final blob = web.Blob(_chunks.toJS, web.BlobPropertyBag(type: mimeType));
    _chunks.clear();
    return web.URL.createObjectURL(blob);
  }

  @override
  void discard() {
    _discarded = true;
    if (_recorder.state != 'inactive') _recorder.stop();
    _chunks.clear();
  }
}

/// Plays a clip: the full clip once it's recorded, and until then the
/// preview (the "before" part), on its own. When the full clip arrives it
/// replaces the preview at the same moment of the clip. Nothing is joined:
/// each is played as one file.
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
  final _video = web.HTMLVideoElement();
  late final String _viewType;
  final List<(String, JSFunction)> _listeners = [];

  ClipMedia? _current;
  bool _onFull = false;
  bool _waiting = false;
  bool _loadFailed = false;
  Timer? _endTimer;

  VideoClip get _clip => widget.clip;

  static double _seconds(Duration d) => d.inMicroseconds / 1e6;

  /// Roughly how tall the browser's own video controls are.
  static const _controlsHeight = 56;

  @override
  void initState() {
    super.initState();
    _video
      ..controls = true
      ..muted = false
      ..playsInline = true;
    _video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain'
      ..backgroundColor = 'black';
    _viewType = _registerView(_video);

    _listen('timeupdate', (_) => _checkEnd());
    // timeupdate only fires every 250 ms or so; also schedule a check for
    // the exact end of the window whenever playback (re)starts or jumps.
    _listen('playing', (_) => _scheduleEndCheck());
    _listen('seeked', (_) => _scheduleEndCheck());
    _listen('ended', (_) => _reachedEnd());
    _listen('seeking', (_) {
      // Keep seeks inside the clip window; the files hold extra history.
      final media = _current;
      if (media == null) return;
      final t = _video.currentTime;
      if (t < _seconds(media.start) - 0.05) {
        _video.currentTime = _seconds(media.start);
      } else if (t > _seconds(media.end)) {
        _video.currentTime = _seconds(media.end);
      }
    });
    _listen('play', (_) {
      // Replaying after the end starts it over.
      final media = _current;
      if (media != null && _video.currentTime >= _seconds(media.end) - 0.05) {
        _video.currentTime = _seconds(media.start);
      }
    });

    _listen('click', (event) {
      // A click on the picture (not the controls bar at the bottom) tags
      // whoever is there instead of toggling playback.
      final controller = widget.controller;
      if (controller?.onPictureTap == null) return;
      final click = event as web.MouseEvent;
      final box = _video.getBoundingClientRect();
      if (click.offsetY > box.height - _controlsHeight) return;
      final fraction = ClipPlayerController.pictureFraction(
        Offset(click.offsetX.toDouble(), click.offsetY.toDouble()),
        Size(box.width, box.height),
        Size(_video.videoWidth.toDouble(), _video.videoHeight.toDouble()),
      );
      if (fraction == null) return;
      click.preventDefault();
      controller!.pictureTapped(fraction);
    });

    _clip.addListener(_onClipChanged);
    widget.controller?.attach(_captureFrame);
    _start();
  }

  /// Pauses, then draws the shown frame onto a canvas and encodes it.
  Future<CapturedFrame?> _captureFrame() async {
    _video.pause();
    final width = _video.videoWidth;
    final height = _video.videoHeight;
    if (width == 0 || height == 0) return null;
    final scale = width > ClipPlayerController.maxFrameWidth
        ? ClipPlayerController.maxFrameWidth / width
        : 1.0;
    final canvas = web.HTMLCanvasElement()
      ..width = (width * scale).round()
      ..height = (height * scale).round();
    (canvas.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(
      _video,
      0,
      0,
      canvas.width,
      canvas.height,
    );
    final blob = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? b) => blob.complete(b)).toJS,
      'image/jpeg',
      0.85.toJS,
    );
    final result = await blob.future;
    if (result == null) return null;
    return CapturedFrame(
      jpeg: (await result.arrayBuffer().toDart).toDart.asUint8List(),
      position: Duration(microseconds: (_video.currentTime * 1e6).round()),
    );
  }

  void _checkEnd() {
    final media = _current;
    if (media != null && _video.currentTime >= _seconds(media.end) - 0.02) {
      _reachedEnd();
    }
  }

  void _scheduleEndCheck() {
    _endTimer?.cancel();
    final media = _current;
    if (media == null || _video.paused) return;
    final remaining = _seconds(media.end) - _video.currentTime;
    if (remaining <= 0) {
      _checkEnd();
      return;
    }
    final rate = _video.playbackRate > 0 ? _video.playbackRate : 1.0;
    _endTimer = Timer(
      Duration(microseconds: (remaining / rate * 1e6).round()),
      () {
        _checkEnd();
        // Still short of the end (e.g. playback stalled): check again.
        if (_current == media && !_video.paused) _scheduleEndCheck();
      },
    );
  }

  void _listen(String type, void Function(web.Event) handler) {
    final fn = handler.toJS;
    _listeners.add((type, fn));
    _video.addEventListener(type, fn);
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
    });
    // Stored recordings load from IndexedDB on first play.
    final String url;
    try {
      url = await media.resolveUrl();
    } catch (_) {
      if (mounted && _current == media) setState(() => _loadFailed = true);
      return;
    }
    if (!mounted || _current != media) return;
    late final JSFunction onMetadata;
    onMetadata = ((web.Event _) {
      _video.removeEventListener('loadedmetadata', onMetadata);
      _video.currentTime = _seconds(at);
      // If the browser blocks autoplay with sound, stay paused on the
      // controls: one tap on play then starts it with audio. Never fall back
      // to muted playback.
      if (play) _video.play().toDart.ignore();
    }).toJS;
    _video.addEventListener('loadedmetadata', onMetadata);
    _video.src = url;
  }

  void _reachedEnd() {
    _endTimer?.cancel();
    _video.pause();
    // Snap back from any overshoot to the exact end.
    final media = _current;
    if (media != null) _video.currentTime = _seconds(media.end);
    // The preview is over; the full clip shows as soon as it's recorded.
    if (!_onFull && _clip.full == null) setState(() => _waiting = true);
  }

  /// Replaces the preview with the full clip, at the same moment of the
  /// clip. It plays on if the preview was playing, or had played to its end
  /// and was waiting for it.
  void _showFull(ClipMedia full) {
    final preview = _current;
    var into = preview == null
        ? Duration.zero
        : Duration(microseconds: (_video.currentTime * 1e6).round()) -
              preview.start;
    if (into.isNegative) into = Duration.zero;
    if (into > full.length) into = full.length;
    _load(
      full,
      full.start + into,
      onFull: true,
      play: _waiting || !_video.paused,
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

  @override
  void dispose() {
    widget.controller?.detach(_captureFrame);
    _endTimer?.cancel();
    _clip.removeListener(_onClipChanged);
    for (final (type, fn) in _listeners) {
      _video.removeEventListener(type, fn);
    }
    _video
      ..pause()
      ..removeAttribute('src')
      ..load();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        HtmlElementView(viewType: _viewType),
        if (_loadFailed)
          const Center(
            child: Text(
              "Couldn't load this clip from storage",
              style: TextStyle(color: Color(0xFFFB4934)),
            ),
          ),
        if (_current != null && !_onFull && !_waiting)
          const Align(
            alignment: Alignment.topLeft,
            child: Padding(padding: EdgeInsets.all(12), child: _PreviewLabel()),
          ),
        if (_waiting)
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xCC282828),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    'Recording the next ${_clip.after.inSeconds} s…',
                    style: const TextStyle(color: Color(0xFFEBDBB2)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Marks the preview (the part before the press) while the full clip is
/// still recording.
class _PreviewLabel extends StatelessWidget {
  const _PreviewLabel();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    key: Key('clip-preview'),
    decoration: BoxDecoration(
      color: Color(0xCC282828),
      borderRadius: BorderRadius.all(Radius.circular(4)),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text('Preview', style: TextStyle(color: Color(0xFFEBDBB2))),
    ),
  );
}
