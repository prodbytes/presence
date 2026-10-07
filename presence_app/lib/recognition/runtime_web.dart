import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'runtime.dart';

/// TensorFlow.js running `.tflite` models (`@tensorflow/tfjs-tflite`, in
/// WebAssembly). Its scripts are served with the app from `tfjs/` and only
/// loaded the first time a model is.
class PlatformRuntime implements TfliteRuntime {
  /// Where the scripts and WebAssembly are, relative to the page (tests
  /// point it at a server).
  static String root = 'tfjs/';
  static const List<String> scripts = [
    'tf-core.min.js',
    'tf-backend-cpu.min.js',
    'tf-tflite.min.js',
  ];

  static Future<void>? _loading;

  @override
  bool get supported => true;

  @override
  Future<TfliteModel> load(Uint8List bytes) async {
    await (_loading ??= _loadScripts()..ignore());
    // The model's own bytes: a view into a larger buffer (an asset bundle)
    // would hand TFLite everything around it too.
    final exact =
        bytes.offsetInBytes == 0 &&
            bytes.lengthInBytes == bytes.buffer.lengthInBytes
        ? bytes
        : Uint8List.fromList(bytes);
    final model = await _tflite.loadTFLiteModel(exact.buffer.toJS).toDart;
    return _WebModel(model);
  }

  static Future<void> _loadScripts() async {
    try {
      for (final name in scripts) {
        final loaded = Completer<void>();
        final script = web.HTMLScriptElement()
          ..src = '$root$name'
          ..async = false;
        script.onload = ((web.Event _) => loaded.complete()).toJS;
        script.onerror = ((web.Event _) => loaded.completeError(
          StateError('Could not load $name'),
        )).toJS;
        web.document.head!.append(script);
        await loaded.future;
      }
      _tflite.setWasmPath(root);
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }
}

class _WebModel implements TfliteModel {
  _WebModel(this._model);

  final _TFLiteModel _model;

  @override
  Future<List<Float32List>> run(TypedData input) async {
    final spec = _model.inputs.toDart.first;
    final tensor = input is Int32List
        ? _tf.tensor(input.toJS, spec.shape, 'int32'.toJS)
        : _tf.tensor((input as Float32List).toJS, spec.shape, 'float32'.toJS);
    try {
      final result = _model.predict(tensor);
      // One output comes back as a tensor, several as a map of them.
      final outputs = _model.outputs.length == 1
          ? [result as _Tensor]
          : [
              for (final key in _objectKeys(result).toDart)
                _getProperty(result, key) as _Tensor,
            ];
      try {
        return [
          for (final t in outputs)
            Float32List.fromList((t.dataSync() as JSFloat32Array).toDart),
        ];
      } finally {
        for (final t in outputs) {
          t.dispose();
        }
      }
    } finally {
      tensor.dispose();
    }
  }

  @override
  void dispose() {}
}

@JS('tflite')
external _TfliteNamespace get _tflite;

extension type _TfliteNamespace(JSObject _) implements JSObject {
  external JSPromise<_TFLiteModel> loadTFLiteModel(JSArrayBuffer model);
  external void setWasmPath(String path);
}

extension type _TFLiteModel(JSObject _) implements JSObject {
  external JSArray<_TensorInfo> get inputs;
  external JSArray<_TensorInfo> get outputs;
  external JSObject predict(_Tensor input);
}

extension type _TensorInfo(JSObject _) implements JSObject {
  external JSArray<JSNumber> get shape;
}

@JS('tf')
external _TfNamespace get _tf;

extension type _TfNamespace(JSObject _) implements JSObject {
  external _Tensor tensor(
    JSTypedArray values,
    JSArray<JSNumber> shape,
    JSString dtype,
  );
}

extension type _Tensor(JSObject _) implements JSObject {
  external JSTypedArray dataSync();
  external void dispose();
}

@JS('Object.keys')
external JSArray<JSString> _objectKeys(JSObject o);

@JS('Reflect.get')
external JSObject _getProperty(JSObject o, JSString key);
