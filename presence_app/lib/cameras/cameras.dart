/// Device cameras and clip playback, with the implementation picked per
/// platform: browser APIs on web, the `camera` plugin elsewhere.
library;

export 'camera_source.dart';
export 'native_cameras.dart' if (dart.library.js_interop) 'web_cameras.dart';
