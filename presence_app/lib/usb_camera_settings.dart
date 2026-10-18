import 'dart:async';

import 'package:flutter/material.dart';

import 'blink_settings.dart' show BlinkSettings, GetDeviceFile, PutDeviceFile;
import 'cloud/cloud_sync.dart';
import 'config.dart';
import 'events.dart';
import 'l10n/l10n.dart';
import 'streamer_picker.dart';

/// Settings' **USB cameras** section (specs/usb-cameras.md): cameras
/// plugged into a Linux streamer of the profile by USB (PTP/MTP, such as a
/// GoPro HERO5 to HERO8), with no network and no address. The streamer
/// lists those it detects in its status (`usbcam-status.json`, read every
/// [poll] while this shows); each is added with a name, known by its USB
/// serial number (`usbcam.json`, sealed with the streamer's key:
/// [CloudSync.putDeviceFile]), and becomes a device of its own. Each is
/// **unattended** unless turned off (on the add form, on by default, and
/// per camera: `{set: {deviceId, unattended}}`): only the parts of its
/// videos with movement are kept, and each video is deleted from the
/// camera once fetched. The
/// streamer is the one picked in [config] for `usbcam`, else whichever
/// leads ([StreamerPicker]).
class UsbCameraSettings extends StatefulWidget {
  const UsbCameraSettings({
    super.key,
    required this.streamers,
    required this.putFile,
    required this.getFile,
    this.leader,
    this.config,
    this.poll = const Duration(seconds: 10),
    this.now,
  });

  /// From [CloudSync] and the event log (the profile's Linux devices).
  factory UsbCameraSettings.of({
    Key? key,
    required CloudSync sync,
    required EventLog log,
    required String profileId,
    required ConfigController config,
    String? thisDevice,
  }) => UsbCameraSettings(
    key: key,
    streamers: () =>
        BlinkSettings.streamersOf(log, sync, profileId, thisDevice),
    leader: () => sync.deviceSlots?.leader,
    config: config,
    putFile: sync.putDeviceFile,
    getFile: sync.getDeviceFile,
  );

  /// The integration's ID ([IntegrationsConfig.known]), its files' name.
  static const String id = 'usbcam';

  /// The profile's streamers the cameras can be plugged into.
  final List<String> Function() streamers;
  final PutDeviceFile putFile;
  final GetDeviceFile getFile;

  /// The profile's leading streamer ([DeviceSlots.leader]), when known.
  final String? Function()? leader;

  /// Where the streamer picked is kept ([IntegrationsConfig]); this
  /// section's own, unkept, when null.
  final ConfigController? config;
  final Duration poll;
  final DateTime Function()? now;

  @override
  State<UsbCameraSettings> createState() => _UsbCameraSettingsState();
}

class _UsbCameraSettingsState extends State<UsbCameraSettings> {
  /// The name typed for each detected camera, by serial number.
  final Map<String, TextEditingController> _names = {};

  /// Unattended, as picked on the add form, by serial number (on unless
  /// turned off).
  final Map<String, bool> _unattended = {};

