import 'dart:typed_data';

/// A WebM recording cut to a clip's window: the bytes, and where the window
/// starts and ends in them.
typedef WebmCut = ({Uint8List bytes, Duration start, Duration end});

/// Cuts a browser recording (`MediaRecorder` WebM) down to the window from
/// [start] to [end] (offsets from the start of the recording), without
/// re-encoding: the new file starts at the last video keyframe at or before
/// [start] and stops after the last frame at [end]. Its timestamps start at
/// zero, and it states its duration, so players show the clip's own length.
///
/// The recording only gets as close to [start] as its keyframes allow
/// (`MediaRecorder` is asked for one every few seconds); the returned
/// [WebmCut.start] is where the window begins in the new file.
///
/// Returns null when the bytes aren't a WebM this understands (block
/// groups, laced headers, no video track): the caller keeps the original.
WebmCut? cutWebm(Uint8List bytes, Duration start, Duration end) {
  try {
    return _cut(bytes, start, end);
  } on _NotWebm {
    return null;
  } on RangeError {
    return null;
  }
}

/// The blocks of a WebM file, in file order (for tests).
List<WebmBlock>? webmBlocks(Uint8List bytes) {
  try {
    return _Parsed(bytes).blocks;
  } on _NotWebm {
    return null;
  } on RangeError {
    return null;
  }
}

/// The duration a WebM file's Info states, if any (for tests).
Duration? webmDuration(Uint8List bytes) {
  try {
    final parsed = _Parsed(bytes);
    final units = parsed.duration;
    return units == null ? null : parsed.toDuration(units.round());
  } on _NotWebm {
    return null;
  }
}

/// One frame (or audio packet) of a WebM file.
class WebmBlock {
  WebmBlock(this.track, this.time, this.keyframe, this._payload);

  final int track;

  /// When it plays, from the start of the file.
  final Duration time;
  final bool keyframe;

  /// The SimpleBlock's bytes after its track number and timecode: the flags
  /// and the frame data.
  final Uint8List _payload;

  /// The SimpleBlock's track number as written (a variable-length integer).
  late final Uint8List _trackBytes;
}

// Element IDs (with their length markers, as written).
const _ebml = 0x1A45DFA3;
const _segment = 0x18538067;
const _seekHead = 0x114D9B74;
const _info = 0x1549A966;
const _tracks = 0x1654AE6B;
const _cluster = 0x1F43B675;
const _cues = 0x1C53BB6B;
const _tags = 0x1254C367;
const _chapters = 0x1043A770;
const _attachments = 0x1941A469;
const _timecodeScale = 0x2AD7B1;
const _duration = 0x4489;
const _trackEntry = 0xAE;
const _trackNumber = 0xD7;
const _trackType = 0x83;
const _timecode = 0xE7;
const _simpleBlock = 0xA3;
const _blockGroup = 0xA0;

/// Segment-level elements: an unknown-size cluster ends at the next one.
const _segmentLevel = {
  _seekHead,
  _info,
  _tracks,
  _cluster,
  _cues,
  _tags,
  _chapters,
  _attachments,
};

class _NotWebm implements Exception {}

WebmCut? _cut(Uint8List bytes, Duration start, Duration end) {
  final parsed = _Parsed(bytes);
  final video = parsed.videoTrack;
  if (video == null || parsed.blocks.isEmpty) throw _NotWebm();
  final blocks = parsed.blocks;

  // Start at the last video keyframe at or before the window, or the first
  // one if the window starts before any.
  WebmBlock? from;
  for (final b in blocks) {
    if (b.track != video || !b.keyframe) continue;
    if (b.time <= start || from == null) from = b;
    if (b.time > start) break;
  }
  if (from == null) throw _NotWebm();
  final origin = from.time;
  final kept = [
    for (final b in blocks)
      if (b.time >= origin && b.time <= end) b,
  ];
  if (kept.isEmpty) throw _NotWebm();
  final last = kept.map((b) => b.time).reduce((a, b) => a > b ? a : b);

  // Written as a list of slices (views into [bytes] where possible), each
  // element's size known before its header is written, then copied once
  // into the new file.
  final segment = _Chunks()
    ..add(parsed.infoWithDuration(parsed.toUnits(last - origin).toDouble()))
    ..add(parsed.tracksElement!);

  // New clusters: one per video keyframe, and before block timecodes (16
  // bits, signed) would overflow.
  var cluster = _Chunks();
  int? clusterTime;
  void flush() {
    final time = clusterTime;
    if (time == null) return;
    final timecode = _element(_timecode, _uint(time));
    segment
      ..add(_header(_cluster, timecode.length + cluster.length))
      ..add(timecode)
      ..addAll(cluster);
    cluster = _Chunks();
  }

  for (final b in kept) {
    final t = parsed.toUnits(b.time - origin);
    final newCluster =
        clusterTime == null ||
        (b.track == video && b.keyframe) ||
        t - clusterTime > 30000;
    if (newCluster) {
      flush();
      clusterTime = t;
    }
    final rel = t - clusterTime;
    cluster
      ..add(_header(_simpleBlock, b._trackBytes.length + 2 + b._payload.length))
      ..add(b._trackBytes)
      ..add(Uint8List.fromList([(rel >> 8) & 0xFF, rel & 0xFF]))
      ..add(b._payload);
  }
  flush();

  final out = _Chunks()
    ..add(parsed.ebmlHeader)
    ..add(_header(_segment, segment.length))
    ..addAll(segment);
  return (bytes: out.toBytes(), start: start - origin, end: end - origin);
}

