import 'dart:typed_data';

import 'package:idb_shim/idb_shim.dart';

/// Native platforms don't record clips yet, so nothing is persisted there:
/// each launch gets a fresh in-memory database.
IdbFactory newDefaultIdbFactory() => newIdbFactoryMemory();

Future<Uint8List> readMediaBytes(String url) =>
    throw UnsupportedError('Clip recordings are only supported on web');

String createMediaUrl(Uint8List bytes, String mimeType) =>
    throw UnsupportedError('Clip recordings are only supported on web');

Future<bool> requestPersistentStorage() async => false;
