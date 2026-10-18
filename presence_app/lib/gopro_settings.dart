import 'dart:async';

import 'package:flutter/material.dart';

import 'blink_settings.dart' show BlinkSettings, GetDeviceFile, PutDeviceFile;
import 'cloud/cloud_sync.dart';
import 'events.dart';
import 'l10n/l10n.dart';

/// Settings' **GoPro cameras** section (specs/gopro.md): a Linux streamer
/// of the profile (a Raspberry Pi, picked here) reaches GoPro cameras on
/// its network (the Open GoPro HTTP API) and fetches their new videos, each
/// camera a device of its own. The app adds and removes cameras through the
/// profile's folder, sealed with the streamer's key
/// ([CloudSync.putDeviceFile]: `gopro.json`, with the camera's address and
/// password), and reads its answer (`gopro-status.json`) every [poll]
/// while this shows.
class GoProSettings extends StatefulWidget {
  const GoProSettings({
    super.key,
    required this.streamers,
    required this.putFile,
    required this.getFile,
    this.poll = const Duration(seconds: 10),
    this.now,
  });

  /// From [CloudSync] and the event log (the profile's Linux devices).
  factory GoProSettings.of({
    Key? key,
    required CloudSync sync,
    required EventLog log,
    required String profileId,
    String? thisDevice,
  }) => GoProSettings(
    key: key,
    streamers: () =>
        BlinkSettings.streamersOf(log, sync, profileId, thisDevice),
    putFile: sync.putDeviceFile,
    getFile: sync.getDeviceFile,
  );

  /// The profile's streamers that can fetch GoPro videos.
  final List<String> Function() streamers;
  final PutDeviceFile putFile;
  final GetDeviceFile getFile;
  final Duration poll;
  final DateTime Function()? now;

  @override
  State<GoProSettings> createState() => _GoProSettingsState();
}

