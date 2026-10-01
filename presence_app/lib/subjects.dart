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

  /// This subject's color: its dots on the map and on its frames.
  Color get color => colorOf(id);

  static String idOf(String name) => name.trim().toLowerCase();

  /// The subjects' colors (Gruvbox's accents).
  static const List<Color> colors = [
    Gruvbox.red,
    Gruvbox.blue,
    Gruvbox.green,
    Gruvbox.yellow,
    Gruvbox.purple,
    Gruvbox.aqua,
    Gruvbox.orange,
  ];

  /// The color for the subject [id]: always the same one for a name, on
  /// every screen and launch and on web and native alike (so not
  /// [String.hashCode]). Past seven subjects, colors repeat.
  static Color colorOf(String id) {
    var hash = 0;
    for (final unit in id.codeUnits) {
      hash = (hash * 31 + unit) % 1000003;
    }
    return colors[hash % colors.length];
  }
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

/// A map merging every subject's latest events, each subject in its own
/// color (on the Monitoring tab). Tapping a dot opens its event.
class SubjectsMap extends StatelessWidget {
  const SubjectsMap({
    super.key,
    required this.log,
    required this.config,
    this.tiles,
    this.onOpenEvent,
  });

  final EventLog log;
  final ConfigController config;

  /// Opens an event (a dot tapped on the map).
  final ValueChanged<AppEvent>? onOpenEvent;

  /// The map's tiles; defaults to OpenStreetMap.
  final Widget? tiles;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: config,
    builder: (context, _) => _SubjectsBuilder(
      log: log,
      builder: (context, subjects) {
        final limit = config.subjects.mapEvents;
        return _SightingsMap(
          key: const Key('subjects-map'),
          dots: [
            for (final subject in subjects)
              ..._dotsOf(
                subject,
                limit,
                key: (s) => 'subjects-dot-${subject.id}-${s.event.id}',
              ),
          ],
          tiles: tiles,
          onOpen: onOpenEvent,
        );
      },
    ),
  );
}

/// Everyone tagged on clips, one card per subject, each with a square of
/// their color and the frame from the latest event they're on, the most
/// recently seen first, down a column. Tapping one opens its
/// [SubjectScreen].
class SubjectList extends StatelessWidget {
  const SubjectList({
    super.key,
    required this.log,
    required this.config,
    this.tiles,
    this.onOpenEvent,
  });

  final EventLog log;
  final ConfigController config;
  final ValueChanged<AppEvent>? onOpenEvent;
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
                onOpenEvent: onOpenEvent,
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// A dot on a map: where the device was for one of a subject's events, in
/// the subject's color, faded by age.
typedef _MapPoint = ({
  Sighting sighting,
  Color color,
  double opacity,
  String key,
});

/// The dots for [subject]'s latest [limit] events that have a location,
/// the newest solid and older ones fading ([SubjectScreen.opacityOf]).
List<_MapPoint> _dotsOf(
  Subject subject,
  int limit, {
  required String Function(Sighting s) key,
}) {
  final located = [
    for (final s in subject.sightings.take(limit))
      if (s.event.location != null) s,
  ];
  return [
    for (var i = 0; i < located.length; i++)
      (
        sighting: located[i],
        color: subject.color,
        opacity: SubjectScreen.opacityOf(i, located.length),
        key: key(located[i]),
      ),
  ];
}

/// The square of a subject's color, matching its dots on the maps.
class SubjectSwatch extends StatelessWidget {
  const SubjectSwatch({super.key, required this.color, this.size = 14});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: Colors.white, width: 1.5),
    ),
  );
}

class _SubjectRow extends StatelessWidget {
  const _SubjectRow({required this.subject, required this.onTap});

  /// Narrower than this, the frame goes above the text instead of beside.
  static const double stackBelow = 260;

