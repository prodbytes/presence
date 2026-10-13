import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../annotations.dart';
import '../auth/auth_service.dart';
import '../auth/roles_service.dart';
import '../clips.dart';
import '../config.dart';
import '../events.dart';
import '../l10n/l10n.dart';
import '../subjects.dart';
import 'image.dart';
import 'vision.dart';

/// Cloud recognition's crops: [side] × [side] pixels, RGB, row by row
/// ([side] × [side] × 3 bytes), a square around a person or pet (black
/// outside the frame), as DINOv2 in the recognition API takes them.
abstract final class CloudCrop {
  static const int side = 224;

  /// [box] of [image], squared, as a crop.
  static Uint8List of(RgbaImage image, Box box) {
    final tensor = toTensor(
      image,
      Region.box(image, box, square: true),
      width: side,
      height: side,
      scale: PixelScale.bytes,
    ) as Int32List;
    return Uint8List.fromList(tensor);
  }

  /// "person", or "pet" for a cat or a dog.
  static String kindOf(SeenKind kind) => kind.isPet ? 'pet' : 'person';

  /// "cat" or "dog" (breeds and coats); null for a person.
  static String? speciesOf(SeenKind kind) => switch (kind) {
    SeenKind.cat => 'cat',
    SeenKind.dog => 'dog',
    SeenKind.person => null,
  };
}

/// A label someone placed, as the training API learns it.
@immutable
class CloudLabel {
  const CloudLabel({
    required this.id,
    required this.clipId,
    required this.name,
    required this.kind,
    required this.labeledAt,
    required this.pixels,
  });

  final String id;

  /// The clip's event it's on: the API forgets a label only when told its
  /// clip no longer has it.
  final String clipId;
  final String name;

  /// "person" or "pet".
  final String kind;
  final int labeledAt;

  /// A [CloudCrop].
  final Uint8List pixels;

  Map<String, Object?> toJson() => {
    'id': id,
    'clipId': clipId,
    'name': name,
    'kind': kind,
    'labeledAt': labeledAt,
    'pixels': base64Encode(pixels),
  };
}

/// What the training API holds for the profile.
@immutable
class CloudStatus {
  const CloudStatus({required this.trainedAt, required this.labels});

  /// When it was last trained (ms since the epoch); null if never.
  final int? trainedAt;

  /// The labels it has, by ID, with their `labeledAt`.
  final Map<String, int> labels;
}

/// One of the profile's subjects a crop may be, and how sure (0 to 1).
@immutable
class CloudMatch {
  const CloudMatch(this.name, this.confidence);

  final String name;
  final double confidence;
}

/// A cat's or dog's breed ("Persian") or coat ("black cat"), as cloud
/// recognition named it, and how sure (0 to 1). [type]: `breed` or `coat`.
@immutable
class CloudPetLabel {
  const CloudPetLabel(this.label, this.type, this.confidence);

  final String label;
  final String type;
  final double confidence;
}

/// The recognition API (premium only; specs/cloud-recognition.md), next to
/// the auth API. Failures throw [RolesException] with the HTTP status (403:
/// not premium; 413: too many labels; 429: throttled; 503/504: a model
/// still loading, try again).
abstract class CloudRecognitionClient {
  Future<CloudStatus> status(String idToken);

  /// Sends up to [maxBatch] labels' crops; the API keeps their embeddings.
  Future<void> upload(String idToken, List<CloudLabel> labels);

  /// Trains on the profile's labels: [names] (ID to name) are the labels on
  /// [clips], the clips this device has; the API forgets its labels on those
  /// clips that aren't among them (removed), keeps those on other clips
  /// (this device's history doesn't reach them), and renames the renamed.
  /// When it was trained.
  Future<int> train(
    String idToken,
    Map<String, String> names,
    Iterable<String> clips,
  );

  /// Which subjects each crop (by its ID) may be: (when the model was
  /// trained, or null if never; the matches, surest first).
  Future<(int?, Map<String, List<CloudMatch>>)> identify(
    String idToken,
    Map<String, (String kind, Uint8List pixels)> crops,
  );

