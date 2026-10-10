import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'seal_files.dart' as files;
import 'seal_format.dart';

export 'seal_format.dart' show SealBroken, SealFormat, SealKeyMissing;

/// The media keys this device knows: its own, which seals everything it
/// records, and its profile's other devices', which open what they
/// recorded. Each is a random AES-256 key, named by its device's ID.
///
/// The own key is made with the device ID (`EventStore.deviceIdentity`).
/// Other devices' come with their settings in the cloud
/// (`devices/<id>/settings.json`) or, for profiles without the bucket,
/// with their events over live sync; they're kept in the settings store
/// (`keys`) so they work offline.
///
/// Listeners hear when a key is added (images that couldn't open try
/// again) and when one is [wanted] (cloud sync looks for it).
class MediaKeys extends ChangeNotifier {
  final _own = Completer<({String id, Uint8List key})>();
  final Map<String, Uint8List> _peers = {};
  final Set<String> _wanted = {};

  /// Saves another device's key when it's learned ([add]).
  void Function(String deviceId, Uint8List key)? onAdded;

  /// This device's ID and key, once known.
  Future<({String id, Uint8List key})> get own => _own.future;

  /// This device's ID, once its key is known; null before.
  String? get ownId => _ownNow?.id;

  /// This device's ID and key once known (null before), without waiting.
  ({String id, Uint8List key})? get ownNow => _ownNow;
  ({String id, Uint8List key})? _ownNow;

  /// This device's key (from `EventStore.deviceIdentity`). Set once.
  void setOwn(String deviceId, Uint8List key) {
    if (_own.isCompleted) return;
    _ownNow = (id: deviceId, key: key);
    _own.complete(_ownNow);
    notifyListeners();
  }

  /// The key of device [deviceId], when known.
  Uint8List? keyOf(String deviceId) =>
      _ownNow?.id == deviceId ? _ownNow!.key : _peers[deviceId];

  /// Other devices' keys, as known.
  Map<String, Uint8List> get peers => UnmodifiableMapView(_peers);

  /// Device IDs whose key was needed and isn't known.
  Set<String> get wanted => UnmodifiableSetView(_wanted);

