import 'dart:async';

import 'package:flutter/material.dart';

import 'blink_settings.dart' show BlinkSettings, GetDeviceFile, PutDeviceFile;
import 'cloud/cloud_sync.dart';
import 'events.dart';
import 'l10n/l10n.dart';

/// A make of camera on a streamer's network (specs/gopro.md,
/// specs/reolink.md): its files' name, its strings, and what adding one
/// asks for.
class NetCameraKind {
  const NetCameraKind._({
    required this.id,
    required this.about,
    required this.noStreamer,
    required this.addressHelp,
    required this.password,
    required this.none,
    required this.cameras,
    required this.error,
    this.username = false,
    this.channel = false,
    this.passwordRequired = false,
  });

  /// GoPro's: an address, and a password on the home network only.
  static final gopro = NetCameraKind._(
    id: 'gopro',
    about: (l) => l.goproAbout,
    noStreamer: (l) => l.goproNoStreamer,
    addressHelp: (l) => l.goproAddressHelp,
    password: (l) => l.goproPassword,
    none: (l) => l.goproNone,
    cameras: (l) => l.goproCameras,
    error: (l, e) => l.goproError(e),
  );

  /// Reolink's: an address, a user and its password, and an NVR's channel.
  static final reolink = NetCameraKind._(
    id: 'reolink',
    about: (l) => l.reolinkAbout,
    noStreamer: (l) => l.reolinkNoStreamer,
    addressHelp: (l) => l.reolinkAddressHelp,
    password: (l) => l.reolinkPassword,
    none: (l) => l.reolinkNone,
    cameras: (l) => l.reolinkCameras,
    error: (l, e) => l.reolinkError(e),
    username: true,
    channel: true,
    passwordRequired: true,
  );

  /// Names the request (`<id>.json`), the status (`<id>-status.json`) and
  /// the widgets' keys.
  final String id;
  final String Function(AppLocalizations l) about,
      noStreamer,
      addressHelp,
      password,
      none,
      cameras;
  final String Function(AppLocalizations l, String error) error;

  /// Adding one asks for a user (default `admin`), an NVR's channel; a
  /// password always.
  final bool username, channel, passwordRequired;
}

/// Settings' **GoPro cameras** and **Reolink cameras** sections
/// (specs/gopro.md, specs/reolink.md): a Linux streamer of the profile (a
/// Raspberry Pi, picked here) reaches the [kind]'s cameras on its network
/// and fetches their videos, each camera a device of its own. The app adds
/// and removes cameras through the profile's folder, sealed with the
/// streamer's key ([CloudSync.putDeviceFile]: `<kind>.json`, with the
/// camera's address and login), and reads its answer
/// (`<kind>-status.json`) every [poll] while this shows.
class NetCameraSettings extends StatefulWidget {
  const NetCameraSettings({
    super.key,
    required this.kind,
    required this.streamers,
    required this.putFile,
    required this.getFile,
    this.poll = const Duration(seconds: 10),
    this.now,
  });

  /// From [CloudSync] and the event log (the profile's Linux devices).
  factory NetCameraSettings.of({
    Key? key,
    required NetCameraKind kind,
    required CloudSync sync,
    required EventLog log,
    required String profileId,
    String? thisDevice,
  }) => NetCameraSettings(
    key: key,
    kind: kind,
    streamers: () =>
        BlinkSettings.streamersOf(log, sync, profileId, thisDevice),
    putFile: sync.putDeviceFile,
    getFile: sync.getDeviceFile,
  );

  final NetCameraKind kind;

  /// The profile's streamers that can fetch the cameras' videos.
  final List<String> Function() streamers;
  final PutDeviceFile putFile;
  final GetDeviceFile getFile;
  final Duration poll;
  final DateTime Function()? now;

  @override
  State<NetCameraSettings> createState() => _NetCameraSettingsState();
}

