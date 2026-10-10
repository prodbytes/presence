import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'seal_format.dart';

/// The start of the file [path]: enough for its header, if it's sealed.
Future<Uint8List> readHead(String path) async {
  final file = await File(path).open();
  try {
    return await file.read(SealFormat.maxHeaderLength);
  } finally {
    await file.close();
  }
}

/// Seals the file [from] into the file [to] (replacing it) with [key], of
/// device [keyId], a chunk at a time. Blocks: for another isolate.
void sealFileSync(String from, String to, Uint8List key, String keyId) {
  final source = File(from).openSync();
  final target = File(to).openSync(mode: FileMode.write);
  try {
    final length = source.lengthSync();
    final header = SealFormat.newHeader(keyId);
    final keyData = SecretKeyData(key);
    target.writeFromSync(header.bytes);
    final count = SealFormat.chunkCount(header.chunkSize, length);
    for (var i = 0; i < count; i++) {
      final plain = source.readSync(header.chunkSize);
      target.writeFromSync(
        SealFormat.sealChunkSync(
          keyData,
          header,
          i,
          plain,
          last: i == count - 1,
        ),
      );
    }
    target.flushSync();
  } finally {
    source.closeSync();
    target.closeSync();
  }
}

/// Opens the sealed file [from] into the file [to] (replacing it) with
/// [key], a chunk at a time. Throws [SealBroken] when it isn't sealed or
/// doesn't open; [to] is then deleted. Blocks: for another isolate.
void openFileSync(String from, String to, Uint8List key) {
  final source = File(from).openSync();
  final target = File(to).openSync(mode: FileMode.write);
  var done = false;
  try {
    final total = source.lengthSync();
    final header = SealFormat.parseHeader(
      source.readSync(SealFormat.maxHeaderLength),
    );
    if (header == null) throw const SealBroken('not sealed media');
    final length = SealFormat.plainLength(header, total);
    if (length == null) throw const SealBroken('cut off');
    source.setPositionSync(header.length);
    final keyData = SecretKeyData(key);
    final count = SealFormat.chunkCount(header.chunkSize, length);
    for (var i = 0; i < count; i++) {
      final size = min(header.chunkSize, length - i * header.chunkSize);
      final chunk = source.readSync(size + SealFormat.tagLength);
      target.writeFromSync(
        SealFormat.openChunkSync(
          keyData,
          header,
          i,
          chunk,
          last: i == count - 1,
        ),
      );
    }
    target.flushSync();
    done = true;
  } finally {
    source.closeSync();
    target.closeSync();
    // Nothing half opened is left behind.
    if (!done) File(to).deleteSync();
  }
}
