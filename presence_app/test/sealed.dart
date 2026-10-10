import 'dart:typed_data';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/crypto/media_seal.dart';
import 'package:presence_app/events.dart';

/// [plain] sealed with the tests' key ([MediaSeal.instance], set in
/// `flutter_test_config.dart`), as the app stores every image.
Uint8List sealed(List<int> plain) {
  final own = MediaSeal.instance.keys.ownNow!;
  return SealFormat.sealSync(Uint8List.fromList(plain), own.key, own.id);
}

/// [bytes] opened with the tests' key.
Uint8List opened(Uint8List bytes) =>
    SealFormat.openSync(bytes, MediaSeal.instance.keys.ownNow!.key);

/// A tagged frame of [jpeg] at [ms], sealed (as `newFrame` makes them).
TagFrame testFrame(List<int> jpeg, int ms) =>
    TagFrame(id: AppEvent.newId(), sealed: sealed(jpeg), ms: ms);
