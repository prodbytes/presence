import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/crypto/media_seal.dart';

/// The streamer (presence_streamer, Go) seals the recordings and thumbnails
/// it uploads itself: the app must open them. The fixture is what its
/// `seal.Seal` makes (presence_streamer/internal/seal/seal_test.go).
void main() {
  test('opens media sealed by presence-streamer', () {
    final sealed = File('../presence_streamer/testdata/sealed-fixture.bin')
        .readAsBytesSync();
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final media = Uint8List.fromList(
      List.generate(300000, (i) => i * 31 % 251),
    );

    expect(SealFormat.keyIdOf(sealed), 'streamer_test_device');
    expect(SealFormat.openSync(sealed, key), media);
  });
}
