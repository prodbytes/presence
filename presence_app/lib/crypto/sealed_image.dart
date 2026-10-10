import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'media_seal.dart';

/// Shows a sealed image ([MediaSeal]): opened in memory to be shown, never
/// stored open. Until it's open nothing shows (the size it's given stays
/// empty); one whose device's key isn't known yet shows a lock, and opens
/// once the key arrives; one that doesn't open shows a broken image.
class SealedImage extends StatefulWidget {
  const SealedImage(
    this.bytes, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.cacheWidth,
    this.seal,
  });

  /// The sealed image (a JPEG or PNG, sealed).
  final Uint8List bytes;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final int? cacheWidth;

  /// The seal to open it with: [MediaSeal.instance] by default.
  final MediaSeal? seal;

  @override
  State<SealedImage> createState() => _SealedImageState();
}

class _SealedImageState extends State<SealedImage> {
  MediaSeal get _seal => widget.seal ?? MediaSeal.instance;
  Uint8List? _open;
  Object? _error;
  MediaKeys? _keys;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(SealedImage old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes) || old.seal != widget.seal) {
      _start();
    }
  }

  void _start() {
    final bytes = widget.bytes;
    _error = null;
    _listen(null);
    _seal
        .openImage(bytes)
        .then(
          (open) {
            if (!mounted || !identical(bytes, widget.bytes)) return;
            setState(() => _open = open);
          },
          onError: (Object e) {
            if (!mounted || !identical(bytes, widget.bytes)) return;
            setState(() {
              _open = null;
              _error = e;
            });
            // Opens once its device's key comes.
            if (e is SealKeyMissing) _listen(_seal.keys);
          },
        );
  }

  void _listen(MediaKeys? keys) {
    _keys?.removeListener(_onKeys);
    _keys = keys?..addListener(_onKeys);
  }

  void _onKeys() {
    final error = _error;
    if (error is SealKeyMissing && _seal.keys.keyOf(error.keyId) != null) {
      _start();
    }
  }

  @override
  void dispose() {
    _listen(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    if (open != null) {
      return Image.memory(
        open,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        gaplessPlayback: true,
      );
    }
    final error = _error;
    if (error == null) {
      return SizedBox(width: widget.width, height: widget.height);
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Center(
        child: Tooltip(
          message: error is SealKeyMissing
              ? "Waiting for ${error.keyId}'s key"
              : "This image can't be opened",
          child: Icon(
            error is SealKeyMissing ? Icons.lock_outline : Icons.broken_image,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
