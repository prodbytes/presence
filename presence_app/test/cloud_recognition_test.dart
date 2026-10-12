import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/recognition/cloud_recognition.dart';

import 'fakes.dart';
import 'sealed.dart';

/// The training API in memory: what it holds, and what it was sent.
class FakeCloudClient implements CloudRecognitionClient {
  int? trainedAt;
  final held = <String, int>{};
  final uploads = <List<CloudLabel>>[];
  final trainings = <(Map<String, String>, Set<String>)>[];
  Object? error;
  int nextTrainedAt = 5000;

  @override
  Future<CloudStatus> status(String idToken) async {
    if (error case final e?) throw e;
    return CloudStatus(trainedAt: trainedAt, labels: Map.of(held));
  }

  @override
  Future<void> upload(String idToken, List<CloudLabel> labels) async {
    uploads.add(labels);
    for (final l in labels) {
      held[l.id] = l.labeledAt;
    }
  }

  @override
  Future<int> train(
    String idToken,
    Map<String, String> names,
    Iterable<String> clips,
  ) async {
    trainings.add((Map.of(names), clips.toSet()));
    return trainedAt = nextTrainedAt;
  }

  @override
  Future<(int?, Map<String, List<CloudMatch>>)> identify(
    String idToken,
    Map<String, (String, Uint8List)> crops,
  ) => throw UnimplementedError();

  @override
  Future<Map<String, List<CloudPetLabel>>> describe(
    String idToken,
    Map<String, (String, Uint8List)> crops,
  ) => throw UnimplementedError();
}

VideoClip clip() => VideoClip.restored(
  id: 'clip-${AppEvent.newId()}',
  cameraId: 'cam',
  cameraLabel: 'Back camera',
  before: const Duration(seconds: 15),
  after: const Duration(seconds: 15),
  past: null,
  full: ClipMedia(
    url: 'blob:clip',
    start: Duration.zero,
    end: const Duration(seconds: 30),
  ),
);

