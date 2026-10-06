import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'annotations.dart';
import 'camera_feeds.dart';
import 'clips.dart';
import 'config.dart';
import 'dot.dart';
import 'events.dart';
import 'location/map_parts.dart';
import 'theme.dart';
import 'time_format.dart';

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
    for (final tag in event.annotations.tags) {
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
/// or a clip's tags change. The subjects are worked out again only when
/// [events] gives another list or a clip's tags changed.
class _SubjectsBuilder extends StatefulWidget {
  const _SubjectsBuilder({
    required this.log,
    required this.events,
    required this.builder,
  });

  final EventLog log;
  final Widget Function(BuildContext context, List<Subject> subjects) builder;

  /// The events the subjects are taken from: a list that's kept (such as
  /// [EventLog.eventsOf]) while they're the same.
  final List<AppEvent> Function() events;

  @override
  State<_SubjectsBuilder> createState() => _SubjectsBuilderState();
}

class _SubjectsBuilderState extends State<_SubjectsBuilder> {
  late Listenable _changes = _changesOf(widget.log);

  static Listenable _changesOf(EventLog log) =>
      Listenable.merge([log, log.annotations]);

  List<AppEvent>? _from;
  int _tags = -1;
  List<Subject> _subjects = const [];

  @override
  void didUpdateWidget(_SubjectsBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.log != widget.log) {
      _changes = _changesOf(widget.log);
      _from = null;
    }
  }

  List<Subject> get _current {
    final events = widget.events();
    final tags = widget.log.annotationsVersion;
    if (!identical(events, _from) || tags != _tags) {
      _from = events;
      _tags = tags;
      _subjects = subjectsOf(events);
    }
    return _subjects;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _changes,
    builder: (context, _) => widget.builder(context, _current),
  );
}

/// A map merging every subject's latest events, each subject in its own
/// color (on the Monitoring tab), with the subject's name beside its newest
/// dot. Tapping a dot opens its event; tapping a name opens the subject.
/// Only [profileId]'s events show, and with a device picked
/// ([EventFilters.onlyDevice]) only that device's.
class SubjectsMap extends StatelessWidget {
  const SubjectsMap({
    super.key,
    required this.log,
    required this.config,
    this.tiles,
    this.onOpenEvent,
    this.deviceId,
    this.profileId,
    this.filters,
  });

  final EventLog log;
  final ConfigController config;

  /// This device's ID: events without a device ID (not saved yet) are its.
  final String? deviceId;

  /// The signed-in account's profile (null signed out): only its events
  /// show, as in the timeline ([EventTimeline.ofProfile]).
  final String? profileId;

  /// The timeline's filters: the map follows its device filter
  /// ([EventFilters.onlyDevice]). Every device shows without them.
  final EventFilters? filters;

  /// Opens an event (a dot tapped on the map).
  final ValueChanged<AppEvent>? onOpenEvent;

  /// The map's tiles; defaults to OpenStreetMap.
  final Widget? tiles;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Not the search nor the system events: they don't change the map.
    listenable: Listenable.merge([config, filters?.onlyDevice]),
    builder: (context, _) => _SubjectsBuilder(
      log: log,
      events: () => switch (filters) {
        final filters? =>
          filters
              .viewOf(log, deviceId: deviceId, profileId: profileId)
              .ofDevices,
        null => log.eventsOf(profileId),
      },
      builder: (context, subjects) {
        final limit = config.subjects.mapEvents;
        final dots = <_MapPoint>[];
        final labels = <_MapLabel>[];
        for (final subject in subjects) {
          final mine = _dotsOf(
            subject,
            limit,
            key: (s) => 'subjects-dot-${subject.id}-${s.event.id}',
          );
          dots.addAll(mine);
          if (mine.isNotEmpty) {
            labels.add((
              sighting: mine.first.sighting,
              subject: subject,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SubjectScreen(
                    subjectId: subject.id,
                    log: log,
                    profileId: profileId,
                    config: config,
                    tiles: tiles,
                    onOpenEvent: onOpenEvent,
                  ),
                ),
              ),
            ));
          }
        }
        return _SightingsMap(
          key: const Key('subjects-map'),
          // Fitted again to the dots shown when the device filter changes.
          fitKey: filters?.onlyDevice.value,
          closeUp: true,
          dots: dots,
          labels: labels,
          tiles: tiles,
          onOpen: onOpenEvent,
        );
      },
    ),
  );
}

