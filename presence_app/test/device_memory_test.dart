import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/identity/device_memory.dart';

void main() {
  test('sizes as people read them', () {
    expect(DeviceMemory.format(512 << 20), '512 MB');
    expect(DeviceMemory.format(1288490189), '1.2 GB');
    expect(DeviceMemory.format(8 << 30), '8 GB');
    expect(DeviceMemory.format((12.4 * (1 << 30)).round()), '12 GB');
  });

  test("Linux's MemAvailable", () {
    // A Raspberry Pi Zero W's, in part.
    const meminfo =
        'MemTotal:         436784 kB\n'
        'MemFree:           27652 kB\n'
        'MemAvailable:     234612 kB\n'
        'Buffers:          20000 kB\n';
    expect(DeviceMemory.memAvailableOf(meminfo), 234612 * 1024);
    expect(
      DeviceMemory.format(DeviceMemory.memAvailableOf(meminfo)!),
      '229 MB',
    );
    expect(DeviceMemory.memAvailableOf('MemTotal: 1 kB\n'), isNull);
  });
}
