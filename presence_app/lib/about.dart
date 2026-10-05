import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_version.dart';
import 'auth/account_sheet.dart';
import 'auth/auth_service.dart';
import 'auth/membership_client.dart';
import 'auth/profile_client.dart';
import 'auth/roles_service.dart';

/// Opens [url] outside the app; false when it couldn't.
typedef LinkOpener = Future<bool> Function(Uri url);

Future<bool> _launch(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// The About icon in the app bar, shown to everyone, signed in or not: it
/// opens the [AboutScreen].
class AboutButton extends StatelessWidget {
  const AboutButton({
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
  final LinkOpener? openLink;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('about'),
    tooltip: 'About',
    icon: const Icon(Icons.info_outline),
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AboutScreen(
          auth: auth,
          roles: roles,
          membership: membership,
          profiles: profiles,
          openLink: openLink,
        ),
      ),
    ),
  );
}

/// What Presence is, who makes it, its links, and a call to support it by
/// becoming a member.
class AboutScreen extends StatelessWidget {
  const AboutScreen({
    super.key,
    required this.auth,
    required this.roles,
    required this.membership,
    this.profiles,
    LinkOpener? openLink,
  }) : openLink = openLink ?? _launch;

  final AuthService auth;
  final RolesService roles;
  final MembershipClient membership;
  final ProfileClient? profiles;

  /// Opens a link; a link that can't open is copied instead.
  final LinkOpener openLink;

  static final web = Uri.parse('https://presence.nu01.com');
  static final source = Uri.parse('https://github.com/prodbytes/presence');
  static final prodbytes = Uri.parse('https://github.com/prodbytes');
  static final license = Uri.parse(
    'https://github.com/prodbytes/presence/blob/main/LICENSE',
  );
  static const install = 'curl -fsSL https://sh.presence.nu01.com | sh';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    const version = AppVersion.version;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              key: const Key('about-page'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Presence',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (version.isNotEmpty)
                    Text(
                      'Version $version',
                      key: const Key('about-version'),
                      style: muted,
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Presence helps you keep track of what happens in a private '
                    'place you\'re responsible for, such as your home, a shop '
                    'or an office. It turns a phone, tablet or laptop into an '
                    'always-on camera: it shows the live feeds and records '
                    'clips, including the moments before you pressed Clip. It '
                    'also records when the picture moves, and lets you tag the '
                    'people and pets in a clip. Members\' clips and events sync '
                    'to the cloud, so they can be viewed from their other '
                    'devices.',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Make sure you\'re allowed to record: Presence records video '
                    'and audio, and laws on recording people vary. Only record '
                    'places you have the right to monitor.',
                    style: muted,
                  ),
                  const SizedBox(height: 16),
                  Text.rich(
                    key: const Key('about-made-by'),
                    TextSpan(
                      style: theme.textTheme.titleMedium,
                      children: [
                        const TextSpan(text: 'Made with '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Icon(
                            Icons.favorite,
                            size: 20,
                            color: scheme.error,
                            semanticLabel: 'love',
                          ),
                        ),
                        const TextSpan(text: ' by prodbytes'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  ListenableBuilder(
                    listenable: Listenable.merge([auth, roles]),
                    builder: (context, _) => _support(context),
                  ),
                  const SizedBox(height: 16),
                  Text('Links', style: theme.textTheme.titleMedium),
                  _link(context, Icons.public, 'Presence on the web', web),
                  _link(context, Icons.code, 'Source code', source),
                  _link(context, Icons.groups, 'prodbytes', prodbytes),
                  _link(
                    context,
                    Icons.gavel,
                    'License (Apache 2.0), no warranty',
                    license,
                  ),
                  ListTile(
                    key: const Key('about-install'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.terminal),
                    title: const Text('Run it on this machine'),
                    subtitle: const SelectableText(
                      install,
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                    trailing: IconButton(
                      tooltip: 'Copy command',
                      icon: const Icon(Icons.copy),
                      onPressed: () =>
                          _copy(context, install, 'Command copied'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The call to support Presence: become a member, or thanks for being
  /// one. None in DEV, which has no accounts.
  Widget _support(BuildContext context) {
    if (roles.mode == ExecutionMode.dev) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final member = auth.user != null && roles.hasAccess;
    final signedIn = auth.user != null;
    return Card(
      key: const Key('about-support'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              member ? 'Thank you for being a member' : 'Support Presence',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            Text(
              member
                  ? 'Your membership keeps Presence going: the cloud sync, '
                        'the new features and the fixes.'
                  : 'Become a member: you get every feature, cloud sync of '
                        'your clips and events across your devices, and you '
                        'keep Presence going.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            if (!member && signedIn)
              FilledButton.icon(
                key: const Key('about-become-member'),
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Become a member'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => SignUpSheet(
                    auth: auth,
                    roles: roles,
                    membership: membership,
                    profiles: profiles,
                  ),
                ),
              ),
            if (!signedIn) ...[
              Text(
                'Sign in first, then ask to become a member.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: SignInAction(auth: auth),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _link(BuildContext context, IconData icon, String title, Uri url) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text('${url.host}${url.path}'),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () async {
          if (await openLink(url)) return;
          if (context.mounted) _copy(context, '$url', 'Link copied');
        },
      );

  static void _copy(BuildContext context, String text, String done) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
  }
}