/// The **Subjects** (named people and pets) tagged on [event], once each,
/// in tag order: a square of each one's color and their name (on the
/// event's card), and an x that removes the subject's tags from the clip.
/// In a timeline ([EventSearchScope]) a click on a name filters the events
/// by it (again, clears the filter), highlighting it while it's the search;
/// a long press opens the player ([onOpenAt]).
class EventSubjects extends StatelessWidget {
  const EventSubjects({super.key, required this.event, this.onOpenAt});

  final ClipRequested event;

  /// Called when a name is clicked (long pressed in a timeline), with the
  /// earliest frame that subject is tagged on (null for tags without a
  /// frame).
  final void Function(Duration? at)? onOpenAt;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: event.annotations,
    builder: (context, _) {
      final theme = Theme.of(context);
      final seen = <String>{};
      final search = EventSearchScope.maybeOf(context);
      // Each subject's earliest tagged frame.
      final firstMs = <String, int>{};
      for (final tag in event.annotations.tags) {
        final id = Subject.idOf(tag.name);
        final ms = tag.frameMs;
        if (ms != null && ms < (firstMs[id] ?? ms + 1)) firstMs[id] = ms;
      }
      final tags = [
        for (final tag in event.annotations.tags)
          if (Subject.idOf(tag.name) case final id
              when id.isNotEmpty && seen.add(id))
            (
              id: id,
              name: tag.name.trim(),
              detected: tag.source == TagSource.detected,
              ms: firstMs[id],
              // Whether it's the search: highlighted.
              active:
                  search != null &&
                  EventSearchScope.isActive(search.value, tag.name),
            ),
      ];
      if (tags.isEmpty) return const SizedBox.shrink();
      final scheme = theme.colorScheme;
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          key: const Key('event-subjects'),
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final t in tags)
              Semantics(
                key: Key('event-subject-chip-${t.id}'),
                selected: search == null ? null : t.active,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.active ? scheme.primaryContainer : null,
                    border: t.active ? Border.all(color: scheme.primary) : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OpenAtLabel(
                        key: Key('event-subject-${t.id}'),
                        ms: t.ms,
                        onOpenAt: onOpenAt,
                        filter: t.name,
                        borderRadius: BorderRadius.circular(4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 6,
                          children: [
                            SubjectSwatch(
                              key: Key('event-subject-color-${t.id}'),
                              color: Subject.colorOf(t.id),
                              size: 12,
                            ),
                            Text(
                              t.name,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: t.active
                                    ? scheme.onPrimaryContainer
                                    : null,
                                fontWeight: t.active ? FontWeight.bold : null,
                              ),
                            ),
                            // Found by recognition, not tagged by someone.
                            if (t.detected)
                              Tooltip(
                                message: 'Recognized automatically',
                                child: Icon(
                                  Icons.auto_awesome,
                                  key: Key('event-subject-detected-${t.id}'),
                                  size: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      RemoveLabelButton(
                        key: Key('event-subject-remove-${t.id}'),
                        label: t.name,
                        kind: 'subject',
                        onRemove: () => event.annotations.removeName(t.name),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// A subject's name on a map, beside its newest dot.
typedef _MapLabel = ({Sighting sighting, Subject subject, VoidCallback onTap});

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
            // Decoded at the size it's shown, not the frame's full size.
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .round(),
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
    this.profileId,
    this.tiles,
    this.onOpenEvent,
  });

  /// The signed-in account's profile: only its events count, as on the
  /// Monitoring tab ([EventTimeline.ofProfile]).
  final String? profileId;

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
      events: () => log.eventsOf(profileId),
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

/// The points that frame [points] around [center]: each one and its mirror
/// image through [center], in the map's (Web Mercator) projection. Fitting
/// the camera to them puts [center] in the middle, zoomed out just enough
/// to show every point. Mirrors past the date line are cut back to it.
List<LatLng> framedAround(LatLng center, List<LatLng> points) {
  const projection = Epsg3857();
  final (cx, cy) = projection.projection.projectXY(center);
  return [
    center,
    for (final p in points) ...[
      p,
      () {
        final (x, y) = projection.projection.projectXY(p);
        final mirror = projection.projection.unprojectXY(
          2 * cx - x,
          2 * cy - y,
        );
        return LatLng(
          mirror.latitude.clamp(-90, 90),
          mirror.longitude.clamp(-180, 180),
        );
      }(),
    ],
  ];
}

/// A map of [dots], opening centered on the newest one and zoomed out to
/// show them all (on the whole world without any), with zoom buttons.
/// With [closeUp], it opens on the newest one at street level instead, and
/// follows the newest as events arrive until the map is moved.
/// Tapping a dot opens its event.
class _SightingsMap extends StatefulWidget {
  const _SightingsMap({
    super.key,
    required this.dots,
    this.labels = const [],
    this.tiles,
    this.onOpen,
    this.fitKey,
    this.closeUp = false,
  });

  /// When it changes, the map fits the dots again, as when it opened.
  final Object? fitKey;

  /// Centered on the newest dot at street level ([closeUpZoom]), showing
  /// only the dots within [nearbyMeters] of it; fitted again when a newer
  /// dot arrives (or the first, once the events load) until the map is
  /// moved by hand.
  final bool closeUp;

  /// Called with a tapped dot's event.
  final ValueChanged<AppEvent>? onOpen;

  /// Each subject's newest first, all with a location.
  final List<_MapPoint> dots;

  /// Names beside dots, drawn over every dot.
  final List<_MapLabel> labels;
  final Widget? tiles;

  /// The widest a name gets before it's cut short.
  static const double labelWidth = 160;

  static const double minZoom = 2;
  static const double maxZoom = 19;

  /// The close-up zoom range: street level ([closeUp]).
  static const double closeUpMinZoom = 16;
  static const double closeUpZoom = 17;

  /// The dots this close to the newest are fitted with it ([closeUp]).
  static const double nearbyMeters = 300;

  static LatLng _at(Sighting s) =>
      LatLng(s.event.location!.latitude, s.event.location!.longitude);

  @override
  State<_SightingsMap> createState() => _SightingsMapState();
}

class _SightingsMapState extends State<_SightingsMap> {
  final _map = MapController();
  bool _ready = false;

  /// Moved by hand (a drag, pinch, wheel or the zoom buttons): a newer dot
  /// no longer refits a [_SightingsMap.closeUp] map.
  bool _moved = false;

  /// The fit the map opens on, worked out once from the first dots:
  /// flutter_map applies it at the first real size it gets, which may come
  /// later (a resize), and a fit of the current dots then would snap back to
  /// the newest after the map was moved. Newer dots are followed through
  /// [didUpdateWidget] (or [_onReady]) instead.
  late final CameraFit? _initialFit;

  /// What [_initialFit] was worked out from, to tell at [_onReady] whether
  /// the dots changed before the map was ready.
  late final Object? _initialFitKey;
  late final String? _initialNewest;

  @override
  void initState() {
    super.initState();
    _initialFit = _fit(widget.dots, closeUp: widget.closeUp);
    _initialFitKey = widget.fitKey;
    _initialNewest = _newest(widget.dots)?.sighting.event.id;
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  /// One step in ([by] 1) or out (-1), around the map's center.
  void _zoom(double by) {
    if (!_ready) return;
    _moved = true;
    final camera = _map.camera;
    _map.move(
      camera.center,
      (camera.zoom + by).clamp(_SightingsMap.minZoom, _SightingsMap.maxZoom),
    );
    setState(() {});
  }

  double get _zoomLevel => _ready ? _map.camera.zoom : _SightingsMap.minZoom;

  @override
  void didUpdateWidget(_SightingsMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    final refilter = oldWidget.fitKey != widget.fitKey;
    final newer =
        widget.closeUp &&
        !_moved &&
        _newest(widget.dots)?.sighting.event.id !=
            _newest(oldWidget.dots)?.sighting.event.id;
    if (refilter || newer) {
      if (refilter) _moved = false;
      _refitAfterBuild();
    }
  }

  /// Fits the current dots, after this build (once the map has them).
  void _refitAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final fit = _fit(widget.dots, closeUp: widget.closeUp);
      if (fit == null) {
        _map.move(const LatLng(20, 0), _SightingsMap.minZoom);
      } else {
        _map.fitCamera(fit);
      }
      setState(() {});
    });
  }

  /// The map is ready: if the dots changed since [_initialFit] was worked
  /// out (events loaded in the meantime), fit them as [didUpdateWidget]
  /// would have.
  void _onReady() {
    setState(() => _ready = true);
    final refilter = widget.fitKey != _initialFitKey;
    final newer =
        widget.closeUp &&
        !_moved &&
        _newest(widget.dots)?.sighting.event.id != _initialNewest;
    if (refilter || newer) _refitAfterBuild();
  }

  /// The newest of [dots]; null without any.
  static _MapPoint? _newest(List<_MapPoint> dots) {
    _MapPoint? newest;
    for (final d in dots) {
      if (newest == null ||
          d.sighting.event.time.isAfter(newest.sighting.event.time)) {
        newest = d;
      }
    }
    return newest;
  }

  /// Centered on the newest dot, out far enough for all of them; null
  /// without any (the whole world). With [closeUp], at street level, out
  /// only as far as the dots within [_SightingsMap.nearbyMeters].
  static CameraFit? _fit(List<_MapPoint> dots, {bool closeUp = false}) {
    final newest = _newest(dots);
    if (newest == null) return null;
    final center = _SightingsMap._at(newest.sighting);
    var points = [for (final d in dots) _SightingsMap._at(d.sighting)];
    if (closeUp) {
      // Haversine: Vincenty fails to converge for nearly antipodal points.
      const distance = DistanceHaversine();
      points = [
        for (final p in points)
          if (distance(center, p) <= _SightingsMap.nearbyMeters) p,
      ];
    }
    return CameraFit.coordinates(
      coordinates: framedAround(center, points),
      padding: const EdgeInsets.all(48),
      minZoom: closeUp ? _SightingsMap.closeUpMinZoom : 0,
      maxZoom: _SightingsMap.closeUpZoom,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dots = widget.dots;
    final points = [for (final d in dots) _SightingsMap._at(d.sighting)];
    // Faintest first, so newer dots are drawn on top.
    final order = [for (var i = 0; i < dots.length; i++) i]
      ..sort((a, b) => dots[a].opacity.compareTo(dots[b].opacity));
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCameraFit: _initialFit,
            initialCenter: const LatLng(20, 0),
            initialZoom: 2,
            minZoom: _SightingsMap.minZoom,
            maxZoom: _SightingsMap.maxZoom,
            backgroundColor: Gruvbox.bg0,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: _onReady,
            // Pinches and wheels change the zoom too: keep the buttons'
            // limits current.
            onPositionChanged: (_, hasGesture) {
              if (hasGesture) setState(() => _moved = true);
            },
          ),
          children: [
            widget.tiles ?? openStreetMapTiles(),
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
                      onTap: widget.onOpen,
                    ),
                  ),
                // To the right of the point, clear of the dot.
                for (final l in widget.labels)
                  Marker(
                    key: Key('subjects-label-${l.subject.id}'),
                    point: _SightingsMap._at(l.sighting),
                    width: _SightingsMap.labelWidth,
                    height: 24,
                    alignment: Alignment.centerRight,
                    child: _MapName(subject: l.subject, onTap: l.onTap),
                  ),
              ],
            ),
            const MapAttribution(),
          ],
        ),
        // For those without pinch or a wheel.
        Positioned(
          right: 12,
          bottom: 12,
          child: MapZoomButtons(
            keyPrefix: 'sightings-',
            onZoomIn: _ready && _zoomLevel < _SightingsMap.maxZoom
                ? () => _zoom(1)
                : null,
            onZoomOut: _ready && _zoomLevel > _SightingsMap.minZoom
                ? () => _zoom(-1)
                : null,
          ),
        ),
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
            child: Dot(
              color: color,
              opacity: opacity,
              size: 18,
              outlined: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// A subject's name on a map, in a pill edged in its color. Tapping it
/// opens the subject.
class _MapName extends StatelessWidget {
  const _MapName({required this.subject, required this.onTap});

  final Subject subject;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Semantics(
          button: true,
          label: 'Open ${subject.name}',
          excludeSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Gruvbox.bg0.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: subject.color, width: 1.5),
                ),
                child: Text(
                  subject.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Gruvbox.fg,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
                ? Dot(
                    outlined: true,
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
  return '${formatDate(t)} ${formatEventTime(t)}';
}