  /// Each cat's and dog's breed and coat, those the API is sure enough of,
  /// by its crop's ID: [crops] are (`cat` or `dog`, its [CloudCrop]). Needs
  /// no training; its own function, so it never waits for [identify].
  Future<Map<String, List<CloudPetLabel>>> describe(
    String idToken,
    Map<String, (String species, Uint8List pixels)> crops,
  );

  /// The most crops or labels in one request.
  static const int maxBatch = 8;
}

class HttpCloudRecognitionClient implements CloudRecognitionClient {
  HttpCloudRecognitionClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  /// A request takes at most this long (the API gives up at 30 s).
  static const Duration timeout = Duration(seconds: 35);

  Future<Map<String, Object?>> _send(
    String method,
    String path,
    String idToken, [
    Object? body,
  ]) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] = 'Bearer $idToken';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    final response = await http.Response.fromStream(await _client.send(request))
        .timeout(timeout);
    if (response.statusCode ~/ 100 != 2) {
      throw RolesException(response.statusCode);
    }
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }

  @override
  Future<CloudStatus> status(String idToken) async {
    final body = await _send('GET', '/api/recognition/status', idToken);
    final labels = body['labels'];
    return CloudStatus(
      trainedAt: (body['trainedAt'] as num?)?.toInt(),
      labels: {
        if (labels is List)
          for (final l in labels)
            if (l is Map && l['id'] is String)
              l['id'] as String: (l['labeledAt'] as num?)?.toInt() ?? 0,
      },
    );
  }

  @override
  Future<void> upload(String idToken, List<CloudLabel> labels) =>
      _send('POST', '/api/recognition/labels', idToken, {
        'labels': [for (final l in labels) l.toJson()],
      });

  @override
  Future<int> train(
    String idToken,
    Map<String, String> names,
    Iterable<String> clips,
  ) async {
    final body = await _send('POST', '/api/recognition/train', idToken, {
      'labels': [
        for (final MapEntry(:key, :value) in names.entries)
          {'id': key, 'name': value},
      ],
      'clips': [...clips],
    });
    return (body['trainedAt'] as num).toInt();
  }

  @override
  Future<(int?, Map<String, List<CloudMatch>>)> identify(
    String idToken,
    Map<String, (String kind, Uint8List pixels)> crops,
  ) async {
    final body = await _send('POST', '/api/recognition/identify', idToken, {
      'crops': [
        for (final MapEntry(key: id, value: (kind, pixels)) in crops.entries)
          {'id': id, 'kind': kind, 'pixels': base64Encode(pixels)},
      ],
    });
    final results = body['results'];
    return (
      (body['trainedAt'] as num?)?.toInt(),
      {
        if (results is List)
          for (final r in results)
            if (r is Map && r['id'] is String)
              r['id'] as String: [
                if (r['labels'] case final List labels)
                  for (final l in labels)
                    if (l is Map &&
                        l['name'] is String &&
                        l['confidence'] is num)
                      CloudMatch(
                        l['name'] as String,
                        (l['confidence'] as num).toDouble().clamp(0, 1),
                      ),
              ],
      },
    );
  }

  @override
  Future<Map<String, List<CloudPetLabel>>> describe(
    String idToken,
    Map<String, (String species, Uint8List pixels)> crops,
  ) async {
    final body = await _send('POST', '/api/recognition/describe', idToken, {
      'crops': [
        for (final MapEntry(key: id, value: (species, pixels)) in crops.entries)
          {'id': id, 'kind': species, 'pixels': base64Encode(pixels)},
      ],
    });
    final results = body['results'];
    return {
      if (results is List)
        for (final r in results)
          if (r is Map && r['id'] is String)
            r['id'] as String: [
              if (r['labels'] case final List labels)
                for (final l in labels)
                  if (l is Map &&
                      l['label'] is String &&
                      (l['label'] as String).trim().isNotEmpty &&
                      l['type'] is String &&
                      l['confidence'] is num)
                    CloudPetLabel(
                      (l['label'] as String).trim(),
                      l['type'] as String,
                      (l['confidence'] as num).toDouble().clamp(0, 1),
                    ),
            ],
    };
  }
}

