import 'package:flutter/material.dart';

import '../about.dart';
import '../cloud/device_slots.dart';
import '../events.dart';
import '../l10n/l10n.dart';
import 'account_sheet.dart' show profileDevices;
import 'payments_client.dart';
import 'premium_checkout.dart';
import 'roles_service.dart';
import 'store_billing.dart';
import 'store_plans.dart';

/// The profile's devices in [log] whose events are hidden here
/// ([EventLog.shows]: those past the plan's device limit), sorted.
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

/// [plan]'s name, in [l10n]'s language: Free, Premium or Pro.
String planName(Plan plan, AppLocalizations l10n) => switch (plan) {
  Plan.free => l10n.authPlanFree,
  Plan.premium => l10n.authPlanPremium,
  Plan.pro => l10n.authPlanPro,
};

/// What the account's plan gives, Free, Premium or Pro, as the account
/// sheet says it, and what's hidden for it:
///
/// - Pro: cloud backup, and up to [DeviceSlots.proLimit] devices;
/// - Premium: cloud backup, and up to [DeviceSlots.premiumLimit] devices;
///   on the web ([PurchaseChannel.stripe]) also that Pro has up to
///   [DeviceSlots.proLimit], with a **Pro monthly** and a **Pro yearly**
///   button for each Pro link the payments API has ([links]; none until an
///   admin saves them);
/// - Free: up to [DeviceSlots.freeLimit] devices, syncing while online; and
///   how to get Premium, by [channel]:
///   - the web: cloud backup and up to [DeviceSlots.premiumLimit]
///     devices, US$20 a month, the first week free (and Pro's devices),
///     with a **Premium monthly** and a **Premium yearly** button, each
///     opening its Stripe checkout ([PremiumCheckout]) when the payments
///     API has its link ([links]); without either, **Upgrade to Premium**
///     to nu01.com;
///   - iOS and Android: the store's subscriptions ([StorePlans], from
///     [store]), with the store's prices; never Stripe, nu01.com, a web
///     price or Pro (not sold in the stores yet);
///   - elsewhere (Linux, ...): no purchase buttons.
///
///   And **Check again** for once it's paid.
/// - Premium bought in the store here: **Manage subscription**.
///
/// What's hidden past the limit is said under the device list
/// ([HiddenDevicesLine]).
class PlanNotice extends StatelessWidget {
  const PlanNotice({
    super.key,
    required this.plan,
    this.email,
    this.profileId,
    this.links,
    this.onCheckAgain,
    this.store,
    this._channel,
    LinkOpener? openLink,
  }) : openLink = openLink ?? launchLink;

  /// The member's plan ([RolesService.plan]).
  final Plan plan;

  /// The signed-in account's email and profile, for the checkout.
  final String? email;
  final String? profileId;

  /// The plans' Stripe links (`PaymentsService.links`); null when unknown.
  final PaymentLinks? links;

  /// Checks the roles again ([RolesService.refresh]), after paying; no
  /// Check again button without it.
  final Future<void> Function()? onCheckAgain;

  /// Opens the checkout; one that can't open is copied.
  final LinkOpener openLink;

  /// The App Store's or Google Play's subscriptions, on iOS and Android.
  final StoreBilling? store;

  /// Where Premium is bought in this build ([PurchaseChannel.current]).
  PurchaseChannel get channel => _channel ?? PurchaseChannel.current;
  final PurchaseChannel? _channel;

