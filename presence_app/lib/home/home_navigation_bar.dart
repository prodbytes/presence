import 'package:flutter/material.dart';

import '../auth/account_sheet.dart';
import '../auth/auth_service.dart';
import '../home_tabs.dart';

/// The home screen's bottom navigation bar, as on most phone apps: one
/// destination per shown tab ([HomeTabs.tabs]), each an icon over its label,
/// the open one filled and in the accent color (no pill behind it). A tap
/// slides to the tab; the tooltip and screen-reader label are the tab's
/// name. The Profile tab's icon is the signed-in [user]'s avatar, ringed in
/// the accent color while it's open. Its look is the theme's
/// ([NavigationBarThemeData] in `lib/theme.dart`).
class HomeNavigationBar extends StatelessWidget {
  const HomeNavigationBar({super.key, required this.tabs, this.user});

  final HomeTabs tabs;

  /// Who's signed in: the Profile tab's avatar.
  final AuthUser? user;

  /// The controller the bar and the pages share.
  TabController get controller => tabs.controller;

  /// The size of the avatar, as the other tabs' icons.
  static const double avatarSize = 24;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      // A hairline between the page and the bar.
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: NavigationBar(
        selectedIndex: controller.index,
        onDestinationSelected: controller.animateTo,
        destinations: [
          for (final tab in tabs.tabs)
            switch ((tab, user)) {
              (HomeTab.profile, final user?) => NavigationDestination(
                icon: _Avatar(user: user, ring: null),
                selectedIcon: _Avatar(user: user, ring: scheme.primary),
                label: tab.label,
                tooltip: 'Signed in as ${user.identity}',
              ),
              _ => NavigationDestination(
                icon: Icon(
                  tab.icon,
                  key: tab == HomeTab.profile
                      ? const Key('account-button')
                      : null,
                ),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.label,
              ),
            },
        ],
      ),
    );
  }
}

/// The Profile tab's icon: [user]'s avatar, [HomeNavigationBar.avatarSize]
/// across, inside a [ring] when the tab is open.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.user, required this.ring});

  final AuthUser user;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    const size = HomeNavigationBar.avatarSize;
    return Container(
      key: ring == null ? const Key('account-button') : null,
      width: size,
      height: size,
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring ?? Colors.transparent, width: 1.5),
      ),
      child: FittedBox(
        child: UserAvatar(user: user, radius: size / 2),
      ),
    );
  }
}
