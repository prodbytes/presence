import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/account_sheet.dart' show profileDeviceDetails;
import 'cloud/cloud_sync.dart';
import 'events.dart';
import 'l10n/l10n.dart';

/// Sends a streamer a sealed file (`CloudSync.putDeviceFile`); false when
/// it couldn't.
typedef PutDeviceFile = Future<bool> Function(
  String deviceId,
  String name,
  Map<String, Object?> json,
);

/// Reads a streamer's sealed file (`CloudSync.getDeviceFile`); null when
/// there's none.
typedef GetDeviceFile = Future<Map<String, Object?>?> Function(
  String deviceId,
  String name,
);

/// Settings' **Blink cameras** section (specs/blink.md): a Linux streamer
/// of the profile (a Raspberry Pi, picked here) logs in to a Blink account
/// and fetches its cameras' clips, each camera a device of its own. The
/// app asks it through the profile's folder, sealed with the streamer's
/// key ([CloudSync.putDeviceFile]: `blink.json`, with the email, the
/// password, then the PIN Blink sends), and reads its answer
/// (`blink-status.json`) every [poll] while this shows.
class BlinkSettings extends StatefulWidget {
  const BlinkSettings({
    super.key,
    required this.streamers,
    required this.putFile,
    required this.getFile,
    this.poll = const Duration(seconds: 10),
    this.now,
  });

  /// From [CloudSync] and the event log (`streamersOf`).
  factory BlinkSettings.of({
    Key? key,
    required CloudSync sync,
    required EventLog log,
    required String profileId,
    String? thisDevice,
  }) => BlinkSettings(
    key: key,
    streamers: () => streamersOf(log, sync, profileId, thisDevice),
    putFile: sync.putDeviceFile,
    getFile: sync.getDeviceFile,
  );

  /// The profile's streamers that can fetch Blink's clips.
  final List<String> Function() streamers;
  final PutDeviceFile putFile;
  final GetDeviceFile getFile;
  final Duration poll;
  final DateTime Function()? now;

  /// The streamers that can fetch Blink's clips: the profile's Linux
  /// devices (Blink cameras say "Blink", not Linux).
  static List<String> streamersOf(
    EventLog log,
    CloudSync sync,
    String profileId,
    String? thisDevice,
  ) => [
    for (final d in profileDeviceDetails(
      log.events,
      profileId: profileId,
      thisDevice: thisDevice,
      listed: sync.deviceSlots?.devices ?? const [],
    ))
      if (d.os == 'Linux') d.id,
  ];

  @override
  State<BlinkSettings> createState() => _BlinkSettingsState();
}

class _BlinkSettingsState extends State<BlinkSettings> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _pin = TextEditingController();
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
    _email.dispose();
    _password.dispose();
    _pin.dispose();
    super.dispose();
  }

  List<String> get _streamers => widget.streamers();

  Future<void> _refresh() async {
    final streamers = _streamers;
    if (streamers.isEmpty) return;
    // The one with Blink already, else the first.
    if (_streamer == null || !streamers.contains(_streamer)) {
      String? withBlink;
      for (final s in streamers) {
        if (await widget.getFile(s, 'blink-status.json') != null) {
          withBlink = s;
          break;
        }
      }
      if (!mounted) return;
      setState(() => _streamer = withBlink ?? streamers.first);
    }
    final status = await widget.getFile(_streamer!, 'blink-status.json');
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

  Future<void> _send(Map<String, Object?> request) async {
    setState(() {
      _sending = true;
      _problem = null;
    });
    final ok = await widget.putFile(_streamer!, 'blink.json', request);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) {
        _sent = request['requestedAt'] as int;
      } else {
        _problem = context.l10n.blinkNotSent;
      }
    });
    if (ok) _refresh();
  }

  void _connect() {
    final email = _email.text.trim();
    if (email.isEmpty || _password.text.isEmpty) return;
    _send({
      'email': email,
      'password': _password.text,
      'requestedAt': _now().millisecondsSinceEpoch,
    });
  }

  void _sendPin() {
    final pin = _pin.text.trim();
    if (pin.isEmpty) return;
    // The same request, with the PIN: the streamer waits for it.
    final at = (_status?['requestedAt'] as num?)?.toInt() ?? _sent;
    if (at == null) return;
    _send({'email': _status?['account'], 'pin': pin, 'requestedAt': at});
    _pin.clear();
  }

  void _disconnect() =>
      _send({'disconnect': true, 'requestedAt': _now().millisecondsSinceEpoch});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final quiet = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final streamers = _streamers;
    if (streamers.isEmpty) {
      return Text(l.blinkNoStreamer, key: const Key('blink-no-streamer'));
    }
    final state = _state;
    final status = _status;
    final account = status?['account'] as String?;
    final cameras = [
      for (final c in (status?['cameras'] as List?) ?? const [])
        if (c is Map)
          (c['name'] as String? ?? '', c['deviceId'] as String? ?? ''),
    ];
    final lastFetch = (status?['lastFetch'] as num?)?.toInt();
    return Column(
      key: const Key('blink-settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(l.blinkAbout, style: quiet),
        DropdownButtonFormField<String>(
          key: const Key('blink-streamer'),
          initialValue: _streamer ?? streamers.first,
          decoration: InputDecoration(labelText: l.blinkStreamer),
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
            'waiting' => l.blinkWaiting(_streamer ?? ''),
            'installing' => l.blinkInstalling,
            'logging-in' => l.blinkLoggingIn,
            'pin-required' => l.blinkPinRequired(account ?? ''),
            'connected' => l.blinkConnected(account ?? ''),
            'error' => l.blinkError(status?['error'] as String? ?? ''),
            _ => l.blinkOff,
          },
          key: const Key('blink-state'),
          style: state == 'error'
              ? TextStyle(color: theme.colorScheme.error)
              : null,
        ),
        if (state == 'pin-required')
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('blink-pin'),
                  controller: _pin,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l.blinkPin),
                  onSubmitted: (_) => _sendPin(),
                ),
              ),
              FilledButton(
                key: const Key('blink-send-pin'),
                onPressed: _sending ? null : _sendPin,
                child: Text(l.blinkSendPin),
              ),
            ],
          ),
        if (state == 'connected') ...[
          for (final (name, device) in cameras)
            Row(
              key: Key('blink-camera-$device'),
              spacing: 8,
              children: [
                const Icon(Icons.videocam_outlined, size: 18),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: name),
                        TextSpan(text: ' · $device', style: quiet),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          if (cameras.isEmpty) Text(l.blinkNoCameras, style: quiet),
          if (lastFetch != null)
            Text(
              l.blinkLastFetch(
                formatEventTime(DateTime.fromMillisecondsSinceEpoch(lastFetch)),
              ),
              style: quiet,
            ),
          OutlinedButton(
            key: const Key('blink-disconnect'),
            onPressed: _sending ? null : _disconnect,
            child: Text(l.blinkDisconnect),
          ),
        ],
        if (state == 'off' || state == 'error') ...[
          TextField(
            key: const Key('blink-email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(labelText: l.blinkEmail),
          ),
          TextField(
            key: const Key('blink-password'),
            controller: _password,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(labelText: l.blinkPassword),
            onSubmitted: (_) => _connect(),
          ),
          Text(l.blinkPasswordNote, style: quiet),
          FilledButton(
            key: const Key('blink-connect'),
            onPressed: _sending ? null : _connect,
            child: Text(l.blinkConnect),
          ),
        ],
        if (_problem case final problem?)
          Text(problem, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}
