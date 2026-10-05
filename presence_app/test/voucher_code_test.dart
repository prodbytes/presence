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

  test('the season starts and ends with its months', () {
    expect(seasonStart(DateTime(2026, 10, 4, 15)), DateTime(2026, 9));
    expect(seasonEnd(DateTime(2026, 10, 4, 15)), DateTime(2026, 11, 30));
    expect(seasonStart(DateTime(2026, 9)), DateTime(2026, 9));
    expect(seasonEnd(DateTime(2026, 11, 30)), DateTime(2026, 11, 30));
    // Winter spans the new year, and February's end moves.
    expect(seasonStart(DateTime(2027, 2, 10)), DateTime(2026, 12));
    expect(seasonEnd(DateTime(2027, 2, 10)), DateTime(2027, 2, 28));
    expect(seasonStart(DateTime(2027, 12, 5)), DateTime(2027, 12));
    expect(seasonEnd(DateTime(2027, 12, 5)), DateTime(2028, 2, 29));
    expect(seasonStart(DateTime(2026, 4, 1)), DateTime(2026, 3));
    expect(seasonEnd(DateTime(2026, 7, 31)), DateTime(2026, 8, 31));
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
