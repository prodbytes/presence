/// Google's own sign-in button on web (Google Identity Services renders it);
/// elsewhere there's none, and the app's button calls `signIn`.
library;

export 'google_button_stub.dart'
    if (dart.library.js_interop) 'google_button_web.dart';
