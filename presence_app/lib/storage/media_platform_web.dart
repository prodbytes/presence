import 'dart:js_interop';
import 'dart:typed_data';

import 'package:idb_shim/idb_browser.dart';
import 'package:web/web.dart' as web;

import 'event_store.dart';
import 'media_store.dart';

/// The browser's IndexedDB.
Future<IdbFactory> newDefaultIdbFactory() async => idbFactoryBrowser;

/// Recordings live in IndexedDB alongside the rest of the data.
MediaStore newDefaultMediaStore(EventStore store) => IdbMediaStore(store);

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
