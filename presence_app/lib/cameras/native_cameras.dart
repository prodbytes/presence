import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../clips.dart';
import 'camera_source.dart';

/// Opens every camera through the `camera` plugin (Android, iOS). The plugin
/// can't keep a rolling recording, so these cameras show live previews and
/// take clip thumbnails, but don't record video clips.
Future<List<CameraSource>> openDeviceCameras(
  Duration Function() preRoll,
) async {
  final sources = <CameraSource>[];
  for (final description in await availableCameras()) {
    final label = description.name.trim().isEmpty ? 'Camera' : description.name;
    final controller = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      sources.add(_NativeCameraSource(description.name, label, controller));
    } catch (e) {
      // dispose() awaits initialize(), so it rethrows the failure.
      controller.dispose().ignore();
      sources.add(UnavailableCameraSource(description.name, label, e));
    }
  }
  return sources;
}

class _NativeCameraSource implements CameraSource {
  _NativeCameraSource(this.id, this.label, this._controller);

  @override
  final String id;

  @override
  final String label;
  final CameraController _controller;

  @override
  bool get supportsVideo => false;

  @override
  Widget buildPreview(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: _controller.value.aspectRatio,
      child: CameraPreview(_controller),
    ),
  );

  @override
  Future<Uint8List?> captureFrame() async {
    try {
      return await (await _controller.takePicture()).readAsBytes();
    } on CameraException {
      return null;
    }
  }

  @override
  ClipCapture requestClip({
    required Duration before,
    required Duration after,
  }) => ClipCapture.unsupported;

  @override
  void dispose() => _controller.dispose().ignore();
}

class ClipPlayerView extends StatelessWidget {
  const ClipPlayerView({super.key, required this.clip});

  final VideoClip clip;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      "Clip playback isn't supported on this platform yet",
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}
