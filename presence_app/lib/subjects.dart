import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'annotations.dart';
import 'camera_feeds.dart';
import 'clips.dart';
import 'config.dart';
import 'events.dart';
import 'location/map_parts.dart';
import 'theme.dart';

/// One event a subject was tagged in: the clip, the tag and the frame it
/// was clicked on.
@immutable
class Sighting {
  const Sighting({required this.event, required this.tag, this.frame});

  final ClipRequested event;
  final Annotation tag;
  final TagFrame? frame;

  DateTime get time => event.time;
}

/// A person or pet named on clips: everyone tagged with the same name
/// (ignoring case and surrounding spaces) is one subject.
@immutable
class Subject {
  const Subject({required this.id, required this.sightings});

  /// The name in lower case, which identifies the subject.
  final String id;

  /// One per event, newest first; never empty.
  final List<Sighting> sightings;

  Sighting get latest => sightings.first;

  /// As it was written on the latest event.
  String get name => latest.tag.name;

  static String idOf(String name) => name.trim().toLowerCase();
}

/// The subjects tagged in [events], the most recently seen first.
List<Subject> subjectsOf(Iterable<AppEvent> events) {
  final clips = events.whereType<ClipRequested>().toList()
    ..sort((a, b) => b.time.compareTo(a.time));
  final sightings = <String, List<Sighting>>{};
  for (final event in clips) {
    final frames = event.annotations.frames;
    final seen = <String>{};
    for (final tag in event.annotations.items) {
      final id = Subject.idOf(tag.name);
      // Tagged twice in one clip is still one event.
      if (id.isEmpty || !seen.add(id)) continue;
      (sightings[id] ??= []).add(
        Sighting(event: event, tag: tag, frame: frames[tag.frameId]),
      );
    }
  }
  return [
    for (final MapEntry(:key, :value) in sightings.entries)
      Subject(id: key, sightings: value),
  ];
}

/// Rebuilds [builder] with the current subjects whenever an event is added
/// or a clip's tags change.
class _SubjectsBuilder extends StatelessWidget {
  const _SubjectsBuilder({required this.log, required this.builder});

  final EventLog log;
  final Widget Function(BuildContext context, List<Subject> subjects) builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: log,
    builder: (context, _) {
      final events = log.events;
      return ListenableBuilder(
        listenable: Listenable.merge([
          for (final e in events.whereType<ClipRequested>()) e.annotations,
        ]),
        builder: (context, _) => builder(context, subjectsOf(events)),
      );
    },
  );
}

/// The Subjects screen (the Subjects tab): everyone tagged on clips, each
/// with the frame from the latest event they're on. Tapping one opens its
/// [SubjectScreen].
class SubjectsView extends StatelessWidget {
  const SubjectsView({
    super.key,
    required this.log,
    required this.config,
    this.tiles,
  });

  final EventLog log;
  final ConfigController config;

  /// The subject maps' tiles; defaults to OpenStreetMap.
  final Widget? tiles;

