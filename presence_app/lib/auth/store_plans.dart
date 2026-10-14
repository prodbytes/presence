import 'package:flutter/material.dart';

import '../about.dart';
import '../l10n/l10n.dart';
import 'api_config.dart';
import 'store_billing.dart';

/// The Premium subscriptions in the App Store or Google Play, for a free
/// member in the iOS or Android app ([StoreBilling]): a button per plan
/// with the store's own price and period, its free trial when the store
/// gives one, Restore purchases (Apple requires it), Manage subscription,
/// how renewal works, and the Terms of Service and Privacy Policy next to
/// the buttons (App Store 3.1.2). No web prices, and nothing of Stripe.
class StorePlans extends StatelessWidget {
  const StorePlans({
    super.key,
    required this.billing,
    this.onCheckAgain,
    LinkOpener? openLink,
    this.siteOverride,
  }) : openLink = openLink ?? launchLink;

  final StoreBilling billing;

  /// Checks the roles again; a Check again button with it.
  final Future<void> Function()? onCheckAgain;

  /// Opens Manage subscription and the legal pages.
  final LinkOpener openLink;

  /// The site whose `/tos` and `/privacy` are linked (tests); defaults to
  /// [ApiConfig.baseUrl].
  final Uri? siteOverride;

  Uri get site => siteOverride ?? ApiConfig.baseUrl;

  /// A [period] after a price ("month", "3 months").
  static String every(AppLocalizations l10n, StorePeriod period) {
    final one = period.count == 1;
    return switch (period.unit) {
      PeriodUnit.day =>
        one ? l10n.storeEveryDay : l10n.storeEveryDays(period.count),
      PeriodUnit.week =>
        one ? l10n.storeEveryWeek : l10n.storeEveryWeeks(period.count),
      PeriodUnit.month =>
        one ? l10n.storeEveryMonth : l10n.storeEveryMonths(period.count),
      PeriodUnit.year =>
        one ? l10n.storeEveryYear : l10n.storeEveryYears(period.count),
    };
  }

  /// A [period]'s length ("1 week").
  static String length(AppLocalizations l10n, StorePeriod period) =>
      switch (period.unit) {
        PeriodUnit.day => l10n.storeDays(period.count),
        PeriodUnit.week => l10n.storeWeeks(period.count),
        PeriodUnit.month => l10n.storeMonths(period.count),
        PeriodUnit.year => l10n.storeYears(period.count),
      };

  static String? messageText(AppLocalizations l10n, StoreMessage? message) =>
      switch (message) {
        null => null,
        StoreMessage.pending => l10n.storePending,
        StoreMessage.purchased => l10n.storePurchased,
        StoreMessage.restored => l10n.storeRestored,
        StoreMessage.nothingToRestore => l10n.storeNothingToRestore,
        StoreMessage.otherAccount => l10n.storeOtherAccount,
        StoreMessage.notVerified => l10n.storeNotVerified,
        StoreMessage.failed => l10n.storeFailed,
        StoreMessage.purchaseFailed => l10n.storePurchaseFailed,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListenableBuilder(
      listenable: billing,
      builder: (context, _) {
        final message = messageText(l10n, billing.message);
        return Column(
          key: const Key('store-plans'),
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            if (billing.loading && billing.plans.isEmpty)
              Text(l10n.storeLoading, style: muted)
            else if (!billing.available)
              Text(
                l10n.storeUnavailable,
                key: const Key('store-unavailable'),
                style: muted,
              ),
            for (final plan in billing.plans) ...[
              FilledButton.icon(
                key: Key('store-buy-${plan.productId}'),
                icon: const Icon(Icons.workspace_premium, size: 18),
                label: Text(
                  plan.period == null
                      ? '${_name(l10n, plan)}: ${plan.price}'
                      : l10n.storePlanPrice(
                          _name(l10n, plan),
                          plan.price,
                          every(l10n, plan.period!),
                        ),
                ),
                onPressed: billing.busy || !billing.available
                    ? null
                    : () => billing.buy(plan),
              ),
              if ((plan.trial, plan.period) case (final trial?, final period?))
                Text(
                  l10n.storeTrial(
                    length(l10n, trial),
                    plan.price,
                    every(l10n, period),
                  ),
                  key: Key('store-trial-${plan.productId}'),
                  style: muted,
                ),
            ],
            if (message != null)
              Text(
                message,
                key: const Key('store-message'),
                style: TextStyle(color: theme.colorScheme.tertiary),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  key: const Key('store-restore'),
                  onPressed: billing.busy || !billing.available
                      ? null
                      : billing.restore,
                  child: Text(l10n.storeRestore),
                ),
                TextButton(
                  key: const Key('store-manage'),
                  onPressed: () =>
                      openOrCopyLink(context, billing.manageUrl, openLink),
                  child: Text(l10n.storeManage),
                ),
                if (onCheckAgain case final checkAgain?)
                  TextButton(
                    key: const Key('plan-check-again'),
                    onPressed: checkAgain,
                    child: Text(l10n.authCheckAgain),
                  ),
              ],
            ),
            Text(l10n.storeRenews(billing.channel.storeName), style: muted),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  key: const Key('store-terms'),
                  onPressed: () =>
                      openOrCopyLink(context, site.resolve('/tos'), openLink),
                  child: Text(l10n.storeTerms),
                ),
                TextButton(
                  key: const Key('store-privacy'),
                  onPressed: () => openOrCopyLink(
                    context,
                    site.resolve('/privacy'),
                    openLink,
                  ),
                  child: Text(l10n.storePrivacy),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _name(AppLocalizations l10n, StorePlan plan) =>
      plan.productId == StoreProducts.yearly
      ? l10n.storePlanYearly
      : l10n.storePlanMonthly;
}
