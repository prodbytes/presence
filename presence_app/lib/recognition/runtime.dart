import 'dart:typed_data';

import 'runtime_stub.dart'
    if (dart.library.js_interop) 'runtime_web.dart'
    as platform;

/// Runs TensorFlow Lite models: TensorFlow.js on web (`runtime_web.dart`).
/// Every platform runs the same `.tflite` files, so they give the same
/// results.
abstract class TfliteRuntime {
  /// This platform's runtime.
  factory TfliteRuntime() = platform.PlatformRuntime;

  /// Whether models can run here at all.
  bool get supported;

  /// Loads a model from its bytes.
  Future<TfliteModel> load(Uint8List bytes);
}

/// One loaded model, with a single input.
abstract class TfliteModel {
  /// Runs the model on [input] (shaped as its input: a `Float32List`, or an
  /// `Int32List` for byte inputs) and returns every output, flattened, in
  /// no particular order (callers tell them apart by length).
  Future<List<Float32List>> run(TypedData input);

  void dispose();
}
