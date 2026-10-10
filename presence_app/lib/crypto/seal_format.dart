import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// The format of sealed (encrypted) media: every image and recording the
/// app keeps or sends is sealed with its device's key (see `MediaSeal`).
///
/// A sealed object is a header, then the media in chunks, each encrypted
/// with AES-256-GCM:
///
/// | Bytes | Holds |
/// |-------|-------|
/// | 4 | magic: `PSE` and the format version, 1 |
/// | 1 | the key ID's length, n (1 to 64) |
/// | n | the key ID: the ID of the device whose key sealed it (ASCII) |
/// | 4 | the chunk size, big-endian |
/// | 7 | a random nonce prefix |
///
/// Each chunk is [chunkSize] bytes of media (the last one fewer, or none
/// for empty media) followed by its 16-byte GCM tag. Its nonce is the
/// prefix, the chunk's index (4 bytes, big-endian) and a byte that is 1
/// for the last chunk, 0 for the others, so chunks can't be reordered,
/// dropped or cut off unnoticed. The header is every chunk's additional
/// authenticated data, so the key ID and chunk size can't be changed.
///
/// Chunks let a recording be sealed and opened a piece at a time, from a
/// file to a file, without holding it all in memory.
abstract final class SealFormat {
  /// `PSE` and version 1.
  static const List<int> magic = [0x50, 0x53, 0x45, 0x01];

  /// How much media each chunk holds.
  static const int chunkSize = 256 * 1024;

  static const int tagLength = 16;
  static const int keyLength = 32;
  static const int _prefixLength = 7;
  static const int _maxKeyIdLength = 64;
  static const int _minChunkSize = 1024;
  static const int _maxChunkSize = 16 * 1024 * 1024;

  /// The longest a header can be.
  static const int maxHeaderLength =
      4 + 1 + _maxKeyIdLength + 4 + _prefixLength;

  /// What a key ID looks like (a device ID).
  static final RegExp _keyIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// Whether [bytes] start as sealed media, with a header that reads. Says
  /// nothing about whether it opens.
  static bool isSealed(List<int>? bytes) =>
      bytes != null && parseHeader(bytes) != null;

  /// The ID of the key that sealed [bytes] (its device's ID), or null when
  /// they aren't sealed.
  static String? keyIdOf(List<int> bytes) => parseHeader(bytes)?.keyId;

