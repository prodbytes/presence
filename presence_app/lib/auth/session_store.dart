/// Where a signed-in session is remembered across reloads: the browser's
/// localStorage on web; nothing on Android and iOS, whose Google SDKs keep
/// the session themselves.
library;

export 'session_store_stub.dart'
    if (dart.library.js_interop) 'session_store_web.dart';