class _NetCameraSettingsState extends State<NetCameraSettings> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _username = TextEditingController(text: 'admin');
  final _password = TextEditingController();
  final _channel = TextEditingController(text: '0');
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
    _username.dispose();
    _password.dispose();
    _channel.dispose();
    super.dispose();
  }

  NetCameraKind get _kind => widget.kind;
  String get _statusFile => '${_kind.id}-status.json';
  Key _key(String name) => Key('${_kind.id}-$name');

  List<String> get _streamers => widget.streamers();

  Future<void> _refresh() async {
    final streamers = _streamers;
    if (streamers.isEmpty) return;
    // The one with this kind's cameras already, else the first.
    if (_streamer == null || !streamers.contains(_streamer)) {
      String? withCameras;
      for (final s in streamers) {
        if (await widget.getFile(s, _statusFile) != null) {
          withCameras = s;
          break;
        }
      }
      if (!mounted) return;
      setState(() => _streamer = withCameras ?? streamers.first);
    }
    final status = await widget.getFile(_streamer!, _statusFile);
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
    final ok = await widget.putFile(_streamer!, '${_kind.id}.json', request);
    if (!mounted) return ok;
    setState(() {
      _sending = false;
      if (ok) {
        _sent = request['requestedAt'] as int;
      } else {
        _problem = context.l10n.netcamNotSent;
      }
    });
    if (ok) _refresh();
    return ok;
  }

  Future<void> _add() async {
    final address = _address.text.trim();
    if (address.isEmpty) return;
    if (_kind.passwordRequired && _password.text.isEmpty) return;
    final channel = int.tryParse(_channel.text.trim()) ?? 0;
    final sent = await _send({
      'add': {
        'name': _name.text.trim(),
        'address': address,
        if (_kind.username && _username.text.trim().isNotEmpty)
          'username': _username.text.trim(),
        if (_password.text.isNotEmpty) 'password': _password.text,
        if (_kind.channel && channel > 0) 'channel': channel,
      },
      'requestedAt': _now().millisecondsSinceEpoch,
    });
    if (sent) {
      _name.clear();
      _address.clear();
      _password.clear();
      _channel.text = '0';
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
      return Text(_kind.noStreamer(l), key: _key('no-streamer'));
    }
    final state = _state;
    final status = _status;
    final cameras = [
      for (final c in (status?['cameras'] as List?) ?? const [])
        if (c is Map) c.cast<String, Object?>(),
    ];
    final busy = _sending || state == 'waiting' || state == 'checking';
    return Column(
      key: _key('settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(_kind.about(l), style: quiet),
        DropdownButtonFormField<String>(
          key: _key('streamer'),
          initialValue: _streamer ?? streamers.first,
          decoration: InputDecoration(labelText: l.netcamStreamer),
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
            'waiting' => l.netcamWaiting(_streamer ?? ''),
            'checking' => l.netcamChecking,
            'error' => _kind.error(l, status?['error'] as String? ?? ''),
            _ when cameras.isNotEmpty => _kind.cameras(l),
            _ => _kind.none(l),
          },
          key: _key('state'),
          style: state == 'error'
              ? TextStyle(color: theme.colorScheme.error)
              : null,
        ),
        for (final c in cameras) _camera(c, quiet, theme, busy),
        TextField(
          key: _key('name'),
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: l.netcamName),
        ),
        TextField(
          key: _key('address'),
          controller: _address,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: l.netcamAddress,
            helperText: _kind.addressHelp(l),
            helperMaxLines: 3,
          ),
        ),
        if (_kind.username)
          TextField(
            key: _key('username'),
            controller: _username,
            autocorrect: false,
            decoration: InputDecoration(labelText: l.netcamUsername),
          ),
        TextField(
          key: _key('password'),
          controller: _password,
          obscureText: true,
          decoration: InputDecoration(labelText: _kind.password(l)),
          onSubmitted: (_) => _add(),
        ),
        if (_kind.channel)
          TextField(
            key: _key('channel'),
            controller: _channel,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.netcamChannel,
              helperText: l.netcamChannelHelp,
            ),
          ),
        Text(l.netcamPasswordNote, style: quiet),
        FilledButton(
          key: _key('add'),
          onPressed: busy ? null : _add,
          child: Text(l.netcamAdd),
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
      key: _key('camera-$device'),
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
              Text(
                [
                  c['address'] as String? ?? '',
                  if ((c['channel'] as num?) case final ch? when ch > 0)
                    l.netcamChannelOf(ch.toInt()),
                ].join(' · '),
                style: quiet,
              ),
              if (error != null && error.isNotEmpty)
                Text(
                  l.netcamCameraError(error),
                  style: TextStyle(color: theme.colorScheme.error),
                )
              else if (lastFetch != null)
                Text(
                  l.netcamLastFetch(
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
          key: _key('remove-$device'),
          tooltip: l.netcamRemove,
          icon: const Icon(Icons.delete_outline),
          onPressed: busy ? null : () => _remove(device),
        ),
      ],
    );
  }
}
