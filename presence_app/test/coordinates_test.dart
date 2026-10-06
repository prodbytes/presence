import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/location/coordinates.dart';

void main() {
  void reads(String text, double latitude, double longitude) {
    final at = parseCoordinates(text);
    expect(at.latitude, closeTo(latitude, 1e-6), reason: text);
    expect(at.longitude, closeTo(longitude, 1e-6), reason: text);
  }

  void refuses(String text, [String? message]) => expect(
    () => parseCoordinates(text),
    throwsA(
      isA<FormatException>().having(
        (e) => e.message,
        'message',
        message == null ? isNotEmpty : contains(message),
      ),
    ),
    reason: text,
  );

  test('decimal degrees, however they are apart', () {
    reads('38.7223, -9.1393', 38.7223, -9.1393);
    reads('38.7223,-9.1393', 38.7223, -9.1393);
    reads('38.7223 -9.1393', 38.7223, -9.1393);
    reads('  38.7223;  -9.1393 ', 38.7223, -9.1393);
    reads('(38.7223, -9.1393)', 38.7223, -9.1393);
    reads('-33.8688, 151.2093', -33.8688, 151.2093);
    reads('+38.7, +9', 38.7, 9);
    reads('48 2', 48, 2);
  });

  test('hemispheres, before or after, in either order', () {
    reads('38.7223° N, 9.1393° W', 38.7223, -9.1393);
    reads('38.7223N 9.1393W', 38.7223, -9.1393);
    reads('N 38.7223 W 9.1393', 38.7223, -9.1393);
    reads('s 33.8688, e 151.2093', -33.8688, 151.2093);
    reads('9.1393 W, 38.7223 N', 38.7223, -9.1393);
  });

  test('degrees, minutes and seconds, as Google Maps shows them', () {
    const lat = 38 + 43 / 60 + 20.3 / 3600;
    const lng = -(9 + 8 / 60 + 21.5 / 3600);
    reads('38°43\'20.3"N 9°08\'21.5"W', lat, lng);
    reads('38°43\'20.3"N9°08\'21.5"W', lat, lng);
    reads('38°43′20.3″N, 9°08′21.5″W', lat, lng);
    reads('38º 43\' 20.3" N 9º 08\' 21.5" W', lat, lng);
    reads('38°43.5\'N 9°8\'W', 38 + 43.5 / 60, -(9 + 8 / 60));
  });

  test('not a position, or out of range: says why', () {
    refuses('', 'Paste a latitude and longitude');
    refuses('   ', 'Paste a latitude and longitude');
    refuses('Lisbon', 'Not a position');
    refuses('38.7223', 'Not a position');
    refuses('1, 2, 3', 'Not a position');
    refuses('38.7223, -9.1393, 4', 'Not a position');
    refuses('38.7223,${' ' * 200}-9.1393', 'Not a position');
    refuses('91, 0', 'Latitude must be between -90 and 90');
    refuses('-90.5, 0', 'Latitude must be between -90 and 90');
    refuses('0, 180.01', 'Longitude must be between -180 and 180');
    refuses('38 N, 9 S', 'one latitude');
    refuses('38 E, 9 W', 'one latitude');
    refuses('38°75\'N 9°W', 'Minutes and seconds');
  });

  test('the edges of the range are positions', () {
    reads('90, 180', 90, 180);
    reads('-90, -180', -90, -180);
    reads('0,0', 0, 0);
  });
}
