import 'dart:io';
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import 'runtime.dart';

/// LiteRT (TensorFlow Lite) through `tflite_flutter`, running on the
/// calling isolate: recognition calls it from its worker isolate
/// (`vision_worker.dart`), so the app doesn't stall. Android only for now.
class PlatformRuntime implements TfliteRuntime {
  /// CPU threads per model (the worker runs one model at a time).
  static const int threads = 2;

  @override
  bool get supported => Platform.isAndroid;

  /// Keeps a native copy of [bytes] for as long as the app runs
  /// (`tflite_flutter` never frees it): recognition loads from files
  /// instead ([loadFile]).
  @override
  Future<TfliteModel> load(Uint8List bytes) async =>
      _create((options) => Interpreter.fromBuffer(bytes, options: options));

  /// Loads the model in the file at [path], mapped rather than copied (the
  /// system can drop its pages under memory pressure), and all freed on
  /// [TfliteModel.dispose].
  TfliteModel loadFile(String path) =>
      _create((options) => Interpreter.fromFile(File(path), options: options));

  static TfliteModel _create(
    Interpreter Function(InterpreterOptions options) create,
  ) {
    // The interpreter keeps a copy of its options.
    final options = InterpreterOptions()..threads = threads;
    try {
      return _NativeModel(create(options)..allocateTensors());
    } finally {
      options.delete();
    }
  }
}

class _NativeModel implements TfliteModel {
  _NativeModel(this._interpreter);

  final Interpreter _interpreter;

  /// The outputs are views of the interpreter's own memory, not copies
  /// (EfficientDet's scores alone are 7 MB): read them before the next run.
  @override
  Future<List<Float32List>> run(TypedData input) async {
    // Raw bytes in the input's own type: bytes for a uint8 input, floats
    // otherwise, written straight into the input tensor.
    final bytes = input is Int32List
        ? Uint8List.fromList(input)
        : input.buffer.asUint8List(input.offsetInBytes, input.lengthInBytes);
    _interpreter.getInputTensor(0).data = bytes;
    _interpreter.invoke();
    return [
      for (final tensor in _interpreter.getOutputTensors())
        Float32List.sublistView(tensor.data),
    ];
  }

  @override
  void dispose() => _interpreter.close();
}