/// Byte slices to write one after the other, and their total length.
class _Chunks {
  final _parts = <Uint8List>[];
  int length = 0;

  void add(Uint8List bytes) {
    _parts.add(bytes);
    length += bytes.length;
  }

  void addAll(_Chunks other) {
    _parts.addAll(other._parts);
    length += other.length;
  }

  Uint8List toBytes() {
    final out = Uint8List(length);
    var at = 0;
    for (final part in _parts) {
      out.setRange(at, at + part.length, part);
      at += part.length;
    }
    return out;
  }
}

/// The parts of a WebM file the cut needs.
class _Parsed {
  _Parsed(this._bytes) {
    var pos = 0;
    final header = _readElement(pos);
    if (header.id != _ebml || header.unknownSize) throw _NotWebm();
    ebmlHeader = Uint8List.sublistView(_bytes, pos, header.end);
    pos = header.end;
    final segment = _readElement(pos);
    if (segment.id != _segment) throw _NotWebm();
    final segmentEnd = segment.unknownSize ? _bytes.length : segment.end;
    pos = segment.dataStart;
    while (pos < segmentEnd) {
      final e = _readElement(pos);
      final elementEnd = e.unknownSize
          ? _unknownSizeEnd(e.dataStart, segmentEnd)
          : e.end;
      switch (e.id) {
        case _info:
          _readInfo(e.dataStart, elementEnd);
          info = Uint8List.sublistView(_bytes, e.dataStart, elementEnd);
        case _tracks:
          _readTracks(e.dataStart, elementEnd);
          tracksElement = Uint8List.sublistView(_bytes, pos, elementEnd);
        case _cluster:
          _readCluster(e.dataStart, elementEnd);
        default:
        // SeekHead and Cues would point at the old offsets; tags, void
        // and the rest aren't needed to play.
      }
      pos = elementEnd;
    }
    if (info == null || tracksElement == null) throw _NotWebm();
  }

  final Uint8List _bytes;
  late final Uint8List ebmlHeader;
  Uint8List? info;
  Uint8List? tracksElement;
  int scale = 1000000;
  double? duration;
  int? videoTrack;
  final List<WebmBlock> blocks = [];

  int toUnits(Duration d) => (d.inMicroseconds * 1000 / scale).round();
  Duration toDuration(int units) =>
      Duration(microseconds: (units * scale / 1000).round());

  /// Info with its Duration replaced by [units].
  Uint8List infoWithDuration(double units) {
    final children = _Chunks();
    var pos = 0;
    final data = info!;
    while (pos < data.length) {
      final e = _ElementHeader.read(data, pos);
      if (e.id != _duration) {
        children.add(Uint8List.sublistView(data, pos, e.end));
      }
      pos = e.end;
    }
    final d = ByteData(8)..setFloat64(0, units);
    children.add(_element(_duration, d.buffer.asUint8List()));
    return (_Chunks()
          ..add(_header(_info, children.length))
          ..addAll(children))
        .toBytes();
  }

  _ElementHeader _readElement(int pos) => _ElementHeader.read(_bytes, pos);

  /// Where an unknown-size element starting its data at [pos] ends: at the
  /// next segment-level element, or [limit].
  int _unknownSizeEnd(int pos, int limit) {
    while (pos < limit) {
      final e = _readElement(pos);
      if (_segmentLevel.contains(e.id)) return pos;
      if (e.unknownSize) throw _NotWebm();
      pos = e.end;
    }
    return limit;
  }

  void _readInfo(int pos, int end) {
    while (pos < end) {
      final e = _readElement(pos);
      if (e.id == _timecodeScale) scale = _readUint(e.dataStart, e.end);
      if (e.id == _duration) {
        final view = ByteData.sublistView(_bytes, e.dataStart, e.end);
        duration = e.end - e.dataStart == 4
            ? view.getFloat32(0)
            : view.getFloat64(0);
      }
      pos = e.end;
    }
  }

