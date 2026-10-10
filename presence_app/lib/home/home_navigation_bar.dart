import 'package:flutter/material.dart';

import '../home_tabs.dart';

/// The home screen's bottom navigation bar, as on most phone apps: one
/// destination per shown tab ([HomeTabs.tabs]), each an icon over its label,
/// the open one filled and in the accent color (no pill behind it). A tap
/// slides to the tab; the tooltip and screen-reader label are the tab's
/// name. Its look is the theme's ([NavigationBarThemeData] in
/// `lib/theme.dart`).
class HomeNavigationBar extends StatelessWidget {
  const HomeNavigationBar({super.key, required this.tabs});

  final HomeTabs tabs;

  /// The controller the bar and the pages share.
  TabController get controller => tabs.controller;

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
            NavigationDestination(
              icon: Icon(tab.icon),
              selectedIcon: Icon(tab.selectedIcon),
              label: tab.label,
            ),
        ],
      ),
    );
  }
}
