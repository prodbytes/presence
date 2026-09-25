import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

typedef CameraLoader = Future<List<CameraDescription>> Function();

/// Opens every camera available to the device and shows them in a grid.
class CameraFeedsView extends StatefulWidget {
  const CameraFeedsView({super.key, this.loadCameras = availableCameras});

  final CameraLoader loadCameras;

  @override
  State<CameraFeedsView> createState() => _CameraFeedsViewState();
}

class _CameraFeedsViewState extends State<CameraFeedsView> {
  List<CameraDescription>? _cameras;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _cameras = null;
      _error = null;
    });
    try {
      final cameras = await widget.loadCameras();
      if (mounted) setState(() => _cameras = cameras);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cameras = _cameras;
    if (_error != null) {
      return FeedMessage(
        icon: Icons.error_outline,
        message: 'Could not access cameras\n${describeCameraError(_error!)}',
        action: TextButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    if (cameras == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (cameras.isEmpty) {
      return FeedMessage(
        icon: Icons.videocam_off_outlined,
        message: 'No camera feeds',
        action: TextButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.sqrt(cameras.length).ceil();
        final rows = (cameras.length / columns).ceil();
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
            for (final (i, camera) in cameras.indexed)
              CameraTile(key: ValueKey(i), description: camera),
          ],
        );
      },
    );
  }
}

/// A single live camera feed. Each tile owns and disposes its controller.
class CameraTile extends StatefulWidget {
  const CameraTile({super.key, required this.description});

  final CameraDescription description;

  @override
  State<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<CameraTile> {
  late final CameraController _controller;
  late final Future<void> _initialized;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.description,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _initialized = _controller.initialize();
  }

  @override
  void dispose() {
    // dispose() awaits initialize(), so it rethrows a failed open; the tile
    // already showed that error.
    _controller.dispose().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Gruvbox.bg0Hard,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<void>(
              future: _initialized,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return FeedMessage(
                    icon: Icons.videocam_off_outlined,
                    message: describeCameraError(snapshot.error!),
                  );
                }
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Center(
                  child: AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: CameraPreview(_controller),
                  ),
                );
              },
            ),
            Positioned(
              left: 8,
              bottom: 8,
              child: _CameraLabel(text: cameraLabel(widget.description)),
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

/// Browsers may hide device labels, which leaves the name empty.
String cameraLabel(CameraDescription camera) {
  final name = camera.name.trim();
  return name.isEmpty ? 'Camera' : name;
}

String describeCameraError(Object error) {
  if (error is CameraException) {
    return error.description ?? error.code;
  }
  return error.toString();
}