/// Asks the recognition API who the people and pets on a new clip are, for
/// [SubjectRecognizer]: only for a premium profile whose model has been
/// trained ([RecognitionConfig.cloudTrainedAt]).
class CloudIdentifier {
  CloudIdentifier({
    required this.auth,
    required this.roles,
    required this.config,
    required this.client,
  });

  final AuthService auth;
  final RolesService roles;
  final ConfigController config;
  final CloudRecognitionClient client;

  /// Whether a clip's crops are worth sending.
  bool get available =>
      roles.isPremium &&
      auth.idToken != null &&
      config.recognition.cloudTrainedAt != null;

  /// Each crop's matches, by its ID; null if it couldn't ask (logged).
  Future<Map<String, List<CloudMatch>>?> identify(
    Map<String, (String kind, Uint8List pixels)> crops,
  ) async {
    final token = auth.idToken;
    if (!available || token == null || crops.isEmpty) return null;
    try {
      final (_, matches) = await client.identify(token, crops);
      return matches;
    } catch (e) {
      debugPrint('Presence: cloud recognition failed: $e');
      return null;
    }
  }
}

/// Asks the recognition API for the breeds and coats of the cats and dogs
/// on a new clip, for [SubjectRecognizer]: for a premium profile, trained
/// or not. The answers become the clip's object tags.
class CloudDescriber {
  CloudDescriber({
    required this.auth,
    required this.roles,
    required this.client,
  });

  final AuthService auth;
  final RolesService roles;
  final CloudRecognitionClient client;

  /// Whether a clip's pets are worth sending.
  bool get available => roles.isPremium && auth.idToken != null;

  /// Each crop's labels, by its ID; null if it couldn't ask (logged).
  Future<Map<String, List<CloudPetLabel>>?> describe(
    Map<String, (String species, Uint8List pixels)> crops,
  ) async {
    final token = auth.idToken;
    if (!available || token == null || crops.isEmpty) return null;
    try {
      return await client.describe(token, crops);
    } catch (e) {
      debugPrint('Presence: cloud breeds and coats failed: $e');
      return null;
    }
  }
}

/// What a training check did.
enum TrainingOutcome {
  /// Not premium, or not signed in: nothing asked.
  notPremium,

  /// Too soon since the last check (every [CloudTrainer.every]).
  notDue,

  /// Nothing to learn yet (no labels with frames).
  noLabels,

  /// Checked: not enough new labels, and not long enough since the last
  /// training.
  upToDate,

  /// Trained.
  trained,

  /// The API or the crops failed; tried again after
  /// [CloudTrainer.retryAfter].
  failed,
}

