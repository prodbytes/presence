import 'package:web/web.dart' as web;

/// Replaces the page's address with the same one without its query (and
/// fragment), without reloading.
void clearLaunchQuery() {
  try {
    final location = web.window.location;
    if (location.search.isEmpty) return;
    web.window.history.replaceState(null, '', location.pathname);
  } catch (_) {}
}
