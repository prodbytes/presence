import 'package:flutter/material.dart';

import '../time_format.dart';
import 'feedback_client.dart';
import 'help_view.dart';

/// One member's conversation on the Admin tab: who, when they last wrote
/// and whether it awaits a reply; opened, the whole conversation and a
/// Reply field.
class FeedbackThreadCard extends StatelessWidget {
  const FeedbackThreadCard({
    super.key,
    required this.thread,
    required this.onReply,
  });

  final FeedbackThread thread;

  /// Sends a reply; true if it was.
  final Future<bool> Function(String text) onReply;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final last = thread.messages.last.sentAt.toLocal();
    final when = '${formatDate(last)} ${formatHourMinute(last)}';
    return Card(
      key: Key('feedback-${thread.email}'),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: thread.awaitingReply
            ? Tooltip(
                message: 'Awaiting a reply',
                child: Icon(Icons.mark_chat_unread, color: scheme.primary),
              )
            : Tooltip(
                message: 'Answered',
                child: Icon(
                  Icons.chat_bubble_outline,
                  color: scheme.onSurfaceVariant,
                ),
              ),
        title: Text(thread.name.isEmpty ? thread.email : thread.name),
        subtitle: Text(
          thread.name.isEmpty ? when : '${thread.email} · $when',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          FeedbackConversation(messages: thread.messages, adminView: true),
          const SizedBox(height: 16),
          FeedbackComposer(
            key: Key('feedback-reply-${thread.email}'),
            label: 'Reply',
            action: 'Reply',
            onSend: onReply,
          ),
        ],
      ),
    );
  }
}
