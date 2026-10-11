import 'package:flutter/material.dart';

import '../about.dart';
import '../feedback/feedback_client.dart';
import '../feedback/feedback_inbox.dart';
import 'auth_service.dart';
import 'payment_links_editor.dart';
import 'payments_client.dart';
import 'rbacr_client.dart';
import '../l10n/l10n.dart';

/// The Admin tab's page, for admins only (`presence_user` +
/// `presence_admin`): the members' Feedback and Help conversations, each
/// with a Reply field; then Payments, the Premium plans' Stripe links
/// ([PaymentLinksEditor]). Voucher codes and maintenance mode are managed in
/// rbacr (a link at the end), which keeps every role. Nobody asks for
/// access here: people subscribe at nu01.com. A page of the home screen's
/// tabs, like Settings: no scaffold or app bar of its own; Reload sits by
/// the heading, and pulling down reloads too.
class AdminView extends StatefulWidget {
  const AdminView({
    super.key,
    required this.auth,
    required this.feedback,
    this.payments,
    this.rbacr,
    LinkOpener? openLink,
  }) : openLink = openLink ?? launchLink;

  final AuthService auth;
  final FeedbackClient feedback;

  /// The Premium plans' Stripe links: the Payments section; none without.
  final PaymentsService? payments;

  /// rbacr, where vouchers and maintenance mode are managed;
  /// `RbacrConfig.baseUrl` by default.
  final Uri? rbacr;

  /// Opens rbacr; a link that can't open is copied instead.
  final LinkOpener openLink;

  @override
  State<AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<AdminView> {
  List<FeedbackThread>? _threads;

  /// Why the threads didn't load, in the language shown (set in
  /// [initState] too, before the localizations can be read).
  String Function(AppLocalizations l10n)? _threadsError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.auth.idToken;
    if (token == null) {
      setState(() => _threadsError = (l10n) => l10n.authNotSignedIn);
      return;
    }
    setState(() => _threadsError = null);
    try {
      final threads = await widget.feedback.threads(token);
      if (mounted) setState(() => _threads = threads);
    } catch (e) {
      if (mounted) {
        setState(
          () => _threadsError = (l10n) => l10n.authFeedbackLoadFailed('$e'),
        );
      }
    }
  }

  /// Answers [thread] with [text]; true if it was sent.
  Future<bool> _reply(FeedbackThread thread, String text) async {
    final token = widget.auth.idToken;
    if (token == null) return false;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      final reply = await widget.feedback.reply(
        token,
        thread.conversation,
        text,
      );
      if (!mounted) return true;
      setState(() {
        final threads = _threads;
        if (threads == null) return;
        // Answered last: first in the list.
        _threads = [
          FeedbackThread(
            conversation: thread.conversation,
            email: thread.email,
            name: thread.name,
            messages: [...thread.messages, reply],
          ),
          ...threads.where((t) => t.conversation != thread.conversation),
        ];
      });
      return true;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.authReplyFailed(thread.email, '$e'))),
      );
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget status(String text, {bool error = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: error ? scheme.error : scheme.onSurfaceVariant),
      ),
    );
    const loading = Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: CircularProgressIndicator()),
    );
    final threads = _threads;
    final rbacr = widget.rbacr ?? RbacrConfig.baseUrl;
    return Center(
      key: const Key('admin-view'),
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
                    child: Text(
                      context.l10n.authFeedback,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const Key('admin-reload'),
                    tooltip: context.l10n.authReload,
                    icon: const Icon(Icons.refresh),
                    onPressed: _load,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                context.l10n.authFeedbackIntro,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              ...switch ((threads, _threadsError)) {
                (_, final error?) => [status(error(context.l10n), error: true)],
                (null, _) => [loading],
                (final list?, _) when list.isEmpty => [
                  status(context.l10n.authNoFeedback),
                ],
                (final list?, _) => [
                  for (final thread in list)
                    Padding(
                      // Moves with its thread (a reply puts it first),
                      // staying open.
                      key: ValueKey('thread-${thread.conversation}'),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FeedbackThreadCard(
                        thread: thread,
                        onReply: (text) => _reply(thread, text),
                      ),
                    ),
                ],
              },
              if (widget.payments case final payments?) ...[
                const SizedBox(height: 24),
                PaymentLinksEditor(payments: payments),
              ],
              const SizedBox(height: 24),
              Text(
                context.l10n.authVouchersTitle,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                context.l10n.authRbacrText,
                key: const Key('admin-rbacr-text'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const Key('admin-rbacr'),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(context.l10n.authOpenHost(rbacr.host)),
                  onPressed: () =>
                      openOrCopyLink(context, rbacr, widget.openLink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
