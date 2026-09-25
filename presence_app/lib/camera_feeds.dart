import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cameras/cameras.dart';
import 'clips.dart';
import 'events.dart';
import 'settings.dart';
import 'theme.dart';

/// The open cameras. Owned by the app so cameras (and their rolling
/// recordings) stay open across rebuilds.
class CameraRig extends ChangeNotifier {
  CameraRig({required this._open, required this.settings}) {
    // Android refuses cameras while the screen is off or the app is in the
    // background: when the app comes back, reopen any that failed.
    _lifecycle = AppLifecycleListener(onResume: _retryFailed);
  }

  late final AppLifecycleListener _lifecycle;

  final CameraOpener _open;
  final ClipSettings settings;

  List<CameraSource>? _sources;
  Object? _error;
  bool _disposed = false;

  /// Null while loading.
  List<CameraSource>? get sources => _sources;
  Object? get error => _error;

  bool get canClip =>
      _sources?.any((s) => s is! UnavailableCameraSource) ?? false;

  Future<void> load() async {
    _closeSources();
    _sources = null;
    _error = null;
    notifyListeners();
    try {
      final sources = await _open(() => settings.before);
      if (_disposed) {
        for (final s in sources) {
          s.dispose();
        }
        return;
      }
      _sources = sources;
    } catch (e) {
      if (_disposed) return;
      _error = e;
    }
    notifyListeners();
  }

  /// How long a Clip press waits for a camera's "before" recording before
  /// publishing its event anyway (it then becomes playable when it arrives).
  static const Duration pastWait = Duration(seconds: 2);

  /// Starts a clip on every camera and publishes a [ClipRequested] event for
  /// each, with the camera's current frame as its thumbnail.
  ///
  /// Each event is published once its camera's "before" recording is ready
  /// (normally a few milliseconds), so the event is playable the moment it
  /// appears. The same event is later updated with the full clip.
  Future<void> requestClips(AppEventBus bus) async {
    final before = settings.before;
    final after = settings.after;
    final cameras = (_sources ?? const <CameraSource>[])
        .where((s) => s is! UnavailableCameraSource)
        .toList();

    // Start every clip before anything slower, so they share one moment.
    final requestedAt = DateTime.now();
    final captures = [
      for (final camera in cameras)
        camera.requestClip(before: before, after: after),
    ];

    // Cameras publish independently: a slow one doesn't hold up the others.
    await Future.wait([
      for (final (i, camera) in cameras.indexed)
        _publishWhenPlayable(
          bus,
          camera,
          captures[i],
          requestedAt: requestedAt,
          before: before,
          after: after,
        ),
    ]);
  }

  Future<void> _publishWhenPlayable(
    AppEventBus bus,
    CameraSource camera,
    ClipCapture capture, {
    required DateTime requestedAt,
    required Duration before,
    required Duration after,
  }) async {
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
    final sources = _sources;
    final failed =
        _error != null ||
        (sources?.any((s) => s is UnavailableCameraSource && s.retryable) ??
            false);
    if (failed) load();
  }

  void _closeSources() {
    for (final s in _sources ?? const <CameraSource>[]) {
      s.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _lifecycle.dispose();
    _closeSources();
    super.dispose();
  }
}

/// Shows every open camera in a grid.
class CameraFeedsView extends StatelessWidget {
  const CameraFeedsView({super.key, required this.rig});

  final CameraRig rig;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: rig,
      builder: (context, _) {
        final error = rig.error;
        if (error != null) {
          return FeedMessage(
            icon: Icons.error_outline,
            message: 'Could not access cameras\n${describeCameraError(error)}',
            action: TextButton(onPressed: rig.load, child: const Text('Retry')),
          );
        }
        final sources = rig.sources;
        if (sources == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (sources.isEmpty) {
          return FeedMessage(
            icon: Icons.videocam_off_outlined,
            message: 'No camera feeds',
            action: TextButton(onPressed: rig.load, child: const Text('Retry')),
          );
        }
        return _CameraGrid(sources: sources);
      },
    );
  }
}

/// Live cameras fill the grid. Cameras that couldn't open are listed in a
/// compact line below, unless none opened (then their errors fill the grid).
class _CameraGrid extends StatelessWidget {
  const _CameraGrid({required this.sources});

  final List<CameraSource> sources;

  @override
  Widget build(BuildContext context) {
    final live = sources.where((s) => s is! UnavailableCameraSource).toList();
    final unavailable = sources.whereType<UnavailableCameraSource>().toList();
    if (live.isEmpty || unavailable.isEmpty) return _Grid(sources: sources);
    // One line per reason: "Back camera 2, Front camera 1: …".
    final byReason = <String, List<UnavailableCameraSource>>{};
    for (final camera in unavailable) {
      byReason
          .putIfAbsent(describeCameraError(camera.error), () => [])
          .add(camera);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _Grid(sources: live)),
        for (final MapEntry(key: reason, value: cameras) in byReason.entries)
          Padding(
            // Clear of the Clip button in the bottom-right corner.
            padding: const EdgeInsets.fromLTRB(12, 8, 136, 8),
            child: Text(
              '${cameras.map((c) => c.label).join(', ')}: $reason',
              key: ValueKey('unavailable-${cameras.first.id}'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.sources});

  final List<CameraSource> sources;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.sqrt(sources.length).ceil();
        final rows = (sources.length / columns).ceil();
        // Full screen: edge to edge, with hairline gaps between cameras.
        const spacing = 2.0;
        final tileWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        final tileHeight =
            (constraints.maxHeight - spacing * (rows - 1)) / rows;
        return GridView.count(
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: columns,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: tileHeight > 0 ? tileWidth / tileHeight : 16 / 9,
          children: [
            for (final source in sources)
              CameraTile(key: ObjectKey(source), source: source),
          ],
        );
      },
    );
  }
}

/// A single live camera feed.
class CameraTile extends StatelessWidget {
  const CameraTile({super.key, required this.source});

  final CameraSource source;

  @override
  Widget build(BuildContext context) {
    final src = source;
    return ClipRect(
      child: ColoredBox(
        color: Gruvbox.bg0Hard,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (src is UnavailableCameraSource)
              // Tiles can be small (phones): shrink the message to fit.
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: 200,
                    child: FeedMessage(
                      icon: Icons.videocam_off_outlined,
                      message: describeCameraError(src.error),
                    ),
                  ),
                ),
              )
            else
              src.buildPreview(context),
            Positioned(
              left: 8,
              bottom: 8,
              child: _CameraLabel(text: src.label),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraLabel extends StatelessWidget {
  const _CameraLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Gruvbox.bg0.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          style: const TextStyle(color: Gruvbox.fg, fontSize: 12),
        ),
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
