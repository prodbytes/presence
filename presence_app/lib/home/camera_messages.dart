import 'dart:async';

import 'package:flutter/material.dart';

import '../status_pill.dart';

/// A message over the camera: a clip that started, a sign-in that failed.
@immutable
class CameraMessage {
  const CameraMessage({
    required this.icon,
    required this.label,
    this.opensEvents = false,
    this.error = false,
  });

  final IconData icon;
  final String label;

  /// Tapping it opens Monitoring, where its event is (a clip).
  final bool opensEvents;

  /// Something went wrong: its icon is in the error color.
  final bool error;
}

/// A [CameraMessage] as a pill after the readiness one, where it moves and
/// covers nothing; tapping it opens the clip's event ([onView]), where
/// there's one and access. A label too long for the room is cut short; the
/// tooltip has it all.
class CameraMessagePill extends StatelessWidget {
  const CameraMessagePill({super.key, required this.message, this.onView});

  final CameraMessage message;
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = message.label;
    return StatusPill(
      key: const Key('camera-message'),
      leading: Icon(
        message.icon,
        size: 18,
        color: message.error ? scheme.error : scheme.primary,
      ),
      label: label,
      semantics: onView == null ? label : '$label. Tap to view it.',
      // News: read out when it shows.
      liveRegion: true,
      onTap: onView,
    );
  }
}

/// The message over the camera ([current]), until a newer one replaces it
/// or [showFor] passes; listeners hear both.
class CameraMessages extends ChangeNotifier {
  CameraMessages({required this.showFor});

  /// How long a message stays.
  final Duration showFor;

  /// The message showing; null when there's none.
  CameraMessage? get current => _current;
  CameraMessage? _current;
  Timer? _timer;

  /// Shows [message] for [showFor], replacing any message showing.
  void show(CameraMessage message) {
    _timer?.cancel();
    _timer = Timer(showFor, () {
      _current = null;
      notifyListeners();
    });
    _current = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