/// Keeps a premium profile's cloud recognition model trained. At start (once
/// the profile is known to be premium) and every [every], it checks: the
/// labels people placed ([TagSource.vouched], with a frame) against the
/// training API's. It trains when [minNewLabels] are new since the last
/// training (`labeledAt` after it), when it was never trained and there are
/// [minFirstLabels], or when [maxAge] has passed since it was. Training
/// sends the crops the API doesn't have yet ([crop] makes them, with
/// [maxBatch] per request), then the profile's labels now, and keeps when
/// it trained in the settings ([RecognitionConfig.cloudTrainedAt]).
class CloudTrainer {
  CloudTrainer({
    required this.auth,
    required this.roles,
    required this.log,
    required this.config,
    required this.client,
    required this.crop,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AuthService auth;
  final RolesService roles;
  final EventLog log;
  final ConfigController config;
  final CloudRecognitionClient client;

  /// The crop of the person or pet a label points at on its frame, and its
  /// sort; null if nobody's there (or the frame can't be opened yet).
  final Future<(String kind, Uint8List pixels)?> Function(
    ClipRequested clip,
    Annotation label,
  )
  crop;
  final int Function() _now;

  static const Duration every = Duration(hours: 24);
  static const Duration retryAfter = Duration(minutes: 15);
  static const Duration maxAge = Duration(days: 7);
  static const int minNewLabels = 5;
  static const int minFirstLabels = 3;
  static const int maxBatch = CloudRecognitionClient.maxBatch;

  /// How often the timer looks whether a check is due.
  static const Duration tick = Duration(minutes: 15);

  Timer? _timer;
  bool _wasPremium = false;
  Future<TrainingOutcome>? _running;
  int _retryAt = 0;

  /// Checks now if due, and whenever it's due from then on; and at once
  /// when the profile becomes premium (sign-in, or the roles answering
  /// after the app starts).
  void start() {
    roles.addListener(_onRoles);
    _timer = Timer.periodic(tick, (_) => check().ignore());
    _onRoles();
  }

  void _onRoles() {
    final premium = roles.isPremium;
    if (premium && !_wasPremium) {
      // The app started (or signed in) premium: check now, whenever the
      // last check was.
      check(force: true).ignore();
    }
    _wasPremium = premium;
  }

  /// Checks whether to train, and trains if so. Due every [every] since
  /// the last check, or now if [force]. One at a time.
  Future<TrainingOutcome> check({bool force = false}) =>
      _running ??= _check(force: force).whenComplete(() => _running = null);

  /// Trains now whatever's new (Settings' Train now): [check] with every
  /// threshold at its least.
  Future<TrainingOutcome> trainNow() => _running ??= _check(
    force: true,
    always: true,
  ).whenComplete(() => _running = null);

  Future<TrainingOutcome> _check({
    required bool force,
    bool always = false,
  }) async {
    final token = auth.idToken;
    if (!roles.isPremium || token == null) return TrainingOutcome.notPremium;
    final now = _now();
    final settings = config.recognition;
    final checked = settings.cloudCheckedAt ?? 0;
    if (!force && (now - checked < every.inMilliseconds || now < _retryAt)) {
      return TrainingOutcome.notDue;
    }
    try {
      final outcome = await _train(token, now, always: always);
      _retryAt = 0;
      config.update(
        (c) => c.copyWith(
          recognition: c.recognition.copyWith(cloudCheckedAt: now),
        ),
      );
      return outcome;
    } catch (e, stack) {
      debugPrint('Presence: cloud training check failed: $e\n$stack');
      _retryAt = now + retryAfter.inMilliseconds;
      return TrainingOutcome.failed;
    }
  }

  /// The labels people placed, with frames, newest first: the clip and
  /// the label, by label ID.
  Map<String, (ClipRequested, Annotation)> placedLabels() {
    final clips = log.events.whereType<ClipRequested>().toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return {
      for (final clip in clips)
        for (final tag in clip.annotations.items)
          if (tag.source.vouched &&
              tag.frameId != null &&
              Subject.idOf(tag.name).isNotEmpty)
            tag.id: (clip, tag),
    };
  }

  Future<TrainingOutcome> _train(
    String token,
    int now, {
    required bool always,
  }) async {
    final labels = placedLabels();
    final status = await client.status(token);
    final trainedAt = status.trainedAt;
    if (trainedAt != null) _keepTrainedAt(trainedAt);
    if (labels.isEmpty && status.labels.isEmpty) {
      return TrainingOutcome.noLabels;
    }
    // New since the last training, or not held by the API at all (a
    // training that couldn't send them, e.g. from a device without the
    // models to crop them).
    final fresh = labels.entries
        .where(
          (e) =>
              e.value.$2.labeledTime > (trainedAt ?? 0) ||
              !status.labels.containsKey(e.key),
        )
        .length;
    final due = always
        ? labels.isNotEmpty || status.labels.isNotEmpty
        // Never trained, or trained holding no label (as good as never).
        : trainedAt == null || status.labels.isEmpty
        ? labels.length >= minFirstLabels
        : fresh >= minNewLabels || now - trainedAt >= maxAge.inMilliseconds;
    if (!due) return TrainingOutcome.upToDate;

    // The crops the API doesn't have, newest first.
    final names = <String, String>{};
    final missing = <CloudLabel>[];
    for (final MapEntry(key: id, value: (clip, tag)) in labels.entries) {
      if (status.labels.containsKey(id)) {
        names[id] = tag.name.trim();
        continue;
      }
      final found = await crop(clip, tag);
      if (found == null) continue;
      final (kind, pixels) = found;
      missing.add(
        CloudLabel(
          id: id,
          clipId: clip.id,
          name: tag.name.trim(),
          kind: kind,
          labeledAt: tag.labeledTime,
          pixels: pixels,
        ),
      );
      names[id] = tag.name.trim();
    }
    // Nothing could be sent (no crops, and none held): training would
    // replace the model with an empty one.
    if (names.isEmpty) return TrainingOutcome.noLabels;
    for (var i = 0; i < missing.length; i += maxBatch) {
      await client.upload(
        token,
        missing.sublist(i, (i + maxBatch).clamp(0, missing.length)),
      );
    }
    final trained = await client.train(token, names, {
      for (final e in log.events)
        if (e is ClipRequested) e.id,
    });
    _keepTrainedAt(trained);
    debugPrint(
      'Presence: cloud recognition trained on ${names.length} label(s), '
      '${missing.length} new',
    );
    return TrainingOutcome.trained;
  }

  void _keepTrainedAt(int trainedAt) {
    if (config.recognition.cloudTrainedAt == trainedAt) return;
    config.update(
      (c) => c.copyWith(
        recognition: c.recognition.copyWith(cloudTrainedAt: trainedAt),
      ),
    );
  }

  void dispose() {
    _timer?.cancel();
    roles.removeListener(_onRoles);
  }
}

/// Puts the app's [CloudTrainer] within reach of Settings.
class CloudTrainerScope extends InheritedWidget {
  const CloudTrainerScope({
    super.key,
    required this.trainer,
    required super.child,
  });

  final CloudTrainer trainer;

  static CloudTrainer? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CloudTrainerScope>()?.trainer;

  @override
  bool updateShouldNotify(CloudTrainerScope oldWidget) =>
      trainer != oldWidget.trainer;
}

/// Settings' cloud recognition line, for a premium profile: when its model
/// was last trained, and **Train now**. Nothing otherwise.
class CloudRecognitionTile extends StatefulWidget {
  const CloudRecognitionTile({super.key});

  @override
  State<CloudRecognitionTile> createState() => _CloudRecognitionTileState();
}

class _CloudRecognitionTileState extends State<CloudRecognitionTile> {
  bool _training = false;
  TrainingOutcome? _result;

  static String _say(TrainingOutcome outcome, AppLocalizations l) =>
      switch (outcome) {
        TrainingOutcome.trained => l.settingsCloudTrained,
        TrainingOutcome.noLabels => l.settingsCloudNoLabels,
        TrainingOutcome.failed => l.settingsCloudFailed,
        TrainingOutcome.notPremium => l.settingsCloudNotPremium,
        TrainingOutcome.upToDate ||
        TrainingOutcome.notDue => l.settingsCloudUpToDate,
      };

  Future<void> _train(CloudTrainer trainer) async {
    setState(() {
      _training = true;
      _result = null;
    });
    final outcome = await trainer.trainNow();
    if (!mounted) return;
    setState(() {
      _training = false;
      _result = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final trainer = CloudTrainerScope.maybeOf(context);
    if (trainer == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([trainer.roles, trainer.config]),
      builder: (context, _) {
        if (!trainer.roles.isPremium) return const SizedBox.shrink();
        final l = context.l10n;
        final at = trainer.config.recognition.cloudTrainedAt;
        final when = at == null
            ? l.settingsCloudNotTrained
            : l.settingsCloudLastTrained(
                formatEventTime(DateTime.fromMillisecondsSinceEpoch(at)),
              );
        final result = _result;
        return ListTile(
          key: const Key('cloud-recognition-tile'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_outlined),
          title: Text(l.settingsCloudTitle),
          subtitle: Text(
            '${l.settingsCloudStatus(when)}'
            '${result == null ? '' : '\n${_say(result, l)}'}',
            key: const Key('cloud-recognition-status'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: _training
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  key: const Key('cloud-recognition-train'),
                  onPressed: () => _train(trainer),
                  child: Text(l.settingsCloudTrain),
                ),
        );
      },
    );
  }
}
