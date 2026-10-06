/// Web-only helpers shared by the camera, the clip player and the frame
/// sampler: showing an element as a platform view, and encoding a video
/// frame as a JPEG.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// The one platform view type every element is shown with: the element
/// is looked up by the key in its `creationParams`. The browser's registry
/// keeps every factory forever, so one per camera or player (opened again
/// and again on an unattended device) would keep each element alive.
const String _viewType = 'presence-element';

bool _registered = false;
int _nextKey = 0;
final Map<int, web.HTMLElement> _elements = {};

/// Shows an element as a platform view until [release]d: [build] it as
/// often as needed.
class ElementView {
  ElementView(web.HTMLElement element) : _key = _nextKey++ {
    if (!_registered) {
      _registered = true;
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int _, {Object? params}) => _elements[params] ?? web.HTMLDivElement(),
      );
    }
    _elements[_key] = element;
  }

  final int _key;

  Widget build() => HtmlElementView(viewType: _viewType, creationParams: _key);

  /// Forgets the element, so it can be garbage collected.
  void release() => _elements.remove(_key);
}

/// [video]'s current frame on a new canvas at most [maxWidth] wide, or
/// null before it has one.
web.HTMLCanvasElement? videoFrameCanvas(
  web.HTMLVideoElement video, {
  required int maxWidth,
}) {
  final width = video.videoWidth;
  final height = video.videoHeight;
  if (width == 0 || height == 0) return null;
  final scale = width > maxWidth ? maxWidth / width : 1.0;
  final canvas = web.HTMLCanvasElement()
    ..width = (width * scale).round()
    ..height = (height * scale).round();
  (canvas.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(
    video,
    0,
    0,
    canvas.width,
    canvas.height,
  );
  return canvas;
}

/// [canvas] encoded as a JPEG of [quality] (0–1), or null if the browser
/// couldn't.
Future<Uint8List?> canvasJpeg(
  web.HTMLCanvasElement canvas, {
  double quality = 0.85,
}) async {
  final blob = Completer<web.Blob?>();
  canvas.toBlob(
    ((web.Blob? b) => blob.complete(b)).toJS,
    'image/jpeg',
    quality.toJS,
  );
  final result = await blob.future;
  if (result == null) return null;
  return (await result.arrayBuffer().toDart).toDart.asUint8List();
}
