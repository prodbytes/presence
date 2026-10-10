import 'dart:typed_data';

import '../crypto/sealed_image.dart';
import '../crypto/media_seal.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../annotations.dart';

/// A grabbed frame, with markers for its tags; a click anywhere on it
/// reports where, as fractions (0 to 1) of the frame's width and height.
class FrameTagger extends StatelessWidget {
  const FrameTagger({
    super.key,
    required this.frame,
    required this.tags,
    required this.onTap,
  });

  final TagFrame frame;
  final List<Annotation> tags;
  final void Function(Offset fraction) onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      // The frame's own proportions, so clicks map onto the image exactly.
      future: _frameSize(frame.sealed),
      builder: (context, size) {
        final ratio = size.data == null
            ? 16 / 9
            : size.data!.width / size.data!.height;
        return AspectRatio(
          aspectRatio: ratio,
          child: LayoutBuilder(
            builder: (context, box) => Semantics(
              label:
                  'Frame to name subjects on: click a person or pet to '
                  'name them',
              child: GestureDetector(
                key: const Key('tag-surface'),
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => onTap(
                  Offset(
                    d.localPosition.dx / box.maxWidth,
                    d.localPosition.dy / box.maxHeight,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    SealedImage(frame.sealed, fit: BoxFit.fill),
                    for (final a in tags)
                      _Marker(
                        key: Key('marker-${a.id}'),
                        annotation: a,
                        box: box.biggest,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static final _sizes = Expando<Future<Size>>();

  static Future<Size> _frameSize(Uint8List sealed) =>
      _sizes[sealed] ??= () async {
        final jpeg = await MediaSeal.instance.openImage(sealed);
        final codec = await ui.instantiateImageCodec(jpeg);
        final image = (await codec.getNextFrame()).image;
        final size = Size(image.width.toDouble(), image.height.toDouble());
        image.dispose();
        codec.dispose();
        return size;
      }();
}

/// A named dot at an annotation's spot.
class _Marker extends StatelessWidget {
  const _Marker({super.key, required this.annotation, required this.box});

  final Annotation annotation;
  final Size box;

  static const double _dot = 12;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: annotation.x * box.width - _dot / 2,
      top: annotation.y * box.height - _dot / 2,
      child: IgnorePointer(
        child: Row(
          spacing: 4,
          children: [
            Container(
              width: _dot,
              height: _dot,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  annotation.name,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