  void _readTracks(int pos, int end) {
    while (pos < end) {
      final entry = _readElement(pos);
      if (entry.id == _trackEntry) {
        int? number;
        int? type;
        var p = entry.dataStart;
        while (p < entry.end) {
          final e = _readElement(p);
          if (e.id == _trackNumber) number = _readUint(e.dataStart, e.end);
          if (e.id == _trackType) type = _readUint(e.dataStart, e.end);
          p = e.end;
        }
        if (type == 1 && videoTrack == null) videoTrack = number;
      }
      pos = entry.end;
    }
  }

  void _readCluster(int pos, int end) {
    int? time;
    while (pos < end) {
      final e = _readElement(pos);
      switch (e.id) {
        case _timecode:
          time = _readUint(e.dataStart, e.end);
        case _simpleBlock:
          if (time == null) throw _NotWebm();
          blocks.add(_readBlock(e.dataStart, e.end, time));
        case _blockGroup:
          throw _NotWebm();
      }
      pos = e.end;
    }
  }

  WebmBlock _readBlock(int pos, int end, int clusterTime) {
    final track = _Vint.read(_bytes, pos);
    final p = pos + track.length;
    final rel = ByteData.sublistView(_bytes, p, p + 2).getInt16(0);
    final flags = _bytes[p + 2];
    return WebmBlock(
      track.value,
      toDuration(clusterTime + rel),
      flags & 0x80 != 0,
      Uint8List.sublistView(_bytes, p + 2, end),
    ).._trackBytes = Uint8List.sublistView(_bytes, pos, pos + track.length);
  }

  int _readUint(int start, int end) {
    var v = 0;
    for (var i = start; i < end; i++) {
      v = (v << 8) | _bytes[i];
    }
    return v;
  }
}

class _ElementHeader {
  _ElementHeader(this.id, this.dataStart, this.size);

  static _ElementHeader read(Uint8List bytes, int pos) {
    final first = bytes[pos];
    final idLength = _vintLength(first);
    if (idLength > 4) throw _NotWebm();
    var id = 0;
    for (var i = 0; i < idLength; i++) {
      id = (id << 8) | bytes[pos + i];
    }
    final size = _Vint.read(bytes, pos + idLength);
    return _ElementHeader(
      id,
      pos + idLength + size.length,
      size.unknown ? null : size.value,
    );
  }

  final int id;
  final int dataStart;

  /// Null for an unknown size (a live recording's segment and clusters).
  final int? size;

  bool get unknownSize => size == null;
  int get end => dataStart + size!;
}

/// A variable-length integer, with its length marker removed.
class _Vint {
  _Vint(this.value, this.length, this.unknown);

  static _Vint read(Uint8List bytes, int pos) {
    final length = _vintLength(bytes[pos]);
    var value = bytes[pos] & (0xFF >> length);
    var allOnes = value == (0xFF >> length);
    for (var i = 1; i < length; i++) {
      value = (value << 8) | bytes[pos + i];
      allOnes = allOnes && bytes[pos + i] == 0xFF;
    }
    return _Vint(value, length, allOnes);
  }

  final int value;
  final int length;
  final bool unknown;
}

int _vintLength(int first) {
  for (var i = 0; i < 8; i++) {
    if (first & (0x80 >> i) != 0) return i + 1;
  }
  throw _NotWebm();
}

/// An element's ID and size ([length] bytes of data follow), the size
/// written in 8 bytes.
Uint8List _header(int id, int length) {
  final idBytes = <int>[];
  for (var v = id; v > 0; v >>= 8) {
    idBytes.insert(0, v & 0xFF);
  }
  return Uint8List.fromList([...idBytes, ..._size(length)]);
}

/// A small element with a known size: its header, then [data].
Uint8List _element(int id, List<int> data) =>
    (_Chunks()
          ..add(_header(id, data.length))
          ..add(data is Uint8List ? data : Uint8List.fromList(data)))
        .toBytes();

/// Sizes stay under 4 GB, so the top 3 of the 7 size bytes are zero (shifts
/// past 32 bits aren't safe on the web, where they wrap).
List<int> _size(int n) => [
  0x01,
  0,
  0,
  0,
  for (var shift = 24; shift >= 0; shift -= 8) (n >> shift) & 0xFF,
];

List<int> _uint(int v) {
  final out = <int>[];
  do {
    out.insert(0, v & 0xFF);
    v >>= 8;
  } while (v > 0);
  return out;
}
