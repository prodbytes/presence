import 'package:flutter/foundation.dart';

/// Where the app's API (`/api/*`, e.g. the auth API) lives.
abstract final class ApiConfig {
  /// `API_BASE_URL` at build time. Web leaves it empty and uses the page's
  /// own origin (CloudFront serves the app and `/api/*` together); Android
  /// and iOS have no page, so they default to production.
  static const String _base = String.fromEnvironment('API_BASE_URL');

  static Uri get baseUrl {
    if (_base.isNotEmpty) return Uri.parse(_base);
    return kIsWeb ? Uri.base : Uri.parse('https://presence.nu01.com/');
  }
}
