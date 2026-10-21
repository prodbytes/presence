import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/event_filters.dart';
import 'package:presence_app/session_memory.dart';

void main() {
  test('the defaults with nothing kept; each change is kept', () {
    final memory = InMemorySessionMemory();
    final filters = EventFilters.remembered(
      memory,
      showSystemEvents: false,
      showEventsWithNoOne: false,
    );
    addTearDown(filters.dispose);
    expect(filters.showSystemEvents.value, isFalse);
    expect(filters.showEventsWithNoOne.value, isFalse);
    expect(filters.search.value, '');

    filters.search.value = 'garden';
    filters.showEventsWithNoOne.value = true;
    expect(jsonDecode(memory.values[EventFilters.memoryKey]!), {
      'system': false,
      'noOne': true,
      'search': 'garden',
    });
  });

  test('after a refresh: the toggles and the search as they were', () {
    final memory = InMemorySessionMemory()
      ..values[EventFilters.memoryKey] = jsonEncode({
        'system': true,
        'noOne': true,
        'search': 'brave_fox',
      });
    final filters = EventFilters.remembered(
      memory,
      showSystemEvents: false,
      showEventsWithNoOne: false,
    );
    addTearDown(filters.dispose);
    expect(filters.showSystemEvents.value, isTrue);
    expect(filters.showEventsWithNoOne.value, isTrue);
    expect(filters.search.value, 'brave_fox');
  });

  test('a value that does not read: the defaults', () {
    for (final junk in [
      'not json',
      '[1, 2]',
      '{"system": "yes", "search": 3}',
    ]) {
      final memory = InMemorySessionMemory()
        ..values[EventFilters.memoryKey] = junk;
      final filters = EventFilters.remembered(
        memory,
        showSystemEvents: false,
        showEventsWithNoOne: false,
      );
      expect(filters.showSystemEvents.value, isFalse, reason: junk);
      expect(filters.showEventsWithNoOne.value, isFalse, reason: junk);
      expect(filters.search.value, '', reason: junk);
      filters.dispose();
    }
  });
}
