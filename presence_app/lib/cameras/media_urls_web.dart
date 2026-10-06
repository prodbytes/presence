import 'package:web/web.dart' as web;

/// Live recordings are Blob object URLs, held in memory until revoked.
const bool hasMediaUrls = true;

/// Frees a Blob object URL's memory.
void revokeMediaUrl(String url) => web.URL.revokeObjectURL(url);
