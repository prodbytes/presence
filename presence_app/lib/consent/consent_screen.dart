import 'package:flutter/material.dart';

/// Asked once per device, before anything shows or records (see
/// `DeviceConsent`): the user confirms they have the right to record where
/// the device records, and that faces used to recognise people are
/// biometric data under the GDPR, explained in plain terms. **Agree and
/// start** turns on once both are ticked.
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key, required this.onAgree});

  /// Called once, when the user agrees.
  final Future<void> Function() onAgree;

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _rightToRecord = false;
  bool _biometrics = false;
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
    final body = theme.textTheme.bodyMedium;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    Widget section(String title, String text) => Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(text, style: body),
        ],
      ),
    );
    Widget tick(Key key, String label, bool value, ValueChanged<bool> set) =>
        CheckboxListTile(
          key: key,
          value: value,
          onChanged: _saving ? null : (v) => setState(() => set(v ?? false)),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: body),
        );

    return Scaffold(
      key: const Key('consent'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              children: [
                Icon(Icons.verified_user, size: 40, color: scheme.primary),
                const SizedBox(height: 12),
                Text(
                  'Before Presence starts recording',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Presence records video and sound on this device all the '
                  'time, and lets you name the people in clips. Please '
                  'confirm two things first. We ask once on this device.',
                  style: body,
                ),
                section(
                  'You may record here',
                  'You own or manage the place this device films, or you '
                      'have permission to record it. The people who may be '
                      'filmed know about it, for example from a sign, where '
                      'the law asks for one. Recording people where they '
                      'expect privacy, or without the right to, can be '
                      'illegal.',
                ),
                tick(
                  const Key('consent-right-to-record'),
                  'I have the right to record where this device records.',
                  _rightToRecord,
                  (v) => _rightToRecord = v,
                ),
                section(
                  'Faces are biometric data',
                  'In plain terms: a recording of someone is personal data '
                      'about them. When their face is used to recognise or '
                      'identify them, as when you name people in a clip, '
                      'the EU\'s data protection law (the GDPR) counts it '
                      'as biometric data: a sensitive kind, with stricter '
                      'rules. Usually the people must have clearly agreed, '
                      'recordings must be kept safe and only as long as '
                      'needed, and anyone can ask to see or delete what is '
                      'about them. You are responsible for that.',
                ),
                tick(
                  const Key('consent-biometrics'),
                  'I understand that faces used to identify people are '
                  'biometric data under the GDPR, and that I am '
                  'responsible for using them lawfully.',
                  _biometrics,
                  (v) => _biometrics = v,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('consent-agree'),
                  onPressed: _rightToRecord && _biometrics && !_saving
                      ? _agree
                      : null,
                  child: const Text('Agree and start'),
                ),
                const SizedBox(height: 16),
                Text(
                  'This is not legal advice. If you are unsure, ask a data '
                  'protection professional.',
                  style: small,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
