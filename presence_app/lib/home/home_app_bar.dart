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

/// The home screen's app bar: on the left the open screen's name, bold
/// (none over the camera), and the "dev" label in DEV; on the right the
/// account button, or, without access, only sign-in (signed out) or sign-up
/// and the account (signed in without a role). The tabs are in the bottom
/// navigation bar ([HomeNavigationBar]). Clear over the camera, with a scrim
/// keeping the buttons readable.
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      // The screen's name (none over the camera), then the "dev" label in
      // DEV.
      titleSpacing: 16,
      title: Row(
        children: [
          if (hasAccess && !onCamera) ...[
            Text(tabs.current.title, key: const Key('screen-title')),
            if (dev) const SizedBox(width: 12),
          ],
          if (dev) const Flexible(child: DevModeLabel()),
        ],
      ),
      backgroundColor: onCamera ? Colors.transparent : scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      // Over the camera, a scrim keeps the buttons readable.
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