void main() {
  tearDown(() {
    Annotation.clock = () => DateTime.now().millisecondsSinceEpoch;
  });

  group('labels', () {
    test('someone\'s labels are timed; recognition\'s tags aren\'t', () {
      var now = 1000;
      Annotation.clock = () => now;
      final a = ClipAnnotations();
      final frame = testFrame([1], 0);
      final manual = a.add('Rex', 0.5, 0.5, frame: frame)!;
      expect(manual.labeledAt, 1000);
      final detected = a.add(
        'Ana',
        0.2,
        0.5,
        frame: frame,
        source: TagSource.detected,
        confidence: 0.95,
      )!;
      expect(detected.labeledAt, isNull);
      final suggested = a.add(
        'Bo',
        0.8,
        0.5,
        frame: frame,
        source: TagSource.suggested,
        confidence: 0.6,
      )!;
      expect(suggested.labeledAt, isNull);

      now = 2000;
      a.confirm(suggested.id);
      expect(a.byId(suggested.id)!.labeledAt, 2000, reason: 'confirmed');
      now = 3000;
      a.rename(manual.id, 'Rexy');
      expect(a.byId(manual.id)!.labeledAt, 3000, reason: 'renamed');
      a.rename(detected.id, 'Anna');
      expect(a.byId(detected.id)!.labeledAt, isNull);

      final back = ClipAnnotations.fromJson(jsonDecode(jsonEncode(a.toJson())));
      expect(back.byId(manual.id)!.labeledAt, 3000);
      expect(back.byId(detected.id)!.labeledAt, isNull);
    });

    test('an older tag\'s time comes from its ID', () {
      final at = DateTime.utc(2026, 9, 1).microsecondsSinceEpoch;
      final tag = Annotation(
        id: '${at.toRadixString(36)}-abcdefg',
        name: 'Rex',
        x: 0.5,
        y: 0.5,
      );
      expect(tag.labeledTime, at ~/ 1000);
      expect(
        const Annotation(id: 'x', name: 'R', x: 0, y: 0).labeledTime,
        isZero,
      );
    });
  });

  test('the settings keep when it was trained and checked', () {
    const r = RecognitionConfig(cloudTrainedAt: 5, cloudCheckedAt: 7);
    final back = RecognitionConfig.fromJson(
      jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
    );
    expect(back, r);
    expect(
      const RecognitionConfig().toJson().containsKey('cloudTrainedAt'),
      false,
    );
    expect(RecognitionConfig.fromJson(const {}).cloudTrainedAt, isNull);
  });

  group('training check', () {
    late AppEventBus bus;
    late EventLog log;
    late ConfigController config;
    late FakeAuthService auth;
    late FakeRolesClient rolesClient;
    late RolesService roles;
    late FakeCloudClient client;
    late int now;
    late int crops;

    setUp(() async {
      bus = AppEventBus();
      log = EventLog(bus.stream);
      config = ConfigController();
      auth = FakeAuthService.signedIn();
      rolesClient = FakeRolesClient();
      roles = RolesService(auth: auth, client: rolesClient);
      // Its start check, then the account's roles.
      await pumpEventQueue();
      expect(roles.isPremium, isTrue);
      client = FakeCloudClient();
      now = 100000000;
      crops = 0;
    });

    CloudTrainer trainer({Set<String> nobody = const {}}) => CloudTrainer(
      auth: auth,
      roles: roles,
      log: log,
      config: config,
      client: client,
      now: () => now,
      crop: (clip, label) async {
        crops++;
        return nobody.contains(label.name)
            ? null
            : ('pet', Uint8List(CloudCrop.side * CloudCrop.side * 3));
      },
    );

    /// A clip with [n] labels of [name], placed at [at].
    ClipRequested labeled(String name, int n, {required int at}) {
      Annotation.clock = () => at;
      final a = ClipAnnotations();
      final frame = testFrame([1], 0);
      for (var i = 0; i < n; i++) {
        a.add(name, 0.5, 0.5, frame: frame);
      }
      final event = ClipRequested(clip(), annotations: a);
      log.addHistory([event]);
      return event;
    }

    test('not premium: nothing asked', () async {
      rolesClient.roles = const [userRole];
      await roles.refresh();
      labeled('Suerte', 5, at: 10);
      expect(await trainer().check(force: true), TrainingOutcome.notPremium);
      expect(client.trainings, isEmpty);
    });

    test('a first training needs 3 labels', () async {
      labeled('Suerte', 2, at: 10);
      final t = trainer();
      expect(await t.check(force: true), TrainingOutcome.upToDate);
      expect(client.trainings, isEmpty);
      expect(config.recognition.cloudCheckedAt, now);
      final third = labeled('Suerte', 1, at: 20);
      expect(await t.check(force: true), TrainingOutcome.trained);
      expect(client.uploads.single, hasLength(3));
      final (names, clips) = client.trainings.single;
      expect(names.values.toSet(), {'Suerte'});
      expect(names, hasLength(3));
      expect(clips, contains(third.id));
      expect(config.recognition.cloudTrainedAt, 5000);
      final label = client.uploads.single.first;
      expect(label.kind, 'pet');
      expect(label.clipId, isNotEmpty);
    });

    test('again with 5 new labels, sending only the new crops', () async {
      labeled('Suerte', 4, at: 10);
      final t = trainer();
      expect(await t.check(force: true), TrainingOutcome.trained);
      expect(client.trainedAt, 5000);
      labeled('Suerte', 4, at: 6000);
      expect(await t.check(force: true), TrainingOutcome.upToDate);
      labeled('Fido', 1, at: 7000);
      client.nextTrainedAt = 8000;
      expect(await t.check(force: true), TrainingOutcome.trained);
      expect(client.uploads.last, hasLength(5));
      expect(client.trainings.last.$1, hasLength(9));
      expect(config.recognition.cloudTrainedAt, 8000);
    });

    test('again after 7 days, even with nothing new', () async {
      labeled('Suerte', 3, at: 10);
      client
        ..trainedAt = now
        ..held.addAll({for (final l in trainer().placedLabels().keys) l: 10});
      final t = trainer();
      expect(await t.check(force: true), TrainingOutcome.upToDate);
      now += const Duration(days: 7).inMilliseconds;
      expect(await t.check(force: true), TrainingOutcome.trained);
      expect(client.uploads, isEmpty, reason: 'the API has every crop');
      expect(crops, 0);
    });

    test('every 24 h, unless forced', () async {
      labeled('Suerte', 1, at: 10);
      final t = trainer();
      expect(await t.check(force: true), TrainingOutcome.upToDate);
      now += const Duration(hours: 23).inMilliseconds;
      expect(await t.check(), TrainingOutcome.notDue);
      now += const Duration(hours: 1).inMilliseconds;
      expect(await t.check(), TrainingOutcome.upToDate);
    });

    test('a failure is tried again after 15 minutes', () async {
      labeled('Suerte', 3, at: 10);
      client.error = RolesException(503);
      final t = trainer();
      expect(await t.check(force: true), TrainingOutcome.failed);
      expect(config.recognition.cloudCheckedAt, isNull);
      client.error = null;
      now += const Duration(minutes: 10).inMilliseconds;
      expect(await t.check(), TrainingOutcome.notDue);
      now += const Duration(minutes: 5).inMilliseconds;
      expect(await t.check(), TrainingOutcome.trained);
    });

    test('crops go 8 to a request; labels without one are left out', () async {
      labeled('Suerte', 11, at: 10);
      labeled('Ghost', 2, at: 10);
      expect(
        await trainer(nobody: {'Ghost'}).check(force: true),
        TrainingOutcome.trained,
      );
      expect([for (final u in client.uploads) u.length], [8, 3]);
      expect(client.trainings.single.$1, hasLength(11));
    });

    test('Train now trains whatever there is', () async {
      labeled('Suerte', 1, at: 10);
      expect(await trainer().trainNow(), TrainingOutcome.trained);
    });

    test('becoming premium checks at once', () async {
      rolesClient.roles = const [userRole];
      await roles.refresh();
      labeled('Suerte', 3, at: 10);
      final t = trainer()..start();
      addTearDown(t.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(client.trainings, isEmpty);
      rolesClient.roles = const [userRole, premiumRole];
      await roles.refresh();
      await pumpEventQueue();
      expect(client.trainings, hasLength(1));
    });
  });

  test('cloud labels join the object tags: the surer kept', () {
    final a = ClipAnnotations();
    var heard = 0;
    a.addListener(() => heard++);
    a.addObjects(const [ObjectTag(label: 'black cat', ms: 0, score: 0.6)]);
    expect(a.objects!.single.label, 'black cat', reason: 'none before');
    a.setObjects(const [
      ObjectTag(label: 'cat', ms: 0, score: 0.9),
      ObjectTag(label: 'black cat', ms: 0, score: 0.6),
    ]);
    a.addObjects(const [
      ObjectTag(label: 'black cat', ms: 2000, score: 0.9),
      ObjectTag(label: 'Persian', ms: 1000, score: 0.8),
    ]);
    expect(a.objects!.map((o) => (o.label, o.ms, o.score)), [
      ('cat', 0, 0.9),
      ('black cat', 2000, 0.9),
      ('Persian', 1000, 0.8),
    ]);
    heard = 0;
    a.addObjects(const [ObjectTag(label: 'Persian', ms: 0, score: 0.7)]);
    expect(heard, 0, reason: 'nothing surer: unchanged');
  });

  group('HTTP client', () {
    test('status, labels, train and identify', () async {
      final requests = <http.Request>[];
      final client = HttpCloudRecognitionClient(
        Uri.parse('https://presence.example/'),
        client: MockClient((request) async {
          requests.add(request);
          return switch (request.url.path) {
            '/api/recognition/status' => http.Response(
              '{"model":"dinov2-large","trainedAt":42,'
              '"labels":[{"id":"a","labeledAt":7}],"subjects":[]}',
              200,
            ),
            '/api/recognition/labels' => http.Response('{"stored":1}', 200),
            '/api/recognition/train' => http.Response(
              '{"trainedAt":43,"labels":1,"subjects":[]}',
              200,
            ),
            '/api/recognition/identify' => http.Response(
              '{"trainedAt":43,"results":[{"id":"0","labels":'
              '[{"name":"Suerte","confidence":0.93}]}]}',
              200,
            ),
            _ => http.Response('{"error":"x"}', 403),
          };
        }),
      );
      final status = await client.status('tok');
      expect(status.trainedAt, 42);
      expect(status.labels, {'a': 7});
      final pixels = Uint8List(CloudCrop.side * CloudCrop.side * 3);
      await client.upload('tok', [
        CloudLabel(
          id: 'a',
          clipId: 'c',
          name: 'Suerte',
          kind: 'pet',
          labeledAt: 7,
          pixels: pixels,
        ),
      ]);
      final sent = jsonDecode(requests.last.body) as Map;
      final label = (sent['labels'] as List).single as Map;
      expect(label['clipId'], 'c');
      expect(base64Decode(label['pixels'] as String), hasLength(pixels.length));
      expect(requests.last.headers['authorization'], 'Bearer tok');
      expect(await client.train('tok', {'a': 'Suerte'}, ['c']), 43);
      expect(jsonDecode(requests.last.body), {
        'labels': [
          {'id': 'a', 'name': 'Suerte'},
        ],
        'clips': ['c'],
      });
      final (trainedAt, matches) = await client.identify('tok', {
        '0': ('pet', pixels),
      });
      expect(trainedAt, 43);
      expect(matches['0']!.single.name, 'Suerte');
      expect(matches['0']!.single.confidence, 0.93);
    });

    test('describe: breeds and coats', () async {
      late http.Request request;
      final client = HttpCloudRecognitionClient(
        Uri.parse('https://presence.example/'),
        client: MockClient((r) async {
          request = r;
          return http.Response(
            '{"model":"siglip2-base-patch16-224","results":['
            '{"id":"0","labels":[{"label":"Persian","type":"breed",'
            '"confidence":0.81},{"label":"black cat","type":"coat",'
            '"confidence":1.2},{"label":" ","type":"coat","confidence":0.9}]},'
            '{"id":"1","labels":[]}]}',
            200,
          );
        }),
      );
      final pixels = Uint8List(CloudCrop.side * CloudCrop.side * 3);
      final labels = await client.describe('tok', {'0': ('cat', pixels)});
      expect(request.url.path, '/api/recognition/describe');
      final crop = ((jsonDecode(request.body) as Map)['crops'] as List).single;
      expect((crop as Map)['kind'], 'cat');
      expect(labels['0']!.map((l) => (l.label, l.type, l.confidence)), [
        ('Persian', 'breed', 0.81),
        ('black cat', 'coat', 1.0),
      ]);
      expect(labels['1'], isEmpty);
    });

    test('a refusal throws its status', () async {
      final client = HttpCloudRecognitionClient(
        Uri.parse('https://presence.example/'),
        client: MockClient((_) async => http.Response('{}', 403)),
      );
      await expectLater(
        client.status('tok'),
        throwsA(
          isA<RolesException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
    });
  });

  testWidgets('Settings: the last training, and Train now', (tester) async {
    final bus = AppEventBus();
    final log = EventLog(bus.stream);
    final config = ConfigController();
    final auth = FakeAuthService.signedIn();
    final roles = RolesService(auth: auth, client: FakeRolesClient());
    await tester.runAsync(pumpEventQueue);
    final client = FakeCloudClient();
    Annotation.clock = () => 10;
    final a = ClipAnnotations()
      ..add('Suerte', 0.5, 0.5, frame: testFrame([1], 0));
    log.addHistory([ClipRequested(clip(), annotations: a)]);
    final trainer = CloudTrainer(
      auth: auth,
      roles: roles,
      log: log,
      config: config,
      client: client,
      crop: (_, _) async =>
          ('pet', Uint8List(CloudCrop.side * CloudCrop.side * 3)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudTrainerScope(
            trainer: trainer,
            child: const CloudRecognitionTile(),
          ),
        ),
      ),
    );
    expect(find.textContaining('Not trained yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cloud-recognition-train')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last trained'), findsOneWidget);
    expect(find.textContaining('Trained.'), findsOneWidget);
  });
}
