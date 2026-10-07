import 'package:flutter/material.dart';

import '../auth/account_sheet.dart';
import '../auth/auth_service.dart';
import '../auth/membership_client.dart';
import '../auth/profile_client.dart';
import '../auth/roles_service.dart';
import '../cloud/cloud_sync.dart';
import '../delete_device.dart';
import '../events.dart';
import '../home_tabs.dart';
import 'dev_mode_label.dart';
import 'home_screen.dart';

/// The home screen's app bar: the "dev" label in DEV, and on the right the
/// tabs and the account button, or, without access, only sign-in (signed
/// out) or sign-up and the account (signed in without a role). Clear over
/// the camera, with a scrim keeping the tabs readable.
class HomeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const HomeAppBar({
    super.key,
    required this.tabs,
    required this.onCamera,
    required this.dev,
    required this.hasAccess,
    required this.signedIn,
    required this.auth,
    required this.roles,
    required this.membership,
    required this.profiles,
    required this.log,
    this.sync,
    this.deviceId,
    this.deleteDevice,
  });

  final HomeTabs tabs;
  final bool onCamera;
  final bool dev;
  final bool hasAccess;
  final bool signedIn;
  final AuthService auth;
  final RolesService roles;
  final MembershipClient membership;
  final ProfileClient profiles;
  final EventLog log;
  final CloudSync? sync;
  final String? deviceId;
  final DeleteDevice? deleteDevice;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  /// [HomeScreen.tabWidth], or less (down to [HomeScreen.minTabWidth])
  /// when the tabs, the buttons after them and the dev label's edge don't
  /// fit the screen.
  double _tabWidth(BuildContext context) {
    // The account button (none in DEV) and the gap after it.
    final buttons = (dev ? 0 : 48) + 4;
    const titleRoom = 12 + 16;
    final fit =
        (MediaQuery.sizeOf(context).width - titleRoom - buttons) /
        tabs.tabs.length;
    return fit.clamp(HomeScreen.minTabWidth, HomeScreen.tabWidth);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      // No title: only the "dev" label, in DEV.
      titleSpacing: 12,
      title: dev
          ? const Row(children: [Flexible(child: DevModeLabel())])
          : null,
      backgroundColor: onCamera ? Colors.transparent : scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      // Over the camera, a scrim keeps the tabs readable.
      flexibleSpace: onCamera
          ? const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xB3000000), Color(0x00000000)],
                ),
              ),
            )
          : null,
      actions: [
        if (!hasAccess && !signedIn) ...[
          SignInAction(auth: auth),
          const SizedBox(width: 12),
        ] else if (!hasAccess) ...[
          // Signed in without a role: only their account, and sign-up.
          if (roles.state == AccessState.checking)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox.square(
                key: Key('checking-access'),
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            SignUpButton(
              auth: auth,
              roles: roles,
              membership: membership,
              profiles: profiles,
            ),
          AccountButton(
            auth: auth,
            roles: roles,
            profiles: profiles,
            log: log,
            deviceId: deviceId,
            deleteDevice: deleteDevice,
          ),
          const SizedBox(width: 4),
        ] else ...[
          SizedBox(
            width: _tabWidth(context) * tabs.tabs.length,
            child: TabBar(
              controller: tabs.controller,
              dividerHeight: 0,
              indicatorSize: TabBarIndicatorSize.tab,
              labelPadding: EdgeInsets.zero,
              tabs: [
                for (final tab in tabs.tabs)
                  Tooltip(
                    message: tab.label,
                    child: Tab(icon: Icon(tab.icon, semanticLabel: tab.label)),
                  ),
              ],
            ),
          ),
          // Account (who's signed in, sign out, about): an action, not a
          // tab.
          if (!dev)
            AccountButton(
              auth: auth,
              sync: sync,
              roles: roles,
              profiles: profiles,
              log: log,
              deviceId: deviceId,
              deleteDevice: deleteDevice,
            ),
          const SizedBox(width: 4),
        ],
      ],
    );
  }
}
