import 'package:flutter/material.dart';

/// Asked once per device, before anything shows or records (see
/// `DeviceConsent`): two highlighted conditions, in plain terms, that the
/// user has the right to record where the device records, and that faces
/// used to recognise people are biometric data under the GDPR. One click,
/// **I agree**, accepts both.
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key, required this.onAgree});

  /// Called once, when the user agrees.
  final Future<void> Function() onAgree;

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _saving = false;

  Future<void> _agree() async {
    setState(() => _saving = true);
    await widget.onAgree();
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      key: const Key('consent'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Before Presence starts recording',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'By continuing, you confirm:',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                const _Condition(
                  key: Key('consent-right-to-record'),
                  icon: Icons.videocam,
                  title: 'I have the right to record here.',
                  detail:
                      'I own or manage this place, or have permission, and '
                      'people who may be filmed know about it.',
                ),
                const SizedBox(height: 12),
                const _Condition(
                  key: Key('consent-biometrics'),
                  icon: Icons.face,
                  title: 'Faces are biometric data, and I am responsible.',
                  detail:
                      'Under the GDPR, faces used to identify people, as '
                      'when naming them in clips, need care: clear consent, '
                      'safe keeping, and deleting on request.',
                ),
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('consent-agree'),
                  onPressed: _saving ? null : _agree,
                  child: const Text('I agree'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Asked once on this device. Not legal advice.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One condition, highlighted: an icon, the statement in bold and a short
/// plain explanation.
class _Condition extends StatelessWidget {
  const _Condition({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Icon(icon, color: scheme.primary),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
