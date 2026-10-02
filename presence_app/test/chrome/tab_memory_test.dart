/// The open tab, kept in the browser tab's `sessionStorage`:
/// `flutter test --platform chrome test/chrome/`.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:presence_app/tab_memory.dart';

void main() {
  test('kept in sessionStorage, under presence.tab', () {
    web.window.sessionStorage.removeItem('presence.tab');
    final memory = TabMemory();
    expect(memory.read(), isNull);
    memory.write('monitoring');
    expect(web.window.sessionStorage.getItem('presence.tab'), 'monitoring');
    // A new one (as after a refresh) reads it back.
    expect(TabMemory().read(), 'monitoring');
  });
}
