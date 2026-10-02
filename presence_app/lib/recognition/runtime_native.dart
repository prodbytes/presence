import 'dart:io';
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import 'runtime.dart';

/// LiteRT (TensorFlow Lite) through `tflite_flutter`, each model running in
/// its own background isolate so the app doesn't stall. Android only for
/// now.
class PlatformRuntime implements TfliteRuntime {
  /// CPU threads per model.
  static const int threads = 4;

  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<TfliteModel> load(Uint8List bytes) async {
    final interpreter = Interpreter.fromBuffer(
      bytes,
      options: InterpreterOptions()..threads = threads,
    );
    interpreter.allocateTensors();
    return _NativeModel(
      interpreter,
      await IsolateInterpreter.create(address: interpreter.address),
    );
  }
}

class _NativeModel implements TfliteModel {
  _NativeModel(this._interpreter, this._isolate);

  final Interpreter _interpreter;
  final IsolateInterpreter _isolate;

  @override
  Future<List<Float32List>> run(TypedData input) async {
    // Raw bytes in the input's own type: bytes for a uint8 input, floats
    // otherwise.
    final bytes = input is Int32List
        ? Uint8List.fromList(input)
        : input.buffer.asUint8List(input.offsetInBytes, input.lengthInBytes);
    final tensors = _interpreter.getOutputTensors();
    final outputs = {
      for (var i = 0; i < tensors.length; i++)
        i: Uint8List(tensors[i].numBytes()),
    };
    await _isolate.runForMultipleInputs([bytes], outputs);
    return [
      for (var i = 0; i < tensors.length; i++)
        Float32List.sublistView(outputs[i]!),
    ];
  }

  @override
  void dispose() {
    _isolate.close();
    _interpreter.close();
  }
}
