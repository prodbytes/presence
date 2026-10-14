import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// `navigator.deviceMemory`, in GB (Chrome's, rounded); null where the
/// browser doesn't say.
Future<int?> deviceMemoryMb() async {
  try {
    final navigator = globalContext['navigator'] as JSObject?;
    final gb = navigator?['deviceMemory'];
    if (gb == null || !gb.isA<JSNumber>()) return null;
    final value = (gb as JSNumber).toDartDouble;
    return value > 0 ? (value * 1024).round() : null;
  } catch (_) {
    return null;
  }
}
