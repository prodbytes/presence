/// Sealing and opening files, a chunk at a time (off the web: the web has
/// no files).
library;

export 'seal_files_io.dart' if (dart.library.js_interop) 'seal_files_web.dart';