  final Subject subject;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final latest = subject.latest;
    final count = subject.sightings.length;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          spacing: 8,
          children: [
            SubjectSwatch(
              key: Key('subject-color-${subject.id}'),
              color: subject.color,
            ),
            Flexible(
              child: Text(
                subject.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        Text(
          'Last seen ${formatSeen(latest.time)} · '
          '${latest.event.clip.cameraLabel}',
          style: quiet,
        ),
        Text(count == 1 ? '1 event' : '$count events', style: quiet),
      ],
    );
    return Card.filled(
      key: Key('subject-${subject.id}'),
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth < stackBelow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    SightingFrame(
                      sighting: latest,
                      color: subject.color,
                      width: box.maxWidth,
                    ),
                    text,
                  ],
                );
              }
              return Row(
                spacing: 12,
                children: [
                  SightingFrame(
                    sighting: latest,
                    color: subject.color,
                    width: 96,
                  ),
                  Expanded(child: text),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The frame a subject was tagged on, with a dot where they were clicked.
/// Without one (a tag from before frames were kept), the clip's thumbnail.
class SightingFrame extends StatelessWidget {
  const SightingFrame({
    super.key,
    required this.sighting,
    required this.color,
    required this.width,
  });

  final Sighting sighting;

  /// The subject's color, for the dot.
  final Color color;
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
                          color: color,
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
    this.onOpenEvent,
  });

  /// Opens a dot's event on the Monitoring tab.
  final ValueChanged<AppEvent>? onOpenEvent;

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
        final color = subject.color;
        return Scaffold(
          key: const Key('subject-page'),
          appBar: AppBar(title: Text(subject.name)),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  flex: 3,
                  child: _SightingsMap(
                    dots: _dotsOf(
                      subject,
                      config.subjects.mapEvents,
                      key: (s) => 'subject-dot-${s.event.id}',
                    ),
                    tiles: tiles,
                    onOpen: onOpenEvent,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: _SightingList(
                    shown: shown,
                    located: located,
                    color: color,
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

/// A map of [dots], opening on all of them (on the whole world without
/// any). Tapping a dot opens its event.
class _SightingsMap extends StatelessWidget {
  const _SightingsMap({super.key, required this.dots, this.tiles, this.onOpen});

  /// Called with a tapped dot's event.
  final ValueChanged<AppEvent>? onOpen;

  /// Each subject's newest first, all with a location.
  final List<_MapPoint> dots;
  final Widget? tiles;

  static LatLng _at(Sighting s) =>
      LatLng(s.event.location!.latitude, s.event.location!.longitude);

  @override
  Widget build(BuildContext context) {
    final points = [for (final d in dots) _at(d.sighting)];
    // Faintest first, so newer dots are drawn on top.
    final order = [for (var i = 0; i < dots.length; i++) i]
      ..sort((a, b) => dots[a].opacity.compareTo(dots[b].opacity));
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
            for (final i in order)
              Marker(
                key: Key(dots[i].key),
                point: points[i],
                width: 18,
                height: 18,
                child: _MapDot(
                  sighting: dots[i].sighting,
                  color: dots[i].color,
                  opacity: dots[i].opacity,
                  onTap: onOpen,
                ),
              ),
          ],
        ),
        const MapAttribution(),
      ],
    );
  }
}

/// A dot on a subject's map: tapping it opens its event.
class _MapDot extends StatelessWidget {
  const _MapDot({
    required this.sighting,
    required this.color,
    required this.opacity,
    this.onTap,
  });

  final Sighting sighting;
  final Color color;
  final double opacity;
  final ValueChanged<AppEvent>? onTap;

  @override
  Widget build(BuildContext context) {
    final event = sighting.event;
    final label = '${formatSeen(event.time)} · ${event.clip.cameraLabel}';
    final open = onTap;
    return Tooltip(
      message: label,
      child: Semantics(
        button: open != null,
        label: open != null ? 'Open event $label' : label,
        child: MouseRegion(
          cursor: open != null ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: open == null ? null : () => open(event),
            child: _Dot(color: color, opacity: opacity),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.opacity, this.size = 18});

  final Color color;
  final double opacity;
  final double size;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: opacity,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
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
    required this.color,
    required this.total,
  });

  final List<Sighting> shown;
  final List<Sighting> located;
  final Color color;
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
            leading: SightingFrame(sighting: s, color: color, width: 64),
            title: Text('${formatSeen(s.time)} · ${s.event.clip.cameraLabel}'),
            subtitle: Text(switch (s.event.location) {
              final at? =>
                '${at.latitude.toStringAsFixed(5)}, '
                    '${at.longitude.toStringAsFixed(5)}',
              null => 'No location',
            }, style: small),
            // The same dot as on the map, to match them up.
            trailing: located.contains(s)
                ? _Dot(
                    color: color,
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
