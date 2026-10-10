import 'package:flutter/material.dart';

import '../about.dart';
import '../cloud/device_slots.dart';
import '../events.dart';
import 'account_sheet.dart' show profileDevices;
import 'roles_service.dart';

/// The profile's devices in [log] whose events are hidden here
/// ([EventLog.shows]: a free profile's past its first two), sorted.
List<String> hiddenDevices(
  EventLog log, {
  required String profileId,
  String? thisDevice,
}) => [
  for (final device in profileDevices(
    log.events,
    profileId: profileId,
    thisDevice: thisDevice,
  ))
    if (!log.shows(device)) device,
];

/// What the account's plan gives, Free or Premium, as the account sheet
/// says it, and what's hidden for it:
///
/// - Premium: cloud backup, and up to 50 devices;
/// - Free: up to 2 devices, syncing while online; Premium (cloud backup and
///   up to 50 devices) by signing up at nu01.com, with a Sign up button.
///
/// Past the limit, it says so: this device's events are hidden on the
/// others and theirs here, or how many devices are hidden.
class PlanNotice extends StatelessWidget {
  const PlanNotice({
    super.key,
    required this.premium,
    this.slots,
    this.thisDevice,
    this.hidden = 0,
    LinkOpener? openLink,
  }) : openLink = openLink ?? launchLink;

  /// Whether the profile is premium ([RolesService.isPremium]).
  final bool premium;

  /// The profile's devices, when the auth API has listed them.
  final DeviceSlots? slots;
  final String? thisDevice;

  /// How many of the profile's devices are hidden here.
  final int hidden;

  /// Opens the sign-up link; one that can't open is copied.
  final LinkOpener openLink;

  /// The text for a [premium] profile, or a free one.
  static String planText({required bool premium}) => premium
      ? 'Premium: cloud backup, and up to ${DeviceSlots.premiumLimit} '
            'devices sync.'
      : 'Free: up to ${DeviceSlots.freeLimit} devices sync with each other '
            'while online. Sign up for Premium at nu01.com for cloud backup '
            'and up to ${DeviceSlots.premiumLimit} devices.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final limit =
        slots?.limit ??
        (premium ? DeviceSlots.premiumLimit : DeviceSlots.freeLimit);
    final pastLimit = switch ((slots, thisDevice)) {
      (final slots?, final device?) => !slots.shows(device),
      _ => false,
    };
    final warning = pastLimit
        ? 'This device is past your first $limit: it syncs, but its events '
              'are hidden on your other devices, and theirs here.'
        : hidden > 0
        ? '${hidden == 1 ? '1 more device syncs' : '$hidden more devices sync'}'
              ', but ${hidden == 1 ? 'its' : 'their'} events are hidden: '
              '${premium ? 'Premium' : 'Free'} shows your first $limit.'
        : null;
    return Container(
      key: const Key('plan-notice'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: premium ? scheme.primary : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Row(
            spacing: 8,
            children: [
              Icon(
                premium ? Icons.workspace_premium : Icons.devices_outlined,
                size: 20,
                color: premium ? scheme.primary : scheme.onSurfaceVariant,
              ),
              Text(
                premium ? 'Premium' : 'Free',
                key: const Key('plan-name'),
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          Text(
            planText(premium: premium),
            key: const Key('plan-text'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (warning != null)
            Text(
              warning,
              key: const Key('plan-warning'),
              style: TextStyle(color: scheme.tertiary),
            ),
          if (!premium)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                key: const Key('plan-sign-up'),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Sign up at nu01.com'),
                onPressed: () =>
                    openOrCopyLink(context, DeviceSlots.signUp, openLink),
              ),
            ),
        ],
      ),
    );
  }
}

/// Above the Monitoring tab's events, when devices' events are hidden
/// (a free profile's past its first two): which, and for a free profile
/// where to sign up for Premium. Nothing when nothing's hidden.
class DeviceLimitNotice extends StatelessWidget {
  const DeviceLimitNotice({
    super.key,
    required this.log,
    required this.slots,
    required this.profileId,
    this.thisDevice,
    LinkOpener? openLink,
  }) : openLink = openLink ?? launchLink;

  final EventLog log;

  /// The profile's devices (`CloudSync.deviceSlots`); null hides nothing.
  final DeviceSlots? slots;
  final String? profileId;
  final String? thisDevice;
  final LinkOpener openLink;

  @override
  Widget build(BuildContext context) {
    final slots = this.slots;
    final profileId = this.profileId;
    if (slots == null || profileId == null || log.visibleDevices == null) {
      return const SizedBox.shrink();
    }
    final pastLimit = thisDevice != null && !slots.shows(thisDevice!);
    final hidden = hiddenDevices(
      log,
      profileId: profileId,
      thisDevice: thisDevice,
    ).length;
    if (!pastLimit && hidden == 0) return const SizedBox.shrink();
    final plan = slots.premium ? 'Premium' : 'Free';
    final text = pastLimit
        ? 'Your other devices\' events are hidden on this one: $plan shows '
              'your first ${slots.limit} devices.'
        : '${hidden == 1 ? '1 device\'s' : '$hidden devices\''} events are '
              'hidden: $plan shows your first ${slots.limit} devices.';
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      key: const Key('device-limit-notice'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          spacing: 8,
          children: [
            Icon(Icons.visibility_off_outlined, color: scheme.tertiary),
            Expanded(
              child: Text(
                slots.premium
                    ? text
                    : '$text Sign up at nu01.com for Premium and up to '
                          '${DeviceSlots.premiumLimit}.',
              ),
            ),
            if (!slots.premium)
              TextButton(
                key: const Key('device-limit-sign-up'),
                onPressed: () =>
                    openOrCopyLink(context, DeviceSlots.signUp, openLink),
                child: const Text('Sign up'),
              ),
          ],
        ),
      ),
    );
  }
}
