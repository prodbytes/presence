/// Platform pieces of storage: the IndexedDB factory, and moving recordings
/// between in-memory URLs and stored bytes.
library;

export 'media_platform_native.dart'
    if (dart.library.js_interop) 'media_platform_web.dart';
