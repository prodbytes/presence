import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../auth/roles_service.dart';
import '../time_format.dart';
import '../l10n/l10n.dart';
import 'feedback_client.dart';

/// What a failed send says, in [l] (English by default).
String feedbackSendError(Object e, [AppLocalizations? l]) {
  l ??= lookupAppLocalizations(const Locale('en'));
  return switch (e) {
    RolesException(statusCode: 409) => l.feedbackSentTooMuch,
    RolesException(statusCode: 429) => l.feedbackTooManyTries,
    _ => l.feedbackSendFailed('$e'),
  };
}

/// The Help tab's page (Feedback and Help), for members: their
/// conversation with the administrators, oldest first, and a field to write
/// more. A page of the home screen's tabs, like Settings: no scaffold of its
/// own; Reload sits by the heading, and pulling down reloads too.
class HelpView extends StatefulWidget {
  const HelpView({super.key, required this.auth, required this.feedback});

  final AuthService auth;
  final FeedbackClient feedback;

  @override
  State<HelpView> createState() => _HelpViewState();
}

class _HelpViewState extends State<HelpView> {
  List<FeedbackMessage>? _messages;

  /// Why the messages didn't load, worded in the language shown.
  String Function(AppLocalizations l)? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.auth.idToken;
    if (token == null) {
      setState(() => _error = (l) => l.helpNotSignedIn);
      return;
    }
    setState(() => _error = null);
    try {
      final messages = await widget.feedback.mine(token);
      if (mounted) setState(() => _messages = messages);
    } catch (e) {
      if (mounted) {
        setState(() => _error = (l) => l.helpLoadFailed('$e'));
      }
    }
  }

  /// Sends [text]; true if it was.
  Future<bool> _send(String text) async {
    final token = widget.auth.idToken;
    if (token == null) return false;
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    try {
      final sent = await widget.feedback.send(token, text);
      if (mounted) setState(() => _messages = [...?_messages, sent]);
      return true;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(feedbackSendError(e, l))));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    final messages = _messages;
    return Center(
      key: const Key('help-view'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(l.helpTitle, style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    key: const Key('help-reload'),
                    tooltip: l.helpReload,
                    icon: const Icon(Icons.refresh),
                    onPressed: _load,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                l.helpIntro,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              ...switch ((messages, _error)) {
                (_, final error?) => [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      error(l),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                ],
                (null, _) => [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
                (final list?, _) when list.isEmpty => [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      l.helpNoMessages,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
                (final list?, _) => [
                  FeedbackConversation(messages: list, adminView: false),
                ],
              },
              const SizedBox(height: 16),
              FeedbackComposer(
                key: const Key('help-composer'),
                label: l.helpMessage,
                action: l.helpSend,
                onSend: _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A conversation as chat bubbles, oldest first: the reader's own messages
/// on the right, the other side's on the left. [adminView]: read by an
/// admin, whose side is the replies (each says which admin wrote it);
/// otherwise by the member, to whom replies come from "Presence team".
class FeedbackConversation extends StatelessWidget {
  const FeedbackConversation({
    super.key,
    required this.messages,
    required this.adminView,
  });

  final List<FeedbackMessage> messages;
  final bool adminView;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final m in messages)
          Builder(
            builder: (context) {
              final own = m.fromAdmin == adminView;
              final who = switch ((m.fromAdmin, adminView)) {
                (false, false) => l.feedbackYou,
                (false, true) => l.feedbackMember,
                (true, false) => l.feedbackTeam,
                (true, true) => m.by.isEmpty ? l.feedbackAdmin : m.by,
              };
              final at = m.sentAt.toLocal();
              return Align(
                alignment: own ? Alignment.centerRight : Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: 0.85,
                  alignment: own ? Alignment.centerRight : Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: own
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: own
                              ? scheme.primaryContainer
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: SelectableText(
                            m.message,
                            style: TextStyle(
                              color: own
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        '$who · ${formatDate(at)} ${formatHourMinute(at)}',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// A message field and its send button, disabled while the field is blank
/// or a send is in flight; a sent message clears the field.
class FeedbackComposer extends StatefulWidget {
  const FeedbackComposer({
    super.key,
    required this.label,
    required this.action,
    required this.onSend,
  });

  final String label;
  final String action;

  /// Sends the trimmed text; true if it was (the field is then cleared).
  final Future<bool> Function(String text) onSend;

  @override
  State<FeedbackComposer> createState() => _FeedbackComposerState();
}

class _FeedbackComposerState extends State<FeedbackComposer> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final sent = await widget.onSend(_text.text.trim());
    if (!mounted) return;
    setState(() => _sending = false);
    if (sent) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final canSend = !_sending && _text.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      spacing: 8,
      children: [
        TextField(
          key: const Key('feedback-field'),
          controller: _text,
          minLines: 2,
          maxLines: 6,
          maxLength: FeedbackClient.maxMessage,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
          ),
        ),
        FilledButton.icon(
          key: const Key('feedback-send'),
          onPressed: canSend ? _send : null,
          icon: _sending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send),
          label: Text(widget.action),
        ),
      ],
    );
  }
}