  /// The header at the start of [bytes], or null when there isn't a valid
  /// one.
  static SealHeader? parseHeader(List<int> bytes) {
    if (bytes.length < magic.length + 1) return null;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return null;
    }
    final n = bytes[magic.length];
    if (n < 1 || n > _maxKeyIdLength) return null;
    final length = magic.length + 1 + n + 4 + _prefixLength;
    if (bytes.length < length) return null;
    const idStart = 5;
    final String keyId;
    try {
      keyId = ascii.decode(bytes.sublist(idStart, idStart + n));
    } catch (_) {
      return null;
    }
    if (!_keyIdPattern.hasMatch(keyId)) return null;
    final at = idStart + n;
    final size =
        (bytes[at] << 24) |
        (bytes[at + 1] << 16) |
        (bytes[at + 2] << 8) |
        bytes[at + 3];
    if (size < _minChunkSize || size > _maxChunkSize) return null;
    return SealHeader._(
      keyId: keyId,
      chunkSize: size,
      bytes: Uint8List.fromList(bytes.sublist(0, length)),
    );
  }

  /// A new header for media sealed with the key [keyId], with a fresh
  /// random nonce prefix.
  static SealHeader newHeader(
    String keyId, {
    int chunkSize = chunkSize,
    Random? random,
  }) {
    if (!_keyIdPattern.hasMatch(keyId)) {
      throw ArgumentError.value(keyId, 'keyId', 'not a safe key ID');
    }
    final r = random ?? Random.secure();
    final id = ascii.encode(keyId);
    final bytes = BytesBuilder(copy: false)
      ..add(magic)
      ..addByte(id.length)
      ..add(id)
      ..add([
        (chunkSize >> 24) & 0xFF,
        (chunkSize >> 16) & 0xFF,
        (chunkSize >> 8) & 0xFF,
        chunkSize & 0xFF,
      ])
      ..add([for (var i = 0; i < _prefixLength; i++) r.nextInt(256)]);
    return SealHeader._(
      keyId: keyId,
      chunkSize: chunkSize,
      bytes: bytes.toBytes(),
    );
  }

  /// How many chunks [plainLength] bytes of media take: at least one.
  static int chunkCount(int chunkSize, int plainLength) =>
      plainLength == 0 ? 1 : (plainLength + chunkSize - 1) ~/ chunkSize;

  /// The plain length of a sealed object of [sealedLength] bytes with
  /// [header], or null when no sealing makes that length (cut off).
  static int? plainLength(SealHeader header, int sealedLength) {
    final body = sealedLength - header.length;
    final full = header.chunkSize + tagLength;
    if (body < tagLength) return null;
    final whole = body ~/ full;
    final rest = body % full;
    if (rest == 0) return whole * header.chunkSize;
    if (rest < tagLength) return null;
    return whole * header.chunkSize + rest - tagLength;
  }

  /// Chunk [index]'s nonce: the prefix, the index and whether it's the
  /// [last] one.
  static List<int> nonceOf(SealHeader header, int index, {required bool last}) {
    final prefix = header.bytes.sublist(header.length - _prefixLength);
    return [
      ...prefix,
      (index >> 24) & 0xFF,
      (index >> 16) & 0xFF,
      (index >> 8) & 0xFF,
      index & 0xFF,
      last ? 1 : 0,
    ];
  }

  /// A new random key, [keyLength] bytes.
  static Uint8List newKey([Random? random]) {
    final r = random ?? Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < keyLength; i++) r.nextInt(256),
    ]);
  }

  static final DartAesGcm _gcm = DartAesGcm.with256bits();

  /// Seals [plain] with [key] (of the device [keyId]) on this thread.
  static Uint8List sealSync(
    Uint8List plain,
    Uint8List key,
    String keyId, {
    int chunkSize = chunkSize,
    Random? random,
  }) {
    final header = newHeader(keyId, chunkSize: chunkSize, random: random);
    final keyData = SecretKeyData(key);
    final out = BytesBuilder(copy: false)..add(header.bytes);
    final count = chunkCount(header.chunkSize, plain.length);
    for (var i = 0; i < count; i++) {
      final start = i * header.chunkSize;
      final end = min(start + header.chunkSize, plain.length);
      final box = _gcm.encryptSync(
        Uint8List.sublistView(plain, start, end),
        secretKeyData: keyData,
        nonce: nonceOf(header, i, last: i == count - 1),
        aad: header.bytes,
      );
      out
        ..add(box.cipherText)
        ..add(box.mac.bytes);
    }
    return out.toBytes();
  }

  /// Opens [sealed] with [key] on this thread. Throws [SealBroken] when
  /// it isn't sealed media, or doesn't open with [key] (another key, or
  /// changed).
  static Uint8List openSync(Uint8List sealed, Uint8List key) {
    final header = parseHeader(sealed);
    if (header == null) throw const SealBroken('not sealed media');
    final length = plainLength(header, sealed.length);
    if (length == null) throw const SealBroken('cut off');
    final keyData = SecretKeyData(key);
    final out = Uint8List(length);
    final count = chunkCount(header.chunkSize, length);
    var at = header.length;
    for (var i = 0; i < count; i++) {
      final offset = i * header.chunkSize;
      final size = min(header.chunkSize, length - offset);
      final plain = openChunkSync(
        keyData,
        header,
        i,
        Uint8List.sublistView(sealed, at, at + size + tagLength),
        last: i == count - 1,
      );
      out.setRange(offset, offset + size, plain);
      at += size + tagLength;
    }
    return out;
  }

  /// Opens one chunk (its ciphertext and tag) on this thread.
  static List<int> openChunkSync(
    SecretKeyData key,
    SealHeader header,
    int index,
    Uint8List chunk, {
    required bool last,
  }) {
    if (chunk.length < tagLength) throw const SealBroken('cut off');
    final split = chunk.length - tagLength;
    try {
      return _gcm.decryptSync(
        SecretBox(
          Uint8List.sublistView(chunk, 0, split),
          nonce: nonceOf(header, index, last: last),
          mac: Mac(Uint8List.sublistView(chunk, split)),
        ),
        secretKeyData: key,
        aad: header.bytes,
      );
    } on SecretBoxAuthenticationError {
      throw const SealBroken("doesn't open with its key");
    }
  }

  /// Seals one chunk on this thread: its ciphertext and tag.
  static Uint8List sealChunkSync(
    SecretKeyData key,
    SealHeader header,
    int index,
    List<int> plain, {
    required bool last,
  }) {
    final box = _gcm.encryptSync(
      plain,
      secretKeyData: key,
      nonce: nonceOf(header, index, last: last),
      aad: header.bytes,
    );
    return (BytesBuilder(copy: false)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .toBytes();
  }
}

/// A sealed object's header ([SealFormat.parseHeader]).
class SealHeader {
  const SealHeader._({
    required this.keyId,
    required this.chunkSize,
    required this.bytes,
  });

  /// The ID of the device whose key sealed it.
  final String keyId;
  final int chunkSize;

  /// The header as stored: every chunk's additional authenticated data.
  final Uint8List bytes;

  int get length => bytes.length;
}

/// Sealed media that couldn't be opened: it isn't sealed, or was cut off or
/// changed, or the key isn't the one that sealed it.
class SealBroken implements Exception {
  const SealBroken(this.reason);

  final String reason;

  @override
  String toString() => 'Sealed media broken: $reason';
}

/// Sealed media whose key this device doesn't have (yet): another device's,
/// which comes with that device's settings.
class SealKeyMissing implements Exception {
  const SealKeyMissing(this.keyId);

  final String keyId;

  @override
  String toString() => 'No key for $keyId';
}
