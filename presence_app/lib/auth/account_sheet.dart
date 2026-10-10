import 'package:flutter/material.dart';

import '../about.dart';
import '../camera_feeds.dart' show describeAge;
import '../cloud/cloud_sync.dart';
import '../delete_device.dart';
import '../device_events.dart';
import '../cloud/live_sync.dart';
import '../connectivity.dart';
import '../device_presence.dart';
import '../events.dart';
import '../identity/device_os.dart';
import 'auth_service.dart';
import 'linked_accounts_sheet.dart';
import 'membership_client.dart';
import 'plan_notice.dart';
import 'profile_client.dart';
import 'roles_service.dart';
import 'voucher_code.dart';

/// The app bar's account button: the user's avatar when signed in, a person
/// icon otherwise. Opens [AccountSheet].
class AccountButton extends StatelessWidget {
  const AccountButton({
    super.key,
    required this.auth,
    this.sync,
    this.roles,
    this.profiles,
    this.log,
    this.deviceId,
    this.deleteDevice,
  });

  final AuthService auth;
  final CloudSync? sync;

  /// Deletes another of the profile's devices from the sheet's list.
  final DeleteDevice? deleteDevice;

  /// With [profiles], the sheet offers Linked accounts.
  final RolesService? roles;
  final ProfileClient? profiles;

