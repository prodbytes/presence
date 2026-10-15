import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/device_memory.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/recognition/recognizer.dart';

import 'recognition_test.dart' show FakeRuntime, FakeSampler;

void main() {
  test('memory as people say it: whole or half GB, MB under a GB', () {
    expect(formatMemory(512), '512 MB');
    expect(formatMemory(3700), '3.5 GB');
    expect(formatMemory(4096), '4 GB');
    expect(formatMemory(5800), '5.5 GB');
    expect(formatMemory(7900), '7.5 GB');
    expect(formatMemory(1850), '2 GB');
  });

  test("an event's device memory round-trips through its record", () {
    final e = AppEvent(
      icon: Icons.circle,
      title: 'Door opened',
      time: DateTime(2026, 10, 14, 12),
      deviceId: 'brave_quiet_lamp',
    )..memoryMb = 3700;
    final record = e.toRecord();
    expect(record['memoryMb'], 3700);
    expect(AppEvent.fromRecord(record)!.memoryMb, 3700);
    expect(AppEvent.memoryOf({'memoryMb': 'lots'}), isNull);
    expect(AppEvent.memoryOf({}), isNull);
    e.memoryMb = null;
    expect(e.toRecord(), isNot(contains('memoryMb')));
  });

  test('under ~2 GB a device doesn\'t recognize; unknown, it does', () {
    final bus = AppEventBus();
    final log = EventLog(bus.stream);
    final r = SubjectRecognizer(
      bus: bus,
      log: log,
      config: ConfigController(),
      runtime: FakeRuntime(),
      sampler: FakeSampler(1),
    );
    addTearDown(() {
      r.dispose();
      log.dispose();
      bus.close();
    });
    expect(r.supported, isTrue, reason: 'memory unknown');
    r.totalMemoryMb = 512; // a Raspberry Pi Zero
    expect(r.supported, isFalse);
    r.totalMemoryMb = 1024;
    expect(r.supported, isFalse);
    r.totalMemoryMb = 1850; // a "2 GB" phone, as it reports it
    expect(r.supported, isTrue);
    r.totalMemoryMb = 4096;
    expect(r.supported, isTrue);
  });

  testWidgets('the device list says how much memory each device has', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 14, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileDevices(
            now: () => now,
            devices: [
              (
                id: 'brave_quiet_lamp',
                os: 'Android',
                lastEvent: now.subtract(const Duration(minutes: 5)),
                memoryMb: 3700,
              ),
              (
                id: 'swift_gentle_otter',
                os: 'Linux',
                lastEvent: null,
                memoryMb: null,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Android · 3.5 GB · 5 min ago'), findsOneWidget);
    expect(find.textContaining('GB', findRichText: true), findsOneWidget);
  });
}
