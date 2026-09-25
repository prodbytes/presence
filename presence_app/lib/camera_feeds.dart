import 'package:flutter/material.dart';

import 'cameras/cameras.dart';
import 'clips.dart';
import 'events.dart';
import 'settings.dart';
import 'theme.dart';

/// The camera being shown and recorded: one at a time, starting with the
/// device's default camera, switchable with [flip]. Owned by the app so the
/// camera (and its rolling recording) stays open across rebuilds.
class CameraRig extends ChangeNotifier {
  CameraRig({required this._backend, required this.settings}) {
    settings.addListener(_applyBrightness);
    // Android refuses cameras while the screen is off or the app is in the
    // background: when the app comes back, reopen the camera if it failed.
    _lifecycle = AppLifecycleListener(onResume: _retryFailed);
  }

  late final AppLifecycleListener _lifecycle;

  final CameraBackend _backend;
  final ClipSettings settings;

  List<CameraDevice> _devices = const [];
  CameraDevice? _current;
  CameraSource? _active;
  Object? _error;
  bool _busy = true;
  bool _disposed = false;

  /// Every camera the device has.
  List<CameraDevice> get devices => _devices;

  /// The camera selected for display (open, opening, or failed to open).
  CameraDevice? get current => _current;

  /// The open camera, or null while opening or after a failure.
  CameraSource? get active => _active;

  Object? get error => _error;

  /// True while listing, opening or switching cameras.
  bool get busy => _busy;

  bool get canClip => _active != null && !_busy;

  bool get canFlip => _devices.length > 1 && !_busy;

  /// Lists the cameras and opens the default one: the first back camera, or
  /// else the first camera (on web, the browser's default).
  Future<void> load() async {
    await _closeActive();
    _set(busy: true, error: null);
    try {
      _devices = await _backend.listCameras();
    } catch (e) {
      _devices = const [];
      _current = null;
      if (!_disposed) _set(busy: false, error: e);
      return;
    }
    if (_disposed) return;
    _current = _devices.isEmpty
        ? null
        : _devices.firstWhere(
            (d) => d.facing == CameraFacing.back,
            orElse: () => _devices.first,
          );
    await _openCurrent();
  }

  /// Switches to the next camera: the other facing where the device knows
  /// it (back ↔ front), otherwise the next one in the list.
  Future<void> flip() async {
    final current = _current;
    if (!canFlip || current == null) return;
    final start = _devices.indexOf(current);
    final ordered = [
      for (var i = 1; i < _devices.length; i++)
        _devices[(start + i) % _devices.length],
    ];
    _current = current.facing == CameraFacing.unknown
        ? ordered.first
        : ordered.firstWhere(
            (d) => d.facing != current.facing,
            orElse: () => ordered.first,
          );
    await _closeActive();
    await _openCurrent();
  }

  Future<void> _openCurrent() async {
    final device = _current;
    if (device == null) {
      _set(busy: false, error: null);
      return;
    }
    _set(busy: true, error: null);
    try {
      final source = await _backend.open(device, () => settings.before);
      if (_disposed || _current != device) {
        await source.dispose();
        return;
      }
      _active = source;
      _appliedBrightness = null;
      _applyBrightness();
      _set(busy: false, error: null);
    } catch (e) {
      if (!_disposed) _set(busy: false, error: e);
    }
  }

  double? _appliedBrightness;

  /// Sends the brightness setting to the open camera when it changes.
  void _applyBrightness() {
    final source = _active;
    final ev = settings.brightness;
    if (source == null || ev == _appliedBrightness) return;
    _appliedBrightness = ev;
    source.setBrightness(ev).ignore();
  }

  Future<void> _closeActive() async {
    final source = _active;
    _active = null;
    if (source != null) {
      notifyListeners();
      await source.dispose();
    }
  }

  void _set({required bool busy, required Object? error}) {
    _busy = busy;
    _error = error;
    notifyListeners();
  }

  /// How long a Clip press waits for the camera's "before" recording before
  /// publishing its event anyway (it then becomes playable when it arrives).
  static const Duration pastWait = Duration(seconds: 2);

  /// Starts a clip on the open camera and publishes a [ClipRequested] event,
  /// with the camera's current frame as its thumbnail.
  ///
  /// The event is published once the "before" recording is ready (normally
  /// a few milliseconds), so it's playable the moment it appears. The same
  /// event is later updated with the full clip.
  Future<void> requestClips(AppEventBus bus) async {
    final camera = _active;
    if (camera == null) return;
    final before = settings.before;
    final after = settings.after;
    final requestedAt = DateTime.now();
    final capture = camera.requestClip(before: before, after: after);
    final (thumbnail, past) = await (
      camera.captureFrame(),
      capture.past
          .timeout(pastWait, onTimeout: () => null)
          .then<ClipMedia?>((m) => m, onError: (Object _) => null),
    ).wait;
    bus.publish(
      ClipRequested(
        VideoClip(
          cameraId: camera.id,
          cameraLabel: camera.label,
          before: before,
          after: after,
          capture: capture,
          past: past,
          thumbnail: thumbnail,
          supported: camera.supportsVideo,
        ),
        time: requestedAt,
      ),
    );
  }

  void _retryFailed() {
    if (_error == null || _busy) return;
    if (_devices.isEmpty) {
      load();
    } else {
      _openCurrent();
    }
  }

  /// Retries after a failure: reopens the selected camera, or relists.
  Future<void> retry() => _devices.isEmpty ? load() : _openCurrent();

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_applyBrightness);
    _lifecycle.dispose();
    _active?.dispose();
    _active = null;
    super.dispose();
  }
}

/// The open camera, full screen and without overlays.
class CameraFeedsView extends StatelessWidget {
  const CameraFeedsView({super.key, required this.rig});

  final CameraRig rig;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Gruvbox.bg0Hard,
      child: ListenableBuilder(
        listenable: rig,
        builder: (context, _) {
          final active = rig.active;
          if (active != null) {
            return SizedBox.expand(
              key: ObjectKey(active),
              child: active.buildPreview(context),
            );
          }
          final error = rig.error;
          if (error != null) {
            return FeedMessage(
              icon: Icons.error_outline,
              message:
                  'Could not open the camera\n${describeCameraError(error)}',
              action: TextButton(
                onPressed: rig.retry,
                child: const Text('Retry'),
              ),
            );
          }
          if (rig.busy) {
            return const Center(child: CircularProgressIndicator());
          }
          return FeedMessage(
            icon: Icons.videocam_off_outlined,
            message: 'No camera found',
            action: TextButton(onPressed: rig.load, child: const Text('Retry')),
          );
        },
      ),
    );
  }
}

class FeedMessage extends StatelessWidget {
  const FeedMessage({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

String describeCameraError(Object error) {
  // Browser errors (DOMException) carry a readable message in toString.
  final text = error.toString();
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}
