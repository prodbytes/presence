import 'dart:js_interop';
import 'dart:typed_data';

import 'package:idb_shim/idb_browser.dart';
import 'package:web/web.dart' as web;

/// The browser's IndexedDB.
IdbFactory newDefaultIdbFactory() => idbFactoryBrowser;

/// Reads a recording held at an in-memory (Blob object) URL.
Future<Uint8List> readMediaBytes(String url) async {
  final response = await web.window.fetch(url.toJS).toDart;
  return (await response.arrayBuffer().toDart).toDart.asUint8List();
}

/// Makes stored recording bytes playable again.
String createMediaUrl(Uint8List bytes, String mimeType) =>
    web.URL.createObjectURL(
      web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType)),
    );

/// Asks the browser not to evict this site's data when disk space runs low.
/// Browsers may grant it silently or decline; clips are saved either way.
Future<bool> requestPersistentStorage() async {
  try {
    return (await web.window.navigator.storage.persist().toDart).toDart;
  } catch (_) {
    return false;
  }
}