class _GoProSettingsState extends State<GoProSettings> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _password = TextEditingController();
  String? _streamer;
  Map<String, Object?>? _status;
  Timer? _timer;
  bool _sending = false;
  String? _problem;

  /// The request this app last sent (its time), till the status answers it.
  int? _sent;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.poll, (_) => _refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _name.dispose();
    _address.dispose();
    _password.dispose();
    super.dispose();
  }

  List<String> get _streamers => widget.streamers();

  Future<void> _refresh() async {
    final streamers = _streamers;
    if (streamers.isEmpty) return;
    // The one with GoPro cameras already, else the first.
    if (_streamer == null || !streamers.contains(_streamer)) {
      String? withGoPro;
      for (final s in streamers) {
        if (await widget.getFile(s, 'gopro-status.json') != null) {
          withGoPro = s;
          break;
        }
      }
      if (!mounted) return;
      setState(() => _streamer = withGoPro ?? streamers.first);
    }
    final status = await widget.getFile(_streamer!, 'gopro-status.json');
    if (!mounted) return;
    setState(() => _status = status);
  }

  String get _state {
    final status = _status;
    final answered = (status?['requestedAt'] as num?)?.toInt() ?? 0;
    // Sent and not answered yet: the streamer looks every 30 s.
    if (_sent != null && answered < _sent!) return 'waiting';
    return status?['state'] as String? ?? 'off';
  }

  Future<bool> _send(Map<String, Object?> request) async {
    setState(() {
      _sending = true;
      _problem = null;
    });
    final ok = await widget.putFile(_streamer!, 'gopro.json', request);
    if (!mounted) return ok;
    setState(() {
      _sending = false;
      if (ok) {
        _sent = request['requestedAt'] as int;
      } else {
        _problem = context.l10n.goproNotSent;
      }
    });
    if (ok) _refresh();
    return ok;
  }

  Future<void> _add() async {
    final address = _address.text.trim();
    if (address.isEmpty) return;
    final sent = await _send({
      'add': {
        'name': _name.text.trim(),
        'address': address,
        if (_password.text.isNotEmpty) 'password': _password.text,
      },
      'requestedAt': _now().millisecondsSinceEpoch,
    });
    if (sent) {
      _name.clear();
      _address.clear();
      _password.clear();
    }
  }

  void _remove(String device) =>
      _send({'remove': device, 'requestedAt': _now().millisecondsSinceEpoch});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final quiet = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final streamers = _streamers;
    if (streamers.isEmpty) {
      return Text(l.goproNoStreamer, key: const Key('gopro-no-streamer'));
    }
    final state = _state;
    final status = _status;
    final cameras = [
      for (final c in (status?['cameras'] as List?) ?? const [])
        if (c is Map) c.cast<String, Object?>(),
    ];
    final busy = _sending || state == 'waiting' || state == 'checking';
    return Column(
      key: const Key('gopro-settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(l.goproAbout, style: quiet),
        DropdownButtonFormField<String>(
          key: const Key('gopro-streamer'),
          initialValue: _streamer ?? streamers.first,
          decoration: InputDecoration(labelText: l.goproStreamer),
          items: [
            for (final s in streamers)
              DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (s) {
            setState(() {
              _streamer = s;
              _status = null;
              _sent = null;
            });
            _refresh();
          },
        ),
        Text(
          switch (state) {
            'waiting' => l.goproWaiting(_streamer ?? ''),
            'checking' => l.goproChecking,
            'error' => l.goproError(status?['error'] as String? ?? ''),
            _ when cameras.isNotEmpty => l.goproCameras,
            _ => l.goproNone,
          },
          key: const Key('gopro-state'),
          style: state == 'error'
              ? TextStyle(color: theme.colorScheme.error)
              : null,
        ),
        for (final c in cameras) _camera(c, quiet, theme, busy),
        TextField(
          key: const Key('gopro-name'),
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: l.goproName),
        ),
        TextField(
          key: const Key('gopro-address'),
          controller: _address,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: l.goproAddress,
            helperText: l.goproAddressHelp,
            helperMaxLines: 3,
          ),
        ),
        TextField(
          key: const Key('gopro-password'),
          controller: _password,
          obscureText: true,
          decoration: InputDecoration(labelText: l.goproPassword),
          onSubmitted: (_) => _add(),
        ),
        Text(l.goproPasswordNote, style: quiet),
        FilledButton(
          key: const Key('gopro-add'),
          onPressed: busy ? null : _add,
          child: Text(l.goproAdd),
        ),
        if (_problem case final problem?)
          Text(problem, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }

  Widget _camera(
    Map<String, Object?> c,
    TextStyle quiet,
    ThemeData theme,
    bool busy,
  ) {
    final l = context.l10n;
    final device = c['deviceId'] as String? ?? '';
    final error = c['error'] as String?;
    final lastFetch = (c['lastFetch'] as num?)?.toInt();
    return Row(
      key: Key('gopro-camera-$device'),
      spacing: 8,
      children: [
        const Icon(Icons.videocam_outlined, size: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: c['name'] as String? ?? ''),
                    TextSpan(text: ' · $device', style: quiet),
                  ],
                ),
              ),
              Text(c['address'] as String? ?? '', style: quiet),
              if (error != null && error.isNotEmpty)
                Text(
                  l.goproCameraError(error),
                  style: TextStyle(color: theme.colorScheme.error),
                )
              else if (lastFetch != null)
                Text(
                  l.goproLastFetch(
                    formatEventTime(
                      DateTime.fromMillisecondsSinceEpoch(lastFetch),
                    ),
                  ),
                  style: quiet,
                ),
            ],
          ),
        ),
        IconButton(
          key: Key('gopro-remove-$device'),
          tooltip: l.goproRemove,
          icon: const Icon(Icons.delete_outline),
          onPressed: busy ? null : () => _remove(device),
        ),
      ],
    );
  }
}
