import 'dart:typed_data';

Never _noFiles() => throw UnsupportedError('No files on the web');

Future<Uint8List> readHead(String path) async => _noFiles();

void sealFileSync(String from, String to, Uint8List key, String keyId) =>
    _noFiles();

void openFileSync(String from, String to, Uint8List key) => _noFiles();