  /// The text for [plan], in [l10n]'s language (English without); the
  /// web price, and Pro for a free or premium member, on
  /// [PurchaseChannel.stripe] only.
  static String planText({
    required Plan plan,
    AppLocalizations? l10n,
    PurchaseChannel channel = PurchaseChannel.stripe,
  }) {
    final l = l10n ?? lookupAppLocalizations(const Locale('en'));
    final web = channel == PurchaseChannel.stripe;
    return switch (plan) {
      Plan.pro => l.authPlanProText(DeviceSlots.proLimit),
      Plan.premium when web => l.authPlanPremiumProText(
        DeviceSlots.premiumLimit,
        DeviceSlots.proLimit,
      ),
      Plan.premium => l.authPlanPremiumText(DeviceSlots.premiumLimit),
      Plan.free when web => l.authPlanFreeText(
        DeviceSlots.freeLimit,
        DeviceSlots.premiumLimit,
        DeviceSlots.proLimit,
      ),
      Plan.free => l.storePlanFreeText(
        DeviceSlots.freeLimit,
        DeviceSlots.premiumLimit,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final free = plan == Plan.free;
    // The plans' checkouts on the web: Premium's for a free member, Pro's
    // for a premium one (only those an admin saved).
    final checkouts = switch (plan) {
      Plan.free when links?.isEmpty ?? true => [
        ('plan-upgrade', '', l10n.authUpgradePremium),
      ],
      Plan.free => [
        if (links!.monthly.isNotEmpty)
          ('plan-upgrade-monthly', links!.monthly, l10n.authPremiumMonthly),
        if (links!.yearly.isNotEmpty)
          ('plan-upgrade-yearly', links!.yearly, l10n.authPremiumYearly),
      ],
      Plan.premium => [
        if (links?.proMonthly case final link? when link.isNotEmpty)
          ('plan-upgrade-pro-monthly', link, l10n.authProMonthly),
        if (links?.proYearly case final link? when link.isNotEmpty)
          ('plan-upgrade-pro-yearly', link, l10n.authProYearly),
      ],
      Plan.pro => const <(String, String, String)>[],
    };
    return Container(
      key: const Key('plan-notice'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: free ? scheme.outlineVariant : scheme.primary,
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
                free ? Icons.devices_outlined : Icons.workspace_premium,
                size: 20,
                color: free ? scheme.onSurfaceVariant : scheme.primary,
              ),
              Text(
                planName(plan, l10n),
                key: const Key('plan-name'),
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          Text(
            planText(plan: plan, l10n: l10n, channel: channel),
            key: const Key('plan-text'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (free && channel.isStore && store != null)
            StorePlans(
              billing: store!,
              onCheckAgain: onCheckAgain,
              openLink: openLink,
            )
          else if (free && channel != PurchaseChannel.stripe)
            // No store here (or none loaded yet): no purchase buttons.
            TextButton(
              key: const Key('plan-check-again'),
              onPressed: onCheckAgain,
              child: Text(l10n.authCheckAgain),
            )
          else if (!free && channel.isStore && store?.owned != null)
            TextButton(
              key: const Key('store-manage'),
              onPressed: () =>
                  openOrCopyLink(context, store!.manageUrl, openLink),
              child: Text(l10n.storeManage),
            )
          else if (channel == PurchaseChannel.stripe && checkouts.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (key, link, label) in checkouts)
                  FilledButton.icon(
                    key: Key(key),
                    icon: const Icon(Icons.workspace_premium, size: 18),
                    label: Text(label),
                    onPressed: () => openOrCopyLink(
                      context,
                      PremiumCheckout.checkout(
                        email: email,
                        profileId: profileId,
                        link: link,
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

/// Under the Profile tab's device list, when devices' events are hidden
/// (past the plan's device limit), one small muted line: how many are
/// hidden (or that this device doesn't sync), and on the web an
/// **Upgrade** link to the next plan's checkout: Premium's for a free
/// profile, Pro's for a premium one once an admin saved its link. In the
/// store apps, no link (the store's plans are in the plan box just below,
/// and Pro isn't sold there). Nothing when nothing's hidden.
class HiddenDevicesLine extends StatelessWidget {
  const HiddenDevicesLine({
    super.key,
    required this.plan,
    this.hidden = 0,
    this.pastLimit = false,
    this.email,
    this.profileId,
    this.links,
    this._channel,
    LinkOpener? openLink,
  }) : openLink = openLink ?? launchLink;

  final Plan plan;

  /// How many of the profile's devices are hidden here ([hiddenDevices]).
  final int hidden;

  /// Whether this device is past the plan's limit (it doesn't sync).
  final bool pastLimit;

  /// The signed-in account's email and profile, for the checkout.
  final String? email;
  final String? profileId;

  /// The plans' Stripe links: Upgrade opens the next plan's monthly link
  /// (else its yearly's; for Premium, else nu01.com).
  final PaymentLinks? links;
  final LinkOpener openLink;

  /// Where Premium is bought in this build ([PurchaseChannel.current]).
  PurchaseChannel get channel => _channel ?? PurchaseChannel.current;
  final PurchaseChannel? _channel;

  @override
  Widget build(BuildContext context) {
    if (!pastLimit && hidden == 0) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.bodySmall?.copyWith(color: muted);
    // The checkout, on the web only: Premium's for a free profile (its
    // monthly link, else its yearly, else nu01.com), Pro's for a premium
    // one (none until an admin saves its link).
    final String? link = channel != PurchaseChannel.stripe
        ? null
        : switch (plan) {
            Plan.free => switch (links) {
              final l? when l.monthly.isNotEmpty => l.monthly,
              final l? => l.yearly,
              null => '',
            },
            Plan.premium => switch (links) {
              final l? when l.proMonthly.isNotEmpty => l.proMonthly,
              final l? when l.proYearly.isNotEmpty => l.proYearly,
              _ => null,
            },
            Plan.pro => null,
          };
    return Align(
      key: const Key('hidden-devices-line'),
      alignment: AlignmentDirectional.centerStart,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            pastLimit
                ? l10n.authThisDeviceHidden
                : l10n.authHiddenCount(hidden),
            style: style,
          ),
          if (link != null) ...[
            Text(' · ', style: style),
            TextButton(
              key: const Key('hidden-devices-upgrade'),
              style: TextButton.styleFrom(
                foregroundColor: muted,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall?.copyWith(
                  decoration: TextDecoration.underline,
                ),
              ),
              onPressed: () => openOrCopyLink(
                context,
                PremiumCheckout.checkout(
                  email: email,
                  profileId: profileId,
                  link: link,
                ),
                openLink,
              ),
              child: Text(l10n.authUpgrade),
            ),
          ],
        ],
      ),
    );
  }
}