  /// Restores other devices' keys saved earlier: not saved again.
  void restore(Map<String, Uint8List> keys) {
    var changed = false;
    for (final MapEntry(:key, :value) in keys.entries) {
      if (key == _ownNow?.id || _peers[key] != null) continue;
      _peers[key] = value;
      _wanted.remove(key);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Learns device [deviceId]'s [key]. Returns whether it was new. A
  /// device's key never changes: a different one for a known device is
  /// ignored (logged), and this device's own can't be replaced.
  bool add(String deviceId, Uint8List key) {
    if (key.length != SealFormat.keyLength) return false;
    if (deviceId == _ownNow?.id) return false;
    final known = _peers[deviceId];
    if (known != null) {
      if (!listEquals(known, key)) {
        debugPrint('Presence: ignored a new media key for $deviceId');
      }
      return false;
    }
    _peers[deviceId] = key;
    _wanted.remove(deviceId);
    onAdded?.call(deviceId, key);
    notifyListeners();
    return true;
  }

  /// Device [deviceId]'s key was needed and isn't known: cloud sync looks
  /// for it.
  void want(String deviceId) {
    if (keyOf(deviceId) != null || !_wanted.add(deviceId)) return;
    notifyListeners();
  }

  /// [key] as text (base64), for settings records and messages.
  static String encode(Uint8List key) => base64Encode(key);

  /// A key from its text ([encode]), or null when [value] isn't one.
  static Uint8List? decode(Object? value) {
    if (value is! String || value.length > 64) return null;
    try {
      final key = base64Decode(value);
      return key.length == SealFormat.keyLength ? key : null;
    } catch (_) {
      return null;
    }
  }
}

/// Seals and opens media with the device keys ([MediaKeys]): every image
/// (a clip's thumbnail, a tagged frame) and recording is sealed when it's
/// made, before it's stored or sent, and opened only to be shown, played
/// or searched. See [SealFormat].
///
/// Off the web, big media is sealed and opened on another isolate, so the
/// UI doesn't stall; on the web, the browser's Web Crypto does it.
class MediaSeal {
  MediaSeal(this.keys);

  /// The app's. Tests replace it (see [MediaSeal.forTests]).
  static MediaSeal instance = MediaSeal(MediaKeys());

  /// A seal whose own key is set already: device [deviceId], a fixed key.
  factory MediaSeal.forTests({String deviceId = 'test_device_seal'}) =>
      MediaSeal(
        MediaKeys()..setOwn(deviceId, Uint8List.fromList(List.filled(32, 7))),
      );

  final MediaKeys keys;

  /// Media up to this many bytes is sealed or opened on the calling
  /// isolate (a thumbnail takes well under a millisecond); bigger, on
  /// another.
  static const int _inlineMax = 64 * 1024;

  /// Seals [plain] with this device's key (waiting for it).
  Future<Uint8List> seal(Uint8List plain) async {
    // Known already: taken as is, not waited for (a wait goes through the
    // zone the key was set in).
    final own = keys.ownNow ?? await keys.own;
    if (kIsWeb) return _sealWeb(plain, own.key, own.id);
    if (plain.length <= _inlineMax) {
      return SealFormat.sealSync(plain, own.key, own.id);
    }
    return compute(_sealOff, (plain, own.key, own.id));
  }

  /// Opens [sealed]. Throws [SealKeyMissing] when its device's key isn't
  /// known (and wants it: [MediaKeys.want]), [SealBroken] when it isn't
  /// sealed or doesn't open.
  Future<Uint8List> open(Uint8List sealed) async {
    final key = await _keyFor(sealed);
    if (kIsWeb) return _openWeb(sealed, key);
    if (sealed.length <= _inlineMax) return SealFormat.openSync(sealed, key);
    return compute(_openOff, (sealed, key));
  }

  Future<Uint8List> _keyFor(List<int> sealed) async {
    final keyId = SealFormat.keyIdOf(sealed);
    if (keyId == null) throw const SealBroken('not sealed media');
    // This device's own key may still be loading.
    if (keys.ownId == null) await keys.own;
    final key = keys.keyOf(keyId);
    if (key == null) {
      keys.want(keyId);
      throw SealKeyMissing(keyId);
    }
    return key;
  }

  /// Opened images, by the identity of their sealed bytes: a list or grid
  /// rebuilding doesn't open them again.
  final _opened = LinkedHashMap<Uint8List, Future<Uint8List>>.identity();
  static const int _openedMax = 200;

  /// [open], remembering the last [_openedMax] images opened. A failure
  /// isn't remembered: a key that arrives later opens it.
  Future<Uint8List> openImage(Uint8List sealed) {
    final hit = _opened.remove(sealed);
    if (hit != null) return _opened[sealed] = hit;
    final opening = open(sealed);
    _opened[sealed] = opening;
    if (_opened.length > _openedMax) _opened.remove(_opened.keys.first);
    opening.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_opened[sealed], opening)) _opened.remove(sealed);
      },
    );
    return opening;
  }

  /// Seals the file [from] into the file [to] with this device's key, on
  /// another isolate. Not on the web, which has no files.
  Future<void> sealFile(String from, String to) async {
    final own = keys.ownNow ?? await keys.own;
    await compute(_sealFileOff, (from, to, own.key, own.id));
  }

  /// Opens the sealed file [from] into the file [to], on another isolate.
  /// Throws as [open] does.
  Future<void> openFile(String from, String to) async {
    final key = await _keyFor(await files.readHead(from));
    await compute(_openFileOff, (from, to, key));
  }

  static final AesGcm _webGcm = AesGcm.with256bits();

  static Future<Uint8List> _sealWeb(
    Uint8List plain,
    Uint8List key,
    String keyId,
  ) async {
    final header = SealFormat.newHeader(keyId);
    final secret = SecretKey(key);
    final out = BytesBuilder(copy: false)..add(header.bytes);
    final count = SealFormat.chunkCount(header.chunkSize, plain.length);
    for (var i = 0; i < count; i++) {
      final start = i * header.chunkSize;
      final end = min(start + header.chunkSize, plain.length);
      final box = await _webGcm.encrypt(
        Uint8List.sublistView(plain, start, end),
        secretKey: secret,
        nonce: SealFormat.nonceOf(header, i, last: i == count - 1),
        aad: header.bytes,
      );
      out
        ..add(box.cipherText)
        ..add(box.mac.bytes);
    }
    return out.toBytes();
  }

  static Future<Uint8List> _openWeb(Uint8List sealed, Uint8List key) async {
    final header = SealFormat.parseHeader(sealed);
    if (header == null) throw const SealBroken('not sealed media');
    final length = SealFormat.plainLength(header, sealed.length);
    if (length == null) throw const SealBroken('cut off');
    final secret = SecretKey(key);
    final out = Uint8List(length);
    final count = SealFormat.chunkCount(header.chunkSize, length);
    var at = header.length;
    for (var i = 0; i < count; i++) {
      final offset = i * header.chunkSize;
      final size = min(header.chunkSize, length - offset);
      final split = at + size;
      final List<int> plain;
      try {
        plain = await _webGcm.decrypt(
          SecretBox(
            Uint8List.sublistView(sealed, at, split),
            nonce: SealFormat.nonceOf(header, i, last: i == count - 1),
            mac: Mac(
              Uint8List.sublistView(
                sealed,
                split,
                split + SealFormat.tagLength,
              ),
            ),
          ),
          secretKey: secret,
          aad: header.bytes,
        );
      } on SecretBoxAuthenticationError {
        throw const SealBroken("doesn't open with its key");
      }
      out.setRange(offset, offset + size, plain);
      at = split + SealFormat.tagLength;
    }
    return out;
  }
}

Uint8List _sealOff((Uint8List, Uint8List, String) a) =>
    SealFormat.sealSync(a.$1, a.$2, a.$3);

Uint8List _openOff((Uint8List, Uint8List) a) => SealFormat.openSync(a.$1, a.$2);

void _sealFileOff((String, String, Uint8List, String) a) =>
    files.sealFileSync(a.$1, a.$2, a.$3, a.$4);

void _openFileOff((String, String, Uint8List) a) =>
    files.openFileSync(a.$1, a.$2, a.$3);
