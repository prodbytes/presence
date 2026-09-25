import 'dart:math' as math;

import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/material.dart';

import 'cameras/cameras.dart';
import 'clips.dart';
import 'events.dart';
import 'settings.dart';
import 'theme.dart';

/// The open cameras. Owned by the app so cameras (and their rolling
/// recordings) stay open across rebuilds.
class CameraRig extends ChangeNotifier {
  CameraRig({required this._open, required this.settings});

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

  /// Starts a clip on every camera and publishes a [ClipRequested] event for
  /// each, with the camera's current frame as its thumbnail.
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
    final frames = await Future.wait(cameras.map((c) => c.captureFrame()));

    for (final (i, camera) in cameras.indexed) {
      bus.publish(
        ClipRequested(
          VideoClip(
            cameraLabel: camera.label,
            before: before,
            after: after,
            capture: captures[i],
            thumbnail: frames[i],
            supported: camera.supportsVideo,
          ),
          time: requestedAt,
        ),
      );
    }
  }

  void _closeSources() {
    for (final s in _sources ?? const <CameraSource>[]) {
      s.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
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

class _CameraGrid extends StatelessWidget {
  const _CameraGrid({required this.sources});

  final List<CameraSource> sources;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.sqrt(sources.length).ceil();
        final rows = (sources.length / columns).ceil();
        const spacing = 8.0;
        final tileWidth =
            (constraints.maxWidth - spacing * (columns + 1)) / columns;
        final tileHeight =
            (constraints.maxHeight - spacing * (rows + 1)) / rows;
        return GridView.count(
          padding: const EdgeInsets.all(spacing),
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Gruvbox.bg0Hard,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (src is UnavailableCameraSource)
              FeedMessage(
                icon: Icons.videocam_off_outlined,
                message: describeCameraError(src.error),
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
  if (error is CameraException) {
    return error.description ?? error.code;
  }
  return error.toString();
}
