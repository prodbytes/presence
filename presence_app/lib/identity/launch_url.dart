/// Forgets the link the app was opened with, once handled, so a reload
/// doesn't handle it again: drops the page's query on web; nothing on
/// Android and iOS.
library;

export 'launch_url_stub.dart'
    if (dart.library.js_interop) 'launch_url_web.dart';
