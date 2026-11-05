import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/crypto/media_seal.dart';
import 'package:presence_app/event_details.dart';
import 'package:presence_app/event_transfer.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/storage/event_file.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';

void main() {
  final time = DateTime(2026, 11, 5, 9).millisecondsSinceEpoch;
  const jpeg = [0xFF, 0xD8, 1, 2, 3];
  const frameJpeg = [0xFF, 0xD8, 9, 9];
  final video = Uint8List.fromList(List.generate(70000, (i) => i % 251));

  /// A device: its storage, sealing with its own key.
  ({Persistence persistence, AppEventBus bus, MediaSeal seal}) device(
    String id,
  ) {
    final bus = AppEventBus();
    final seal = MediaSeal.forTests(deviceId: id);
    final persistence = Persistence(
      factory: Future.value(newIdbFactoryMemory()),
      bus: bus,
      config: ConfigController(),
      seal: seal,
      mediaStore: (store) => IdbMediaStore(store, const MediaIo(), seal),
    );
    addTearDown(() {
      persistence.dispose();
      bus.close();
    });
    return (persistence: persistence, bus: bus, seal: seal);
  }

  Future<void> putClipEvent(
    Persistence persistence,
    MediaSeal seal, {
    Map<String, Object?> extra = const {},
  }) async {
    final store = await persistence.store;
    final media = await persistence.media;
    await store.putEvent({
      'id': 'e1',
      'type': ClipRequested.clipRequestedType,
      'title': 'Motion',
      'time': time,
      'clipId': 'c1',
      'clipState': 'complete',
      'profileId': 'theirs',
      'deviceId': 'phone-1',
      'frames': {'f1': await seal.seal(Uint8List.fromList(frameJpeg))},
      ...extra,
    });
    await store.putClip({
      'id': 'c1',
      'eventId': 'e1',
      'cameraId': 'cam',
      'cameraLabel': 'Garden',
      'requestedAt': time,
      'state': 'complete',
      'thumbnail': await seal.seal(Uint8List.fromList(jpeg)),
      'full': {
        'mediaId': 'c1-full',
        'startMs': 0,
        'endMs': 15000,
        'mimeType': 'video/mp4',
      },
    });
    await media.saveBytes('c1-full', await seal.seal(video));
  }

  Future<Uint8List> readMedia(Persistence persistence, String id) async {
    final bytes = await (await persistence.media).read(id);
    final builder = BytesBuilder();
    await for (final chunk in bytes.stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  group('EventFile', () {
    test(
      'a downloaded event holds its record, clip and media, opened',
      () async {
        final a = device('device_a');
        await putClipEvent(a.persistence, a.seal);

        final file = await a.persistence.exportEvent('e1');
        final json = jsonDecode(utf8.decode(file)) as Map<String, Object?>;
        expect(json['format'], EventFile.format);
        expect(json['version'], EventFile.version);
        final event = json['event']! as Map;
        expect(event['id'], 'e1');
        expect(
          base64Decode((event['frames']! as Map)['f1'] as String),
          frameJpeg,
        );
        final clip = json['clip']! as Map;
        expect(base64Decode(clip['thumbnail'] as String), jpeg);
        expect((clip['full']! as Map)['mediaId'], 'c1-full');
        expect(
          base64Decode((json['media']! as Map)['c1-full'] as String),
          video,
        );
      },
    );

    test('an uploaded event is stored on another device, sealed with its '
        'key, in its profile, and named changed for sync', () async {
      final a = device('device_a');
      await putClipEvent(a.persistence, a.seal);
      final file = await a.persistence.exportEvent('e1');

      final b = device('device_b');
      final changed = <Set<String>>[];
      b.persistence.changes.listen(changed.add);
      final events = await b.persistence.importEvent(file, profileId: 'mine');
      expect(events.map((e) => e.id), ['e1']);
      final shown = events.single as ClipRequested;
      expect(shown.profileId, 'mine');
      expect(shown.clip.id, 'c1');

      final store = await b.persistence.store;
      final event = (await store.getEvent('e1'))!;
      expect(event['profileId'], 'mine');
      final frame = (event['frames']! as Map)['f1'] as Uint8List;
      expect(SealFormat.keyIdOf(frame), 'device_b');
      expect(await b.seal.open(frame), frameJpeg);
      final clip = (await store.getClip('c1'))!;
      expect(await b.seal.open(clip['thumbnail']! as Uint8List), jpeg);
      final recording = await readMedia(b.persistence, 'c1-full');
      expect(SealFormat.keyIdOf(recording), 'device_b');
      expect(await b.seal.open(recording), video);
      await Future<void>.delayed(Duration.zero);
      expect(changed.expand((ids) => ids), contains('e1'));
    });

    test('a deleted event is not downloaded', () async {
      final a = device('device_a');
      await putClipEvent(a.persistence, a.seal, extra: {'deletedAt': time});
      expect(
        a.persistence.exportEvent('e1'),
        throwsA(isA<EventFileException>()),
      );
      expect(
        a.persistence.exportEvent('nope'),
        throwsA(isA<EventFileException>()),
      );
    });

    test(
      'a file that is not an event, or has unsafe IDs, is refused',
      () async {
        final b = device('device_b');
        Future<void> refused(Object? json) => expectLater(
          b.persistence.importEvent(
            utf8.encode(json is String ? json : jsonEncode(json)),
            profileId: 'mine',
          ),
          throwsA(isA<EventFileException>()),
        );
        await refused('not json');
        await refused({'format': 'other', 'version': 1, 'event': {}});
        await refused({
          'format': EventFile.format,
          'version': EventFile.version + 1,
          'event': {'id': 'e1', 'time': time},
        });
        await refused({
          'format': EventFile.format,
          'version': 1,
          'event': {'id': '../e1', 'time': time},
        });
        await refused({
          'format': EventFile.format,
          'version': 1,
          'event': {'id': 'e1', 'time': time, 'clipId': 'c1'},
          'clip': {'id': 'c2'},
        });
      },
    );

    test('a recording with an unsafe media ID is left out', () async {
      final b = device('device_b');
      await b.persistence.importEvent(
        utf8.encode(
          jsonEncode({
            'format': EventFile.format,
            'version': 1,
            'event': {
              'id': 'e1',
              'type': ClipRequested.clipRequestedType,
              'title': 'Motion',
              'time': time,
              'clipId': 'c1',
            },
            'clip': {
              'id': 'c1',
              'full': {'mediaId': '../../evil', 'startMs': 0, 'endMs': 1},
            },
            'media': {'../../evil': base64Encode(video)},
          }),
        ),
        profileId: 'mine',
      );
      final clip = (await (await b.persistence.store).getClip('c1'))!;
      expect(clip.containsKey('full'), isFalse);
      expect(await (await b.persistence.media).ids(), isEmpty);
    });
  });

  group('Download and Upload buttons', () {
    late AppEventBus bus;
    late EventLog log;
    late EventFilters filters;

    setUp(() {
      bus = AppEventBus();
      log = EventLog(bus.stream)
        ..addHistory([
          AppEvent(
            icon: Icons.circle,
            id: 'e1',
            title: 'Started',
            time: DateTime(2026, 11, 5, 9),
            profileId: 'mine',
          ),
        ]);
      filters = EventFilters()..showSystemEvents.value = true;
    });

    tearDown(() {
      filters.dispose();
      log.dispose();
      bus.close();
    });

    Future<void> show(
      WidgetTester tester, {
      ExportEvent? export,
      ImportEvent? import,
      Future<Uint8List?> Function()? pick,
    }) => tester.pumpWidget(
      EventDetailsScope(
        profileId: 'mine',
        exportEvent: export,
        importEvent: import,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                UploadEventButton(pick: pick ?? () async => null),
                Expanded(
                  child: EventTimeline(
                    log: log,
                    filters: filters,
                    profileId: 'mine',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    testWidgets('without the app\'s callbacks, neither shows', (tester) async {
      await show(tester);
      expect(find.byKey(const Key('event-download-e1')), findsNothing);
      expect(find.byKey(const Key('events-upload')), findsNothing);
    });

    testWidgets('each card has Download in its header, which exports its '
        'event', (tester) async {
      final exported = <String>[];
      await show(
        tester,
        export: (e) async {
          exported.add(e.id);
          throw StateError('no file here');
        },
      );
      final button = find.byKey(const Key('event-download-e1'));
      expect(
        find.descendant(
          of: find.byKey(const Key('event-actions-e1')),
          matching: button,
        ),
        findsOneWidget,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(exported, ['e1']);
      expect(find.text("Couldn't download the event"), findsOneWidget);
    });

    testWidgets('Upload takes in the picked file, and says so', (tester) async {
      final taken = <Uint8List>[];
      await show(
        tester,
        import: (bytes) async {
          taken.add(bytes);
          if (bytes.first == 0) throw const EventFileException('no');
          return const [];
        },
        pick: () async =>
            taken.isEmpty ? Uint8List.fromList([1]) : Uint8List.fromList([0]),
      );
      await tester.tap(find.byKey(const Key('events-upload')));
      await tester.pumpAndSettle();
      expect(find.text('Event uploaded'), findsOneWidget);

      ScaffoldMessenger.of(tester.element(find.byType(Scaffold)))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('events-upload')));
      await tester.pumpAndSettle();
      expect(find.text("That file isn't a Presence event"), findsOneWidget);
      expect(taken, hasLength(2));
    });
  });
}
