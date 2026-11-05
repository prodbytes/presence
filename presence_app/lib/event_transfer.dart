import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'event_details.dart';
import 'events.dart';
import 'l10n/l10n.dart';
import 'storage/event_file.dart';

/// Makes [event]'s file ([EventFile]; `Persistence.exportEvent`).
typedef ExportEvent = Future<Uint8List> Function(AppEvent event);

/// Takes in an event's file ([EventFile]; `Persistence.importEvent`) and
/// shows its event; returns it.
typedef ImportEvent = Future<List<AppEvent>> Function(Uint8List bytes);

/// Downloads one event as a file ([EventFile]) from its card's header,
/// beside its indicators and Delete: the browser's download on the web,
/// the share sheet on iOS and Android (Save to Files, AirDrop…), a save
/// dialog on the desktop.
class EventDownloadButton extends StatefulWidget {
  const EventDownloadButton({
    super.key,
    required this.event,
    required this.export,
  });

  final AppEvent event;
  final ExportEvent export;

  @override
  State<EventDownloadButton> createState() => _EventDownloadButtonState();
}

class _EventDownloadButtonState extends State<EventDownloadButton> {
  bool _busy = false;

  Future<void> _download() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = context.l10n.eventDownloadFailed;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      final bytes = await widget.export(widget.event);
      await saveEventFile(
        bytes,
        EventFile.nameOf(widget.event.id),
        origin: origin,
      );
    } catch (e) {
      debugPrint('Presence: could not download event ${widget.event.id}: $e');
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: Key('event-download-${widget.event.id}'),
    tooltip: context.l10n.eventDownload,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    iconSize: 18,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    icon: _busy
        ? const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.download_outlined),
    onPressed: _busy ? null : _download,
  );
}

/// Uploads one event's file ([EventFile], downloaded from a card) into
/// this device's events, in the events' top row: it picks the file, and
/// the event shows in the list (and syncs with the signed-in profile).
/// Hidden when the app can't take events in ([EventDetailsScope.importEvent]).
class UploadEventButton extends StatefulWidget {
  const UploadEventButton({super.key, this.pick = pickEventFile});

  /// Picks the file; null when none was picked. Replaceable in tests.
  final Future<Uint8List?> Function() pick;

  @override
  State<UploadEventButton> createState() => _UploadEventButtonState();
}

class _UploadEventButtonState extends State<UploadEventButton> {
  bool _busy = false;

  Future<void> _upload(ImportEvent import) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      final bytes = await widget.pick();
      if (bytes == null) return;
      await import(bytes);
      messenger?.showSnackBar(SnackBar(content: Text(l.eventsUploaded)));
    } on EventFileException catch (e) {
      debugPrint('Presence: could not upload an event: $e');
      messenger?.showSnackBar(SnackBar(content: Text(l.eventsUploadNotEvent)));
    } catch (e) {
      debugPrint('Presence: could not upload an event: $e');
      messenger?.showSnackBar(SnackBar(content: Text(l.eventsUploadFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final import = EventDetailsScope.maybeOf(context)?.importEvent;
    if (import == null) return const SizedBox.shrink();
    return IconButton(
      key: const Key('events-upload'),
      tooltip: context.l10n.eventsUpload,
      visualDensity: VisualDensity.compact,
      icon: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.upload_file_outlined),
      onPressed: _busy ? null : () => _upload(import),
    );
  }
}

const _eventFiles = XTypeGroup(
  label: 'Presence event',
  extensions: [EventFile.extension],
  mimeTypes: [EventFile.mimeType],
  uniformTypeIdentifiers: ['public.json'],
);

/// Saves [bytes] as the file [name]: downloaded on the web, through the
/// share sheet on iOS and Android ([origin]: the button, where an iPad's
/// sheet points), where the user picks on the desktop.
Future<void> saveEventFile(Uint8List bytes, String name, {Rect? origin}) async {
  final file = XFile.fromData(bytes, mimeType: EventFile.mimeType, name: name);
  if (kIsWeb) return file.saveTo(name);
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS || TargetPlatform.android:
      await SharePlus.instance.share(
        ShareParams(
          files: [file],
          fileNameOverrides: [name],
          sharePositionOrigin: origin,
        ),
      );
    default:
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: const [_eventFiles],
      );
      if (location != null) await file.saveTo(location.path);
  }
}

/// Picks an event's file and reads it; null when none was picked.
Future<Uint8List?> pickEventFile() async {
  final file = await openFile(acceptedTypeGroups: const [_eventFiles]);
  return file?.readAsBytes();
}
