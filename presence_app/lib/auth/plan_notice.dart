import 'package:flutter/material.dart';

import '../about.dart';
import '../cloud/device_slots.dart';
import '../events.dart';
import '../l10n/l10n.dart';
import 'account_sheet.dart' show profileDevices;
import 'premium_checkout.dart';
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
/// - Free: up to 2 devices, syncing while online; an **Upgrade to Premium**
///   button (cloud backup and up to 50 devices, US$20 a month, the first
///   week free) that opens the Stripe checkout ([PremiumCheckout]), and
///   **Check again** for once it's paid.
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
    this.email,
    this.profileId,
    this.onCheckAgain,
    LinkOpener? openLink,
  }) : openLink = openLink ?? launchLink;

  /// Whether the profile is premium ([RolesService.isPremium]).
  final bool premium;

  /// The profile's devices, when the auth API has listed them.
  final DeviceSlots? slots;
  final String? thisDevice;

  /// How many of the profile's devices are hidden here.
  final int hidden;

  /// The signed-in account's email and profile, for the checkout.
  final String? email;
  final String? profileId;

  /// Checks the roles again ([RolesService.refresh]), after paying; no
  /// Check again button without it.
  final Future<void> Function()? onCheckAgain;

  /// Opens the checkout; one that can't open is copied.
  final LinkOpener openLink;

  /// The text for a [premium] profile, or a free one, in [l10n]'s
  /// language (English without).
  static String planText({required bool premium, AppLocalizations? l10n}) {
    final l = l10n ?? lookupAppLocalizations(const Locale('en'));
    return premium
        ? l.authPlanPremiumText(DeviceSlots.premiumLimit)
        : l.authPlanFreeText(DeviceSlots.freeLimit, DeviceSlots.premiumLimit);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final limit =
        slots?.limit ??
        (premium ? DeviceSlots.premiumLimit : DeviceSlots.freeLimit);
    final pastLimit = switch ((slots, thisDevice)) {
      (final slots?, final device?) => !slots.shows(device),
      _ => false,
    };
    final warning = pastLimit
        ? l10n.authPastLimit(limit)
        : hidden > 0
        ? l10n.authMoreHidden(
            hidden,
            premium ? l10n.authPlanPremium : l10n.authPlanFree,
            limit,
          )
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
                premium ? l10n.authPlanPremium : l10n.authPlanFree,
                key: const Key('plan-name'),
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          Text(
            planText(premium: premium, l10n: l10n),
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
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const Key('plan-upgrade'),
                  icon: const Icon(Icons.workspace_premium, size: 18),
                  label: Text(l10n.authUpgradePremium),
                  onPressed: () => openOrCopyLink(
                    context,
                    PremiumCheckout.checkout(
                      email: email,
                      profileId: profileId,
                    ),
                    openLink,
                  ),
                ),
                if (onCheckAgain case final checkAgain?)
                  TextButton(
                    key: const Key('plan-check-again'),
                    onPressed: checkAgain,
                    child: Text(l10n.authCheckAgain),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Above the Monitoring tab's events, when devices' events are hidden
/// (a free profile's past its first two): which, and for a free profile
/// an Upgrade button to the Premium checkout. Nothing when nothing's hidden.
class DeviceLimitNotice extends StatelessWidget {
  const DeviceLimitNotice({
    super.key,
    required this.log,
    required this.slots,
    required this.profileId,
    this.thisDevice,
    this.email,
    LinkOpener? openLink,
  }) : openLink = openLink ?? launchLink;

  final EventLog log;

  /// The profile's devices (`CloudSync.deviceSlots`); null hides nothing.
  final DeviceSlots? slots;
  final String? profileId;
  final String? thisDevice;

  /// The signed-in account's email, for the checkout.
  final String? email;
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
    final l10n = context.l10n;
    final plan = slots.premium ? l10n.authPlanPremium : l10n.authPlanFree;
    final text = pastLimit
        ? l10n.authOthersHidden(plan, slots.limit)
        : l10n.authDevicesHidden(hidden, plan, slots.limit);
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
                    : l10n.authPremiumShowsUpTo(text, DeviceSlots.premiumLimit),
              ),
            ),
            if (!slots.premium)
              TextButton(
                key: const Key('device-limit-upgrade'),
                onPressed: () => openOrCopyLink(
                  context,
                  PremiumCheckout.checkout(email: email, profileId: profileId),
                  openLink,
                ),
                child: Text(l10n.authUpgrade),
              ),
          ],
        ),
      ),
    );
  }
}
