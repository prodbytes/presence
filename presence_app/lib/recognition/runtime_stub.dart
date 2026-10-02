import 'dart:typed_data';

import 'runtime.dart';

/// No model runtime on this platform yet: recognition stays off.
class PlatformRuntime implements TfliteRuntime {
  @override
  bool get supported => false;

  @override
  Future<TfliteModel> load(Uint8List bytes) =>
      throw UnsupportedError('No TensorFlow Lite runtime on this platform');
}