  /// The events the sheet's device list comes from, and this device's ID.
  final EventLog? log;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final user = auth.user;
        return IconButton(
          key: const Key('account-button'),
          tooltip: user == null ? 'Sign in' : 'Signed in as ${user.identity}',
          icon: user == null
              ? const Icon(Icons.person)
              : UserAvatar(user: user, radius: 14),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            // Room to scroll a long device list.
            isScrollControlled: true,
            // A device's ID shows its events ([ShowDeviceEvents]).
            builder: (_) => ShowDeviceEvents.capture(
              context,
              AccountSheet(
                auth: auth,
                sync: sync,
                roles: roles,
                profiles: profiles,
                log: log,
                deviceId: deviceId,
                deleteDevice: deleteDevice,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The app bar's sign-in control while signed out: "Sign in with Google"
/// (Google's own button on web). Nothing while the launch check runs; if
/// sign-in isn't set up, a person icon whose sheet says so.
class SignInAction extends StatelessWidget {
  const SignInAction({super.key, required this.auth});

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    if (auth.checking) return const SizedBox.shrink();
    if (!auth.available) return AccountButton(auth: auth);
    return Center(
      child:
          auth.buildSignInButton() ??
          FilledButton.icon(
            key: const Key('google-sign-in'),
            icon: const Icon(Icons.login, size: 18),
            label: const Text('Sign in with Google'),
            onPressed: auth.signIn,
          ),
    );
  }
}

/// Sign in with Google, or show who is signed in, their profile and its
/// devices, and offer sign-out; then what Presence is ([AboutParagraph]).
/// A bottom sheet from [AccountButton] (signed in without access), or the
/// Profile tab's page.
class AccountSheet extends StatelessWidget {
  const AccountSheet({
    super.key,
    required this.auth,
    this.sync,
    this.roles,
    this.profiles,
    this.log,
    this.deviceId,
    this.deleteDevice,
    this.openLink,
    this.now,
  });

  /// Deletes another of the profile's devices (each one's delete button in
  /// the list, after a confirmation): its events are hidden on every
  /// device. None: no delete buttons.
  final DeleteDevice? deleteDevice;

  final AuthService auth;

  /// The time the devices' last events are counted from (tests); defaults
  /// to the clock.
  final DateTime Function()? now;

  /// Opens the about paragraph's link (tests); defaults to the browser.
  final LinkOpener? openLink;

  /// Cloud uploads, when configured: their status shows under the email.
  final CloudSync? sync;

  /// With both, a Linked accounts button (see [LinkedAccountsSheet]).
  final RolesService? roles;
  final ProfileClient? profiles;

  /// The events whose device IDs list the profile's devices (see
  /// [profileDevices]), and this device's ID, listed first.
  final EventLog? log;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      // Cloud and live sync too: this device's dot shows its connectivity.
      listenable: Listenable.merge([auth, ?roles, ?log, ?sync, ?sync?.live]),
      builder: (context, _) {
        final user = auth.user;
        final error = auth.error;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              key: const Key('account-sheet'),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!auth.available) ...[
                    Icon(
                      Icons.lock_outline,
                      size: 40,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      auth.unavailableReason ?? 'Sign-in is unavailable.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ] else if (user == null) ...[
                    Text(
                      'Sign in to Presence',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    auth.buildSignInButton() ??
                        FilledButton.icon(
                          key: const Key('google-sign-in'),
                          icon: const Icon(Icons.login),
                          label: const Text('Sign in with Google'),
                          onPressed: auth.signIn,
                        ),
                  ] else ...[
                    UserAvatar(user: user, radius: 32),
                    const SizedBox(height: 12),
                    if (user.name case final name?)
                      Text(name, style: theme.textTheme.titleMedium),
                    Text(
                      user.email,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    if (roles case final roles?) ...[
                      const SizedBox(height: 8),
                      AccountRoles(roles: roles),
                      const SizedBox(height: 12),
                      ConnectivityIndicator(roles: roles, sync: sync),
                    ],
                    if (sync case final sync?) ...[
                      const SizedBox(height: 8),
                      CloudSyncStatus(sync: sync),
                    ],
                    if (roles?.profile case final profile?) ...[
                      const SizedBox(height: 16),
                      // Pings the devices while the list shows, for their
                      // presence dots.
                      PresencePinger(
                        live: sync?.live,
                        builder: (_) => ProfileDevices(
                          profile: profile,
                          devices: profileDeviceDetails(
                            log?.events ?? const [],
                            profileId: profile,
                            thisDevice: deviceId,
                          ),
                          thisDevice: deviceId,
                          hidden: switch (log) {
                            final log? => hiddenDevices(
                              log,
                              profileId: profile,
                              thisDevice: deviceId,
                            ).toSet(),
                            null => const {},
                          },
                          now: now,
                          live: sync?.live,
                          thisPresence: switch (roles) {
                            final roles? => Connectivity.of(
                              roles,
                              sync,
                            ).presence,
                            null => null,
                          },
                          onDelete: switch (deleteDevice) {
                            final delete? =>
                              (id) => deleteDeviceAfterConfirming(
                                context,
                                deviceId: id,
                                events: deviceEventCount(
                                  log?.events ?? const [],
                                  deviceId: id,
                                  profileId: profile,
                                ),
                                delete: delete,
                              ),
                            null => null,
                          },
                        ),
                      ),
                    ],
                    // Free or Premium, and what each gives, under the devices
                    // it limits; not in DEV, where nothing syncs.
                    if (roles case final roles?
                        when roles.hasAccess &&
                            roles.mode != ExecutionMode.dev) ...[
                      const SizedBox(height: 12),
                      PlanNotice(
                        premium: roles.isPremium,
                        slots: sync?.deviceSlots,
                        thisDevice: deviceId,
                        hidden: switch ((log, roles.profile)) {
                          (final log?, final profile?) => hiddenDevices(
                            log,
                            profileId: profile,
                            thisDevice: deviceId,
                          ).length,
                          _ => 0,
                        },
                        openLink: openLink,
                      ),
                    ],
                    if ((roles, profiles) case (
                      final roles?,
                      final profiles?,
                    )) ...[
                      const SizedBox(height: 8),
                      LinkedAccountsButton(
                        auth: auth,
                        roles: roles,
                        profiles: profiles,
                        sync: sync,
                      ),
                    ],
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      key: const Key('sign-out'),
                      icon: const Icon(Icons.logout),
                      label: const Text('Sign out'),
                      // Close the sheet first (as a page of the tabs there's
                      // nothing to close): signing out swaps the whole app
                      // for the sign-in screen.
                      onPressed: () {
                        Navigator.of(context).maybePop();
                        auth.signOut();
                      },
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  AboutParagraph(openLink: openLink),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Every device ID in [events] of [profileId] (the profile's devices, synced
/// from its cloud folder), sorted, with [thisDevice] first even before it
/// has an event.
List<String> profileDevices(
  Iterable<AppEvent> events, {
  required String profileId,
  String? thisDevice,
}) {
  final others = {
    for (final event in events)
      if (event.profileId == profileId) ?event.deviceId,
  }..remove(thisDevice);
  return [?thisDevice, ...others.toList()..sort()];
}

/// One of the profile's devices, as the account sheet lists it: its ID,
/// its operating system ([AppEvent.os] of its latest event that has one;
/// [DeviceOs.current] for this device when none does) and the time of its
/// latest event (null: none yet).
typedef ProfileDevice = ({String id, String? os, DateTime? lastEvent});

/// [profileDevices], each with its operating system and latest event (see
/// [ProfileDevice]). Events not saved yet, without a device ID, are
/// [thisDevice]'s.
List<ProfileDevice> profileDeviceDetails(
  Iterable<AppEvent> events, {
  required String profileId,
  String? thisDevice,
}) {
  final latest = <String, DateTime>{};
  final os = <String, (DateTime, String)>{};
  for (final event in events) {
    if (event.profileId != profileId) continue;
    final device = EventTimeline.deviceOf(event, thisDevice);
    if (device == null) continue;
    final time = event.time;
    final seen = latest[device];
    if (seen == null || time.isAfter(seen)) latest[device] = time;
    final name = event.os;
    final named = os[device];
    if (name != null && (named == null || time.isAfter(named.$1))) {
      os[device] = (time, name);
    }
  }
  return [
    for (final id in profileDevices(
      events,
      profileId: profileId,
      thisDevice: thisDevice,
    ))
      (
        id: id,
        os: os[id]?.$2 ?? (id == thisDevice ? DeviceOs.current : null),
        lastEvent: latest[id],
      ),
  ];
}

/// [time] to the second, as `2026-10-06 14:05:09`, in local time.
String exactTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  final t = time.toLocal();
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// The profile's ID and its devices, each with its operating system's
/// icon and name and how long ago its latest event was (the exact time in
/// a tooltip). IDs are selectable to copy; a tapped device ID shows its
/// events ([DeviceEventsLink]).
class ProfileDevices extends StatelessWidget {
  const ProfileDevices({
    super.key,
    required this.profile,
    required this.devices,
    this.thisDevice,
    this.now,
    this.onDelete,
    this.live,
    this.thisPresence,
    this.hidden = const {},
  });

  /// The devices whose events are hidden here (past the plan's limit),
  /// labelled "hidden".
  final Set<String> hidden;

  /// [thisDevice]'s presence dot, when given: its connectivity
  /// ([Connectivity.presence]), as the account sheet's indicator shows it.
  /// Otherwise green while live sync is connected.
  final DevicePresence? thisPresence;

  /// Live sync: which devices answer its pings, for each device's
  /// presence dot ([DevicePresence]).
  final LiveSync? live;

  final String profile;
  final List<ProfileDevice> devices;

  /// Asks to delete a device (its delete button). Every device but
  /// [thisDevice] has one, when set: this device's next event would bring
  /// it back.
  final ValueChanged<String>? onDelete;

  /// Labelled "this device" in the list.
  final String? thisDevice;

  /// The time latest events are counted from; defaults to the clock.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final at = (now ?? DateTime.now)();
    final available = liveAvailable(live);
    return Column(
      key: const Key('profile-devices'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text('Profile', style: muted),
        SelectableText(
          profile,
          key: const Key('profile-id'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          devices.length == 1 ? '1 device' : '${devices.length} devices',
          style: muted,
        ),
        for (final device in devices)
          Row(
            key: Key('profile-device-${device.id}'),
            spacing: 8,
            children: [
              Tooltip(
                message: device.os ?? 'Operating system unknown',
                child: Icon(
                  DeviceOs.iconOf(device.os),
                  key: Key('profile-device-os-${device.id}'),
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A Wrap, not a Row: at a large system font
                    // "this device" moves under the ID instead of
                    // overflowing.
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PresenceDot(
                          key: Key('presence-${device.id}'),
                          presence: switch (thisPresence) {
                            final presence? when device.id == thisDevice =>
                              presence,
                            _ => DevicePresence.of(
                              answeredAt: live?.seenOf(device.id),
                              lastEvent: device.lastEvent,
                              now: at,
                              liveAvailable: available,
                              thisDevice: device.id == thisDevice,
                              connected: live?.state == LiveSyncState.connected,
                            ),
                          },
                        ),
                        DeviceEventsLink(
                          device: device.id,
                          builder: (context, onTap) => SelectableText(
                            device.id,
                            key: Key('profile-device-id-${device.id}'),
                            onTap: onTap,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: onTap == null
                                  ? null
                                  : theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        if (device.id == thisDevice)
                          Text('this device', style: muted),
                        if (hidden.contains(device.id))
                          Tooltip(
                            message:
                                'Past the plan\'s device limit: it syncs, '
                                'but its events are hidden here',
                            child: Text(
                              'hidden',
                              key: Key('profile-device-hidden-${device.id}'),
                              style: muted.copyWith(
                                color: theme.colorScheme.tertiary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    _withExactTime(
                      device.lastEvent,
                      Text.rich(
                        key: Key('profile-device-last-${device.id}'),
                        TextSpan(
                          children: [
                            if (device.os case final os?)
                              TextSpan(text: '$os · '),
                            TextSpan(
                              text: switch (device.lastEvent) {
                                null => 'No events',
                                final last => describeAge(at.difference(last)),
                              },
                            ),
                          ],
                        ),
                        style: small,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (onDelete case final onDelete? when device.id != thisDevice)
                IconButton(
                  key: Key('profile-device-delete-${device.id}'),
                  tooltip: 'Delete ${device.id}',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => onDelete(device.id),
                ),
            ],
          ),
      ],
    );
  }

  /// [child] with the exact time of [last] in a tooltip, when there is one.
  /// The whole line carries it: a [WidgetSpan] around just the age would
  /// scale its text twice at a large system font size.
  static Widget _withExactTime(DateTime? last, Widget child) =>
      last == null ? child : Tooltip(message: exactTime(last), child: child);
}

/// Opens [LinkedAccountsSheet].
class LinkedAccountsButton extends StatelessWidget {
  const LinkedAccountsButton({
    super.key,
    required this.auth,
    required this.roles,
    required this.profiles,
    this.sync,
    this.label = 'Linked accounts',
  });

  final AuthService auth;
  final RolesService roles;
  final ProfileClient profiles;
  final CloudSync? sync;
  final String label;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const Key('linked-accounts'),
    icon: const Icon(Icons.link),
    label: Text(label),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Room for the keyboard under the code field.
      isScrollControlled: true,
      builder: (_) => LinkedAccountsSheet(
        auth: auth,
        roles: roles,
        profiles: profiles,
        sync: sync,
      ),
    ),
  );
}

/// The user's photo, or their initial when there's none (or it fails).
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.user, required this.radius});

  final AuthUser user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = user.label.characters.first.toUpperCase();
    final photo = user.photoUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      foregroundImage: photo == null ? null : NetworkImage(photo),
      onForegroundImageError: photo == null ? null : (_, _) {},
      child: Text(initial, style: TextStyle(fontSize: radius * 0.9)),
    );
  }
}

/// The signed-in user's roles, always shown under their email: a small
/// chip per role, named for people ([labelOf]: Member, Admin, Root,
/// Premium), the role's ID in its tooltip; "No roles yet" without any, and
/// "Checking roles…" while the auth API is asked. The anonymous role isn't
/// shown (it's everyone's before signing in).
class AccountRoles extends StatelessWidget {
  const AccountRoles({super.key, required this.roles});

  final RolesService roles;

  /// What a role is called here; another role keeps its ID.
  static String labelOf(String role) => switch (role) {
    userRole => 'Member',
    adminRole => 'Admin',
    rootRole => 'Root',
    premiumRole => 'Premium',
    _ => role,
  };

  /// The order they're shown in: as listed in [labelOf], then the others.
  static int _rank(String role) => switch (role) {
    userRole => 0,
    premiumRole => 1,
    adminRole => 2,
    rootRole => 3,
    _ => 4,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium;
    final shown =
        [
          for (final role in roles.roles)
            if (role != anonymousRole) role,
        ]..sort((a, b) {
          final byRank = _rank(a).compareTo(_rank(b));
          return byRank != 0 ? byRank : a.compareTo(b);
        });
    Widget note(String text) =>
        Text(text, style: style?.copyWith(color: scheme.onSurfaceVariant));
    return Semantics(
      container: true,
      label: shown.isEmpty ? null : 'Roles: ${shown.map(labelOf).join(', ')}',
      child: KeyedSubtree(
        key: const Key('account-roles'),
        child: switch (roles.state) {
          AccessState.starting ||
          AccessState.checking when shown.isEmpty => note('Checking roles…'),
          _ when shown.isEmpty => note('No roles yet'),
          _ => Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final role in shown)
                Tooltip(
                  message: role,
                  excludeFromSemantics: true,
                  child: Container(
                    key: Key('account-role-$role'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ExcludeSemantics(
                      child: Text(labelOf(role), style: style),
                    ),
                  ),
                ),
            ],
          ),
        },
      ),
    );
  }
}

/// One line about cloud uploads: syncing, synced (and how many), or why not
/// (with a Retry button once syncing has stopped). A free profile has no
/// cloud backup: the line says its devices sync with each other instead
/// ([PlanNotice] says what Premium adds).
class CloudSyncStatus extends StatelessWidget {
  const CloudSyncStatus({super.key, required this.sync});

  final CloudSync sync;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final free = !sync.premium;
        final (icon, text, color) = switch (sync.state) {
          CloudSyncState.syncing || CloudSyncState.synced when free => (
            Icons.devices_outlined,
            'Your devices sync with each other while online',
            scheme.onSurfaceVariant,
          ),
          CloudSyncState.off => (
            Icons.cloud_off_outlined,
            'Cloud backup is off',
            scheme.onSurfaceVariant,
          ),
          CloudSyncState.syncing => (
            Icons.cloud_upload_outlined,
            'Uploading…',
            scheme.onSurfaceVariant,
          ),
          CloudSyncState.synced => (
            Icons.cloud_done_outlined,
            switch ((sync.uploaded, sync.downloaded)) {
              (0, 0) => 'Clips and events are backed up',
              (final up, 0) => 'Backed up ($up uploaded)',
              (0, final down) => 'Backed up ($down restored)',
              (final up, final down) =>
                'Backed up ($up uploaded, $down restored)',
            },
            scheme.onSurfaceVariant,
          ),
          CloudSyncState.error => (
            Icons.cloud_off_outlined,
            sync.error ?? 'Upload failed',
            scheme.error,
          ),
        };
        return Row(
          key: const Key('cloud-sync-status'),
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Icon(icon, size: 18, color: color),
            Flexible(
              child: Text(text, style: TextStyle(color: color)),
            ),
            if (sync.stopped)
              TextButton(
                key: const Key('cloud-sync-retry'),
                onPressed: sync.retry,
                child: const Text('Retry'),
              ),
          ],
        );
      },
    );
  }
}

/// Signed in without access: the sign-up icon. Its sheet sends the user to
/// subscribe at nu01.com, lets them redeem a voucher code, and check again.
class SignUpButton extends StatelessWidget {
  const SignUpButton({
    super.key,
    required this.auth,
    required this.roles,
    required this.membership,
    this.profiles,
    this.openLink,
  });

  final AuthService auth;
  final RolesService roles;
  final MembershipClient membership;
  final ProfileClient? profiles;

  /// Opens the subscription page; [launchLink] by default.
  final LinkOpener? openLink;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('sign-up'),
    tooltip: 'Sign up',
    icon: const Icon(Icons.person_add_alt_1),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Room for the keyboard under the voucher field.
      isScrollControlled: true,
      builder: (_) => SignUpSheet(
        auth: auth,
        roles: roles,
        membership: membership,
        profiles: profiles,
        openLink: openLink,
      ),
    ),
  );
}

/// What a signed-in user without access sees: subscribe at nu01.com (where
/// plans, Free and Premium, are taken), redeem a voucher code, link an
/// account that has access, or check again.
class SignUpSheet extends StatefulWidget {
  const SignUpSheet({
    super.key,
    required this.auth,
    required this.roles,
    required this.membership,
    this.profiles,
    LinkOpener? openLink,
  }) : openLink = openLink ?? launchLink;

  final AuthService auth;
  final RolesService roles;
  final MembershipClient membership;

  /// When given, a member's other account can link to it instead.
  final ProfileClient? profiles;

  /// Opens the subscription page.
  final LinkOpener openLink;

  @override
  State<SignUpSheet> createState() => _SignUpSheetState();
}

class _SignUpSheetState extends State<SignUpSheet> {
  final _code = TextEditingController();
  bool _redeeming = false;
  String? _codeError;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// Redeems the voucher code, then re-asks the roles: a valid code lets the
  /// user in at once.
  Future<void> _redeem() async {
    final token = widget.auth.idToken;
    final code = _code.text.trim();
    if (token == null || code.isEmpty) return;
    setState(() {
      _redeeming = true;
      _codeError = null;
    });
    try {
      await widget.membership.redeem(token, code);
      if (mounted) _code.clear();
      await widget.roles.refresh();
    } on RolesException catch (e) {
      if (mounted) {
        setState(
          () => _codeError = switch (e.statusCode) {
            402 when e is PaymentRequiredException =>
              'That code gives ${e.discount}% off. Paying the rest isn\'t '
                  'available yet, so it can\'t let you in.',
            404 => 'That code is invalid, expired or used up.',
            // The route's throttle, or this email's wrong codes (an hour).
            429 => 'Too many tries. Wait a while and try again.',
            _ => 'Couldn\'t redeem the code ($e).',
          },
        );
      }
    } catch (e) {
      if (mounted) setState(() => _codeError = 'Couldn\'t redeem the code.');
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final email = widget.auth.user?.email ?? 'Your account';
    return ListenableBuilder(
      listenable: widget.roles,
      builder: (context, _) => SafeArea(
        child: Padding(
          key: const Key('sign-up-sheet'),
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Icon(Icons.person_add_alt_1, size: 40, color: scheme.primary),
              Text('Subscribe', style: theme.textTheme.titleLarge),
              Text(
                '$email doesn\'t have access to Presence yet. Subscribe at '
                'nu01.com: Free, or Premium for cloud backup and more '
                'devices. Then check again here.',
                key: const Key('subscribe-text'),
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              FilledButton.icon(
                key: const Key('subscribe'),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Subscribe at nu01.com'),
                onPressed: () => openOrCopyLink(
                  context,
                  DeviceSlots.signUp,
                  widget.openLink,
                ),
              ),
              const Divider(),
              Text(
                'Have a voucher code? Redeem it to get in right away.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('voucher-code'),
                      controller: _code,
                      enabled: !_redeeming,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: maxVoucherCode,
                      decoration: const InputDecoration(
                        labelText: 'Voucher code',
                        hintText: 'XXXX-XXXX-XXXX',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onSubmitted: (_) => _redeem(),
                    ),
                  ),
                  _redeeming
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          key: const Key('redeem-voucher'),
                          onPressed: _code.text.trim().isEmpty ? null : _redeem,
                          child: const Text('Redeem'),
                        ),
                ],
              ),
              if (_codeError case final error?)
                Text(
                  error,
                  key: const Key('voucher-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              if (widget.profiles case final profiles?)
                LinkedAccountsButton(
                  auth: widget.auth,
                  roles: widget.roles,
                  profiles: profiles,
                  label: 'Have access with another Google account? Link it',
                ),
              widget.roles.state == AccessState.checking
                  ? const CircularProgressIndicator()
                  : TextButton.icon(
                      key: const Key('check-access'),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Check again'),
                      onPressed: widget.roles.refresh,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
