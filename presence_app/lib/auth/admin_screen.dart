import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'membership_client.dart';

/// Admins only (`presence_user` + `presence_admin`): the pending membership
/// requests, each with **Grant access** (gives it the `presence_user` role)
/// and **Dismiss**.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.auth, required this.membership});

  final AuthService auth;
  final MembershipClient membership;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  List<MembershipRequest>? _requests;
  String? _error;

  /// Emails with a grant or dismissal in flight.
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.auth.idToken;
    if (token == null) {
      setState(() => _error = 'Not signed in.');
      return;
    }
    setState(() => _error = null);
    try {
      final requests = await widget.membership.list(token);
      if (mounted) setState(() => _requests = requests);
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t load requests ($e).');
    }
  }

  Future<void> _act(MembershipRequest request, {required bool grant}) async {
    final token = widget.auth.idToken;
    if (token == null) return;
    setState(() => _busy.add(request.email));
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (grant) {
        await widget.membership.grant(token, request.email);
      } else {
        await widget.membership.dismiss(token, request.email);
      }
      if (!mounted) return;
      setState(() => _requests?.remove(request));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            grant
                ? '${request.email} can now use Presence'
                : 'Dismissed ${request.email}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn\'t update ${request.email} ($e)')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(request.email));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final requests = _requests;
    return Scaffold(
      key: const Key('admin-screen'),
      appBar: AppBar(
        title: const Text('Membership requests'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: switch ((requests, _error)) {
            (_, final error?) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error),
              ),
            ),
            (null, _) => const CircularProgressIndicator(),
            (final list?, _) when list.isEmpty => Text(
              'No pending requests.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            (final list?, _) => RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _RequestCard(
                  request: list[i],
                  busy: _busy.contains(list[i].email),
                  onGrant: () => _act(list[i], grant: true),
                  onDismiss: () => _act(list[i], grant: false),
                ),
              ),
            ),
          },
        ),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.busy,
    required this.onGrant,
    required this.onDismiss,
  });

  final MembershipRequest request;
  final bool busy;
  final VoidCallback onGrant;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final when = MaterialLocalizations.of(context)
        .formatShortDate(request.requestedAt.toLocal());
    return Card(
      key: Key('request-${request.email}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              request.name.isEmpty ? request.email : request.name,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              request.name.isEmpty ? when : '${request.email} · $when',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            SelectableText(request.message),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: busy
                  ? const [
                      SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ]
                  : [
                      TextButton(
                        key: Key('dismiss-${request.email}'),
                        onPressed: onDismiss,
                        child: const Text('Dismiss'),
                      ),
                      FilledButton(
                        key: Key('grant-${request.email}'),
                        onPressed: onGrant,
                        child: const Text('Grant access'),
                      ),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}
