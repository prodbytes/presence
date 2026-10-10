import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/crypto/media_seal.dart';
import 'package:presence_app/crypto/seal_files_io.dart' as files;

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  Uint8List bytes(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 31) & 0xFF));

  group('SealFormat', () {
    test('seals and opens media of every size, a chunk at a time', () {
      for (final n in [0, 1, 1023, 1024, 1025, 4096, 5000]) {
        final plain = bytes(n);
        final sealed = SealFormat.sealSync(
          plain,
          key,
          'a_b_c',
          chunkSize: 1024,
        );
        expect(SealFormat.isSealed(sealed), isTrue);
        expect(SealFormat.keyIdOf(sealed), 'a_b_c');
        expect(sealed.length, greaterThan(n), reason: '$n bytes');
        expect(SealFormat.openSync(sealed, key), plain, reason: '$n bytes');
      }
    });

    test('hides the media and never seals it the same way twice', () {
      final plain = bytes(2000);
      final a = SealFormat.sealSync(plain, key, 'a_b_c');
      final b = SealFormat.sealSync(plain, key, 'a_b_c');
      expect(a, isNot(b));
      final header = SealFormat.parseHeader(a)!;
      expect(
        a.sublist(header.length, header.length + 64),
        isNot(plain.sublist(0, 64)),
      );
    });

    test("doesn't open changed, cut off or reordered media", () {
      final plain = bytes(3000);
      final sealed = SealFormat.sealSync(plain, key, 'a_b_c', chunkSize: 1024);
      final flipped = Uint8List.fromList(sealed)..[sealed.length - 20] ^= 1;
      expect(
        () => SealFormat.openSync(flipped, key),
        throwsA(isA<SealBroken>()),
      );
      // Whole chunks dropped from the end.
      final cut = Uint8List.sublistView(sealed, 0, sealed.length - 952 - 16);
      expect(() => SealFormat.openSync(cut, key), throwsA(isA<SealBroken>()));
      // Another key ID in the header (the same length).
      final renamed = Uint8List.fromList(sealed)..[5] = 'x'.codeUnitAt(0);
      expect(
        () => SealFormat.openSync(renamed, key),
        throwsA(isA<SealBroken>()),
      );
      final other = Uint8List.fromList(List.filled(32, 9));
      expect(
        () => SealFormat.openSync(sealed, other),
        throwsA(isA<SealBroken>()),
      );
    });

    test('tells sealed media from a JPEG', () {
      expect(SealFormat.isSealed([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]), isFalse);
      expect(SealFormat.isSealed(const []), isFalse);
      expect(SealFormat.isSealed(null), isFalse);
    });

    test('new keys are random, 32 bytes', () {
      final a = SealFormat.newKey(Random(1));
      expect(a, hasLength(32));
      expect(SealFormat.newKey(), isNot(SealFormat.newKey()));
    });
  });

  group('MediaSeal', () {
    test("seals with its own key; opens other devices' once known", () async {
      final mine = MediaSeal(MediaKeys()..setOwn('my_own_device', key));
      final theirs = MediaSeal.forTests(deviceId: 'their_other_device');
      final plain = bytes(100 * 1024);
      final sealed = await theirs.seal(plain);
      expect(SealFormat.keyIdOf(sealed), 'their_other_device');
      await expectLater(mine.open(sealed), throwsA(isA<SealKeyMissing>()));
      expect(mine.keys.wanted, {'their_other_device'});
      expect(
        mine.keys.add('their_other_device', (await theirs.keys.own).key),
        isTrue,
      );
      expect(mine.keys.wanted, isEmpty);
      expect(await mine.open(sealed), plain);
      expect(await mine.open(await mine.seal(plain)), plain);
    });

    test("a known device's key isn't replaced, nor this device's", () {
      final keys = MediaKeys()..setOwn('my_own_device', key);
      final other = Uint8List.fromList(List.filled(32, 1));
      expect(keys.add('my_own_device', other), isFalse);
      expect(keys.keyOf('my_own_device'), key);
      expect(keys.add('peer_device_one', other), isTrue);
      expect(keys.add('peer_device_one', key), isFalse);
      expect(keys.keyOf('peer_device_one'), other);
      expect(keys.add('short_key', Uint8List(5)), isFalse);
    });

    test('keys go to text and back', () {
      expect(MediaKeys.decode(MediaKeys.encode(key)), key);
      expect(MediaKeys.decode('not base64!'), isNull);
      expect(MediaKeys.decode(MediaKeys.encode(Uint8List(16))), isNull);
      expect(MediaKeys.decode(42), isNull);
    });

    test('seals and opens files', () async {
      final dir = await Directory.systemTemp.createTemp('seal');
      addTearDown(() => dir.delete(recursive: true));
      final plain = bytes(700 * 1024);
      final from = File('${dir.path}/plain.mp4')..writeAsBytesSync(plain);
      files.sealFileSync(from.path, '${dir.path}/s', key, 'a_b_c');
      final sealed = File('${dir.path}/s').readAsBytesSync();
      expect(SealFormat.openSync(sealed, key), plain);
      files.openFileSync('${dir.path}/s', '${dir.path}/o.mp4', key);
      expect(File('${dir.path}/o.mp4').readAsBytesSync(), plain);
      // One that doesn't open leaves nothing behind.
      expect(
        () => files.openFileSync(from.path, '${dir.path}/x.mp4', key),
        throwsA(isA<SealBroken>()),
      );
      expect(File('${dir.path}/x.mp4').existsSync(), isFalse);
    });
  });
}