  /// Unattended as last sent for each camera, by device: shown till the
  /// streamer answers.
  final Map<String, bool> _setTo = {};
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
    for (final c in _names.values) {
      c.dispose();
    }
    if (widget.config == null) _config.dispose();
    super.dispose();
  }

  static const String _id = UsbCameraSettings.id;
  Key _key(String name) => Key('$_id-$name');

  List<String> get _streamers => widget.streamers();

  late final ConfigController _config = widget.config ?? ConfigController();

  String? get _target => streamerTarget(
    _streamers,
    chosen: _config.integrations.streamerFor(_id),
    leader: widget.leader?.call(),
  );

  Future<void> _refresh() async {
    // The one picked, else the leader: a new one starts afresh.
    final target = _target;
    if (target == null) return;
    if (target != _streamer) {
      setState(() {
        _streamer = target;
        _status = null;
        _sent = null;
      });
    }
    final status = await widget.getFile(target, '$_id-status.json');
    if (!mounted || _streamer != target) return;
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
    final ok = await widget.putFile(_streamer!, '$_id.json', request);
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

  void _add(String serial, String model) {
    final name = _names[serial]?.text.trim() ?? '';
    _send({
      'add': {
        'name': name.isEmpty ? model : name,
        'serial': serial,
        'unattended': _unattended[serial] ?? true,
      },
      'requestedAt': _now().millisecondsSinceEpoch,
    });
  }

  Future<void> _setUnattended(String device, bool on) async {
    final ok = await _send({
      'set': {'deviceId': device, 'unattended': on},
      'requestedAt': _now().millisecondsSinceEpoch,
    });
    if (ok && mounted) setState(() => _setTo[device] = on);
  }

  void _remove(String device) =>
      _send({'remove': device, 'requestedAt': _now().millisecondsSinceEpoch});

  static List<Map<String, Object?>> _list(Object? value) => [
    for (final c in (value as List?) ?? const [])
      if (c is Map) c.cast<String, Object?>(),
  ];

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final quiet = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final streamers = _streamers;
    if (streamers.isEmpty) {
      return Text(l.usbcamNoStreamer, key: _key('no-streamer'));
    }
    final state = _state;
    final status = _status;
    final cameras = _list(status?['cameras']);
    final added = {for (final c in cameras) c['serial']};
    // Those plugged in and not added yet.
    final detected = [
      for (final d in _list(status?['detected']))
        if (!added.contains(d['serial']) &&
            (d['serial'] as String? ?? '').isNotEmpty)
          d,
    ];
    final busy = _sending || state == 'waiting';
    return Column(
      key: _key('settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(l.usbcamAbout, style: quiet),
        StreamerPicker(
          key: _key('streamer'),
          integration: _id,
          streamers: streamers,
          leader: widget.leader?.call(),
          config: _config,
          label: l.usbcamStreamer,
          onChanged: _refresh,
        ),
        if (state == 'waiting')
          Text(l.netcamWaiting(_streamer ?? ''), key: _key('state'))
        else if (state == 'error')
          Text(
            l.usbcamError(status?['error'] as String? ?? ''),
            key: _key('state'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        Text(
          cameras.isEmpty ? l.usbcamNone : l.usbcamCameras,
          key: _key('cameras'),
        ),
        for (final c in cameras) _camera(c, quiet, theme, busy),
        Text(
          detected.isEmpty ? l.usbcamNoneDetected : l.usbcamDetected,
          key: _key('detected'),
          style: detected.isEmpty ? quiet : null,
        ),
        for (final d in detected) _detected(d, quiet, busy),
        if (_problem case final problem?)
          Text(problem, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }

  /// A camera plugged in, not added: its model and serial, a name
  /// (its model at first) and Add.
  Widget _detected(Map<String, Object?> d, TextStyle quiet, bool busy) {
    final l = context.l10n;
    final serial = d['serial'] as String;
    final model = d['model'] as String? ?? '';
    final name = _names.putIfAbsent(
      serial,
      () => TextEditingController(text: model),
    );
    return Column(
      key: _key('detected-$serial'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          spacing: 8,
          children: [
            const Icon(Icons.usb, size: 18),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: model),
                    TextSpan(text: ' · $serial', style: quiet),
                  ],
                ),
              ),
            ),
          ],
        ),
        Row(
          spacing: 8,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: _key('name-$serial'),
                controller: name,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: l.netcamName),
                onSubmitted: busy ? null : (_) => _add(serial, model),
              ),
            ),
            FilledButton(
              key: _key('add-$serial'),
              onPressed: busy ? null : () => _add(serial, model),
              child: Text(l.usbcamAdd),
            ),
          ],
        ),
        _unattendedSwitch(
          _key('unattended-$serial'),
          _unattended[serial] ?? true,
          busy ? null : (on) => setState(() => _unattended[serial] = on),
          quiet,
        ),
      ],
    );
  }

  /// Unattended: keep only the parts with movement, and delete videos from
  /// the camera once fetched.
  Widget _unattendedSwitch(
    Key key,
    bool value,
    ValueChanged<bool>? onChanged,
    TextStyle quiet,
  ) {
    final l = context.l10n;
    return SwitchListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: value,
      onChanged: onChanged,
      title: Text(l.usbcamUnattended),
      subtitle: Text(l.usbcamUnattendedHint, style: quiet),
    );
  }

  /// A camera added: its name, device, model and serial, when its videos
  /// were last fetched (or why they can't be, or that it's unplugged), and
  /// Remove.
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
    final plugged = c['plugged'] == true;
    // An older streamer doesn't say (nor has the mode); sent and not
    // answered yet, the value sent.
    final unattended = _state == 'waiting' && _setTo.containsKey(device)
        ? _setTo[device]
        : c['unattended'] as bool?;
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
                  if (c['model'] case final String model when model.isNotEmpty)
                    model,
                  c['serial'] as String? ?? '',
                ].join(' · '),
                style: quiet,
              ),
              if (error != null && error.isNotEmpty)
                Text(
                  l.netcamCameraError(error),
                  style: TextStyle(color: theme.colorScheme.error),
                )
              else if (!plugged)
                Text(l.usbcamUnplugged, style: quiet)
              else if (lastFetch != null)
                Text(
                  l.netcamLastFetch(
                    formatEventTime(
                      DateTime.fromMillisecondsSinceEpoch(lastFetch),
                    ),
                  ),
                  style: quiet,
                ),
              if (unattended != null)
                _unattendedSwitch(
                  _key('unattended-$device'),
                  unattended,
                  busy ? null : (on) => _setUnattended(device, on),
                  quiet,
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
