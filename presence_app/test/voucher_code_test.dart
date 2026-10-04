import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/auth/voucher_code.dart';

void main() {
  test('the season, northern meteorological', () {
    expect(seasonOf(DateTime(2026, 1, 15)), 'WINTER');
    expect(seasonOf(DateTime(2026, 3, 1)), 'SPRING');
    expect(seasonOf(DateTime(2026, 7, 4)), 'SUMMER');
    expect(seasonOf(DateTime(2026, 10, 4)), 'AUTUMN');
    expect(seasonOf(DateTime(2026, 12, 1)), 'WINTER');
  });

  test('a suggested code is the season, an animal and a number', () {
    for (var seed = 0; seed < 50; seed++) {
      final code = suggestVoucherCode(
        now: DateTime(2026, 10, 4),
        random: Random(seed),
      );
      final parts = code.split('-');
      expect(parts, hasLength(3), reason: code);
      expect(parts[0], 'AUTUMN');
      expect(voucherAnimals, contains(parts[1]));
      expect(int.parse(parts[2]), inInclusiveRange(100, 9999));
      expect(isValidVoucherCode(code), isTrue, reason: code);
    }
  });

  test('chosen codes: letters, digits and separators, 6 to 40', () {
    expect(isValidVoucherCode('autumn otter_4821'), isTrue);
    expect(isValidVoucherCode('FRIENDS-2026'), isTrue);
    expect(isValidVoucherCode('ABCDE'), isFalse);
    expect(isValidVoucherCode('A' * 41), isFalse);
    expect(isValidVoucherCode('CAFÉ-OTTER-12'), isFalse);
    expect(isValidVoucherCode('OTTER;DROP'), isFalse);
  });
}
