import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';

import 'battery.dart';
import 'status_pill.dart';

/// The battery's charge over the camera, as a [StatusPill]: "82 %" with an
/// icon for the level, charging or full. Low (below [low] %) and not
/// charging, a warning icon in the error color. Nothing while there's no
/// reading (browsers without the Battery Status API).
class BatteryPill extends StatelessWidget {
  const BatteryPill({super.key, required this.battery});

  final BatteryController battery;

  /// Below this, the level shows as low.
  static const int low = 15;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: battery,
    builder: (context, _) {
      final reading = battery.reading;
      if (reading == null) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      final level = reading.level.clamp(0, 100);
      final charging = reading.state == BatteryState.charging;
      final isLow = level < low && !charging;
      final icon = switch (reading.state) {
        BatteryState.charging => Icons.battery_charging_full,
        BatteryState.full => Icons.battery_full,
        _ when level < low => Icons.battery_alert,
        _ => _levelIcons[(level * (_levelIcons.length - 1) / 100).round()],
      };
      final state = switch (reading.state) {
        BatteryState.charging => 'charging',
        BatteryState.full => 'full',
        BatteryState.connectedNotCharging => 'plugged in, not charging',
        BatteryState.discharging => 'on battery',
        BatteryState.unknown => null,
      };
      return StatusPill(
        key: const Key('battery'),
        leading: Icon(
          icon,
          size: 18,
          color: isLow ? scheme.error : scheme.onSurface,
        ),
        label: '$level %',
        labelColor: isLow ? scheme.error : null,
        semantics: ['Battery $level %', ?state].join(', '),
      );
    },
  );

  /// From empty to full.
  static const _levelIcons = [
    Icons.battery_0_bar,
    Icons.battery_1_bar,
    Icons.battery_2_bar,
    Icons.battery_3_bar,
    Icons.battery_4_bar,
    Icons.battery_5_bar,
    Icons.battery_6_bar,
    Icons.battery_full,
  ];
}

/// The battery's temperature over the camera, as a [StatusPill]: "31.5 °C",
/// in the error color from [hot]. Only where the platform reports it
/// (Android); nothing elsewhere.
class BatteryTemperaturePill extends StatelessWidget {
  const BatteryTemperaturePill({super.key, required this.battery});

  final BatteryController battery;

  /// From this up, the battery is hot: Android phones start throttling
  /// charging around here.
  static const double hot = 45;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: battery,
    builder: (context, _) {
      final celsius = battery.reading?.celsius;
      if (celsius == null) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      final isHot = celsius >= hot;
      final text = '${celsius.toStringAsFixed(1)} °C';
      return StatusPill(
        key: const Key('battery-temperature'),
        leading: Icon(
          Icons.thermostat,
          size: 18,
          color: isHot ? scheme.error : scheme.onSurface,
        ),
        label: text,
        labelColor: isHot ? scheme.error : null,
        semantics: 'Battery temperature $text${isHot ? ', hot' : ''}',
      );
    },
  );
}
