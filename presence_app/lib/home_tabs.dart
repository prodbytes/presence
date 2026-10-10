import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'tab_memory.dart';

/// The top-level destinations, in the bottom navigation bar.
enum HomeTab {
  camera('Camera', Icons.videocam_outlined, Icons.videocam),
  monitoring('Monitoring', Icons.monitor_heart_outlined, Icons.monitor_heart),
  settings('Settings', Icons.settings_outlined, Icons.settings),

  /// Admins only, when Settings' switch shows it (on by default in DEV,
  /// whose anonymous user is a root); after the always-shown tabs, so they
  /// keep their index.
  log('Log', Icons.receipt_long_outlined, Icons.receipt_long),

  /// Signed-in admins only (not DEV: there are no accounts): membership
  /// requests and voucher codes (`AdminView`). Before Account; with the
  /// Log tab hidden it takes the Log's place, so map a tab to its controller index
  /// through the shown tabs ([HomeTabs.indexOf]), never by [HomeTab.index]
  /// alone.
  admin(
    'Admin',
    Icons.admin_panel_settings_outlined,
    Icons.admin_panel_settings,
  ),

  /// Signed-in users with access, not DEV (there are no accounts): who's
  /// signed in, the profile's devices, sign-out and about (`AccountSheet`,
  /// as a page). Always last, as phone apps put "You"; its icon is the
  /// user's avatar when there is one.
  account('Account', Icons.person_outline, Icons.person);

  const HomeTab(this.label, this.icon, this.selectedIcon);

  final String label;

  /// Outlined, while another tab is open.
  final IconData icon;

  /// Filled, while this tab is open.
  final IconData selectedIcon;

  /// The tabs shown, in [HomeTab] order: the Log tab with [log], the Admin
  /// tab with [admin], the Account tab with [account], the others always.
  static List<HomeTab> shown({
    required bool log,
    required bool admin,
    bool account = false,
  }) => [
    for (final tab in values)
      if (switch (tab) {
        HomeTab.log => log,
        HomeTab.admin => admin,
        HomeTab.account => account,
        _ => true,
      })
        tab,
  ];
}

/// The home screen's tabs: which show ([tabs]), the [controller] the
/// navigation bar and its pages share, and the tab remembered across refreshes
/// ([TabMemory]), opened once there's access ([restore]).
class HomeTabs {
  HomeTabs({
    required this.vsync,
    required this.memory,
    required List<HomeTab> shown,
    required this.onChanged,
  }) {
    controller = _newController(shown, HomeTab.camera);
    _restoreTab = HomeTab.values.asNameMap()[memory.read()];
  }

  final TickerProvider vsync;

  /// Where the open tab is remembered.
  final TabMemory memory;

  /// Called on every change of the controller (a tab picked).
  final VoidCallback onChanged;

  /// The controller for the [tabs]: what the navigation bar and its pages
  /// show.
  late TabController controller;

  /// The tabs [controller] was made for, in order, so the navigation bar and
  /// its pages always match the controller's length.
  late List<HomeTab> tabs;

  /// The tab open before a refresh, until it can show ([restore]).
  HomeTab? _restoreTab;

  /// The open tab.
  HomeTab get current => tabs[controller.index];

  /// [tab]'s index in the navigation bar, or -1 when it isn't shown.
  int indexOf(HomeTab tab) => tabs.indexOf(tab);

  /// Whether [tab] is shown.
  bool shows(HomeTab tab) => tabs.contains(tab);

  /// Switches to [tab] at once, if it's shown.
  void jumpTo(HomeTab tab) {
    final index = indexOf(tab);
    if (index >= 0) controller.index = index;
  }

  /// Slides to [tab], if it's shown.
  void animateTo(HomeTab tab) {
    final index = indexOf(tab);
    if (index >= 0) controller.animateTo(index);
  }

  /// A controller for [shown], open on [tab] (or the camera, if it isn't
  /// shown).
  TabController _newController(List<HomeTab> shown, HomeTab tab) {
    tabs = shown;
    return TabController(
      length: shown.length,
      initialIndex: shown.indexOf(tab).clamp(0, shown.length - 1),
      vsync: vsync,
    )..addListener(_onTab);
  }

  void _onTab() {
    if (!controller.indexIsChanging) memory.write(current.name);
    onChanged();
  }

  /// Shows [shown] (the Log and Admin tabs come and go with the roles and
  /// the Log switch), staying on the same tab or, if it goes, the nearest
  /// one before it. Returns whether the tabs changed.
  bool sync(List<HomeTab> shown) {
    if (listEquals(shown, tabs)) return false;
    final old = controller..removeListener(_onTab);
    final stay = tabs
        .take(old.index + 1)
        .lastWhere(shown.contains, orElse: () => HomeTab.camera);
    controller = _newController(shown, stay);
    // The pages let go of it in this frame's build.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    return true;
  }

  /// Opens the tab remembered from before a refresh, once [hasAccess]
  /// (access is known only once the roles load).
  void restore({required bool hasAccess}) {
    final tab = _restoreTab;
    if (tab == null || !hasAccess) return;
    _restoreTab = null;
    jumpTo(tab);
  }

  void dispose() {
    controller
      ..removeListener(_onTab)
      ..dispose();
  }
}
