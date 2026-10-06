/// Reads a latitude and longitude pasted from elsewhere (a maps app, a web
/// page, a message), in degrees:
///
/// - decimal, separated by a comma, a semicolon or spaces:
///   `38.7223, -9.1393`, `38.7223,-9.1393`, `38.7223 -9.1393`;
/// - with hemispheres, before or after: `38.7223° N, 9.1393° W`,
///   `N 38.7223 W 9.1393`;
/// - degrees, minutes and seconds, as Google Maps shows them:
///   `38°43'20.3"N 9°08'21.5"W` (also with ′ and ″, or without seconds).
///
/// Latitude comes first, unless the hemispheres say otherwise
/// (`9.1393 W, 38.7223 N`). Throws a [FormatException] saying what's wrong
/// when [text] isn't a position, or is out of range (latitude -90 to 90,
/// longitude -180 to 180).
({double latitude, double longitude}) parseCoordinates(String text) {
  final normalized = text
      .trim()
      // Typographic primes and quotes, and the ordinal sign used for °.
      .replaceAll(RegExp('[′’‘`´]'), "'")
      .replaceAll(RegExp('[″“”]'), '"')
      .replaceAll("''", '"')
      .replaceAll('º', '°')
      // Wrapped in brackets, as some apps copy them.
      .replaceAll(RegExp(r'^[(\[]\s*|\s*[)\]]$'), '');
  if (normalized.isEmpty) {
    throw const FormatException('Paste a latitude and longitude');
  }
  // No position is this long; and it keeps the patterns' backtracking
  // small.
  if (normalized.length > 100) {
    throw const FormatException(
      'Not a position: use latitude, longitude, e.g. 38.7223, -9.1393',
    );
  }
  final match =
      _suffixed.firstMatch(normalized) ?? _prefixed.firstMatch(normalized);
  if (match == null) {
    throw const FormatException(
      'Not a position: use latitude, longitude, e.g. 38.7223, -9.1393',
    );
  }
  var first = _Coordinate.of(match, 1);
  var second = _Coordinate.of(match, 1 + _groupsPerCoordinate);
  // Longitude first, as the hemispheres say.
  if (first.axis == _Axis.longitude || second.axis == _Axis.latitude) {
    (first, second) = (second, first);
  }
  if (first.axis == _Axis.longitude || second.axis == _Axis.latitude) {
    throw const FormatException(
      'Give one latitude (N or S) and one longitude (E or W)',
    );
  }
  final latitude = first.degrees;
  final longitude = second.degrees;
  if (latitude.abs() > 90) {
    throw const FormatException('Latitude must be between -90 and 90');
  }
  if (longitude.abs() > 180) {
    throw const FormatException('Longitude must be between -180 and 180');
  }
  return (latitude: latitude, longitude: longitude);
}

/// One coordinate: the degrees (signed or not), an optional degree sign,
/// optional minutes (') and seconds ("), and its hemisphere either before
/// ([prefix]) or after, optional. Five groups: the hemisphere before, the
/// degrees, the minutes, the seconds and the hemisphere after; the side
/// not used is an empty group.
String _coordinate({required bool prefix}) =>
    '${prefix ? r'([NSEW])\s*' : '()'}'
    r'''([+-]?\d+(?:\.\d+)?)\s*°?\s*'''
    r'''(?:(\d+(?:\.\d+)?)\s*'\s*)?(?:(\d+(?:\.\d+)?)\s*"\s*)?'''
    '${prefix ? '()' : r'([NSEW])?'}';
const _groupsPerCoordinate = 5;

/// Two coordinates, apart by a comma, a semicolon, a slash or spaces; or
/// by nothing after a hemisphere or a mark (`38°43'20.3"N9°08'21.5"W`).
/// The hemispheres go all before the numbers ([prefix]) or all after.
RegExp _pairPattern({required bool prefix}) => RegExp(
  '^${_coordinate(prefix: prefix)}'
  r'''(?:\s*[,;/]\s*|\s+|(?<=[NSEW"'°]))'''
  '${_coordinate(prefix: prefix)}\$',
  caseSensitive: false,
);
final _suffixed = _pairPattern(prefix: false);
final _prefixed = _pairPattern(prefix: true);

enum _Axis { latitude, longitude, unknown }

class _Coordinate {
  const _Coordinate(this.degrees, this.axis);

  final double degrees;
  final _Axis axis;

  /// The coordinate whose groups start at [at] in [match].
  factory _Coordinate.of(RegExpMatch match, int at) {
    String? hemisphereAt(int group) {
      final h = match.group(group);
      return h == null || h.isEmpty ? null : h.toUpperCase();
    }

    final number = match.group(at + 1)!;
    final minutes = match.group(at + 2);
    final seconds = match.group(at + 3);
    final hemisphere = hemisphereAt(at) ?? hemisphereAt(at + 4);
    var degrees = double.parse(number).abs();
    if (minutes != null || seconds != null) {
      final m = double.parse(minutes ?? '0');
      final s = double.parse(seconds ?? '0');
      if (m >= 60 || s >= 60) {
        throw const FormatException('Minutes and seconds go up to 59');
      }
      degrees += m / 60 + s / 3600;
    }
    final negative =
        number.startsWith('-') || hemisphere == 'S' || hemisphere == 'W';
    return _Coordinate(negative ? -degrees : degrees, switch (hemisphere) {
      'N' || 'S' => _Axis.latitude,
      'E' || 'W' => _Axis.longitude,
      _ => _Axis.unknown,
    });
  }
}
