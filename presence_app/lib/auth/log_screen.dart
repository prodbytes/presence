import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_log.dart';

/// Admins only, opened from the Admin screen: the app's latest log
/// messages ([AppLog]), newest first, with the time of each; errors in the
/// error color. Copy puts the whole log on the clipboard; Clear empties it.
class LogScreen extends StatelessWidget {
  const LogScreen({super.key, required this.log});

  final AppLog log;

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _text(List<LogEntry> entries) =>
      [for (final e in entries) '${e.time.toIso8601String()} ${e.message}']
          .join('\n');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        final entries = log.entries.reversed.toList();
        return Scaffold(
          key: const Key('log-screen'),
          appBar: AppBar(
            title: const Text('Log'),
            actions: [
              IconButton(
                key: const Key('log-copy'),
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: entries.isEmpty
                    ? null
                    : () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await Clipboard.setData(
                          ClipboardData(text: _text(log.entries)),
                        );
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Log copied')),
                        );
                      },
              ),
              IconButton(
                key: const Key('log-clear'),
                tooltip: 'Clear',
                icon: const Icon(Icons.delete_sweep),
                onPressed: entries.isEmpty ? null : log.clear,
              ),
            ],
          ),
          body: entries.isEmpty
              ? const Center(child: Text('Nothing logged yet.'))
              : SelectionArea(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 12),
                    itemBuilder: (context, i) {
                      final entry = entries[i];
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _time(entry.time),
                            style: mono?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              entry.message,
                              style: entry.error
                                  ? mono?.copyWith(
                                      color: theme.colorScheme.error,
                                    )
                                  : mono,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
        );
      },
    );
  }
}