  @override
  Widget build(BuildContext context) => _SubjectsBuilder(
    log: log,
    builder: (context, subjects) {
      if (subjects.isEmpty) {
        return const FeedMessage(
          icon: Icons.people_outline,
          message: 'No subjects yet. Tag people and pets on a clip.',
        );
      }
      return ListView.separated(
        key: const Key('subjects-list'),
        padding: const EdgeInsets.all(12),
        itemCount: subjects.length,
        separatorBuilder: (context, i) => const SizedBox(height: 8),
        itemBuilder: (context, i) => _SubjectRow(
          subject: subjects[i],
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SubjectScreen(
                subjectId: subjects[i].id,
                log: log,
                config: config,
                tiles: tiles,
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SubjectRow extends StatelessWidget {
  const _SubjectRow({required this.subject, required this.onTap});

  final Subject subject;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final latest = subject.latest;
    final count = subject.sightings.length;
    return Card.filled(
      key: Key('subject-${subject.id}'),
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            spacing: 12,
            children: [
              SightingFrame(sighting: latest, width: 96),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(subject.name, style: theme.textTheme.titleSmall),
                    Text(
                      'Last seen ${formatSeen(latest.time)} · '
                      '${latest.event.clip.cameraLabel}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      count == 1 ? '1 event' : '$count events',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// The frame a subject was tagged on, with a dot where they were clicked.
/// Without one (a tag from before frames were kept), the clip's thumbnail.
class SightingFrame extends StatelessWidget {
  const SightingFrame({super.key, required this.sighting, required this.width});

  final Sighting sighting;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final frame = sighting.frame;
    final image = frame?.jpeg ?? sighting.event.clip.thumbnail;
    final Widget child;
    if (image == null) {
      child = AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: scheme.surfaceContainerLowest,
          child: Icon(Icons.person, color: scheme.onSurfaceVariant),
        ),
      );
    } else {
      // The image at its own shape, so the dot lands on the clicked spot.
      child = Stack(
        children: [
          Image.memory(
            image,
            key: const Key('subject-frame'),
            width: width,
            gaplessPlayback: true,
          ),
          if (frame != null)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, c) => Stack(
                  children: [
                    Positioned(
                      left: sighting.tag.x * c.maxWidth - 4,
                      top: sighting.tag.y * c.maxHeight - 4,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Gruvbox.red,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(width: width, child: child),
    );
  }
}

/// One subject: a map with a dot where the device was for each of its
/// latest events (the newest solid, older ones fading), and those events
/// listed under it.
class SubjectScreen extends StatelessWidget {
  const SubjectScreen({
    super.key,
    required this.subjectId,
    required this.log,
    required this.config,
    this.tiles,
  });

  /// [Subject.id].
  final String subjectId;
  final EventLog log;

  /// How many events show ([SubjectsConfig.mapEvents]).
  final ConfigController config;
  final Widget? tiles;

  /// The oldest dot's opacity; the newest is fully opaque.
  static const double oldestOpacity = 0.15;

  /// The opacity of the dot at [rank] (0 = newest) of [count].
  static double opacityOf(int rank, int count) =>
      count <= 1 ? 1 : 1 - rank * (1 - oldestOpacity) / (count - 1);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: config,
    builder: (context, _) => _SubjectsBuilder(
      log: log,
      builder: (context, subjects) {
        final subject = subjects.where((s) => s.id == subjectId).firstOrNull;
        if (subject == null) {
          // Every tag was removed while this was open.
          return Scaffold(
            appBar: AppBar(),
            body: const FeedMessage(
              icon: Icons.person_off_outlined,
              message: 'Nobody is tagged with this name any more.',
            ),
          );
        }
        final shown = subject.sightings
            .take(config.subjects.mapEvents)
            .toList();
        final located = [
          for (final s in shown)
            if (s.event.location != null) s,
        ];
        return Scaffold(
          key: const Key('subject-page'),
          appBar: AppBar(title: Text(subject.name)),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  flex: 3,
                  child: _SightingsMap(sightings: located, tiles: tiles),
                ),
                Expanded(
                  flex: 2,
                  child: _SightingList(
                    shown: shown,
                    located: located,
                    total: subject.sightings.length,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _SightingsMap extends StatelessWidget {
  const _SightingsMap({required this.sightings, this.tiles});

  /// Newest first, all with a location.
  final List<Sighting> sightings;
  final Widget? tiles;

  static LatLng _at(Sighting s) =>
      LatLng(s.event.location!.latitude, s.event.location!.longitude);

  @override
  Widget build(BuildContext context) {
    final points = [for (final s in sightings) _at(s)];
    final count = sightings.length;
    return FlutterMap(
      options: MapOptions(
        // Opens on all the dots; on the whole world without any.
        initialCameraFit: points.isEmpty
            ? null
            : CameraFit.coordinates(
                coordinates: points,
                padding: const EdgeInsets.all(48),
                maxZoom: 17,
              ),
        initialCenter: const LatLng(20, 0),
        initialZoom: 2,
        minZoom: 2,
        maxZoom: 19,
        backgroundColor: Gruvbox.bg0,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        tiles ?? openStreetMapTiles(),
        MarkerLayer(
          markers: [
            // Oldest first, so newer dots are drawn on top.
            for (var i = count - 1; i >= 0; i--)
              Marker(
                key: Key('subject-dot-${sightings[i].event.id}'),
                point: points[i],
                width: 18,
                height: 18,
                child: _Dot(opacity: SubjectScreen.opacityOf(i, count)),
              ),
          ],
        ),
        const MapAttribution(),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.opacity, this.size = 18});

  final double opacity;
  final double size;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: opacity,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Gruvbox.red,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
    ),
  );
}

/// The events on the map, newest first; tapping one plays its clip.
class _SightingList extends StatelessWidget {
  const _SightingList({
    required this.shown,
    required this.located,
    required this.total,
  });

  final List<Sighting> shown;
  final List<Sighting> located;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return ListView(
      key: const Key('subject-events'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            shown.length < total
                ? 'Latest ${shown.length} of $total events'
                : (total == 1 ? '1 event' : '$total events'),
            style: small,
          ),
        ),
        for (final s in shown)
          ListTile(
            key: Key('subject-event-${s.event.id}'),
            leading: SightingFrame(sighting: s, width: 64),
            title: Text('${formatSeen(s.time)} · ${s.event.clip.cameraLabel}'),
            subtitle: Text(
              s.event.location == null
                  ? 'No location'
                  : '${s.event.location!.latitude.toStringAsFixed(5)}, '
                        '${s.event.location!.longitude.toStringAsFixed(5)}',
              style: small,
            ),
            // The same dot as on the map, to match them up.
            trailing: located.contains(s)
                ? _Dot(
                    opacity: SubjectScreen.opacityOf(
                      located.indexOf(s),
                      located.length,
                    ),
                    size: 12,
                  )
                : null,
            onTap: s.event.clip.playable
                ? () => showClipPlayer(context, s.event)
                : null,
          ),
      ],
    );
  }
}

/// The time, with the date when it isn't today.
String formatSeen(DateTime t, [DateTime? now]) {
  final today = now ?? DateTime.now();
  if (t.year == today.year && t.month == today.month && t.day == today.day) {
    return formatEventTime(t);
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${formatEventTime(t)}';
}
