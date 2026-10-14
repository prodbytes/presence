import 'dart:typed_data';

/// Tells night from day by the camera's own picture: the mean brightness
/// of its motion frames (64×48 luma, a few a second), averaged over the
/// last [window] of frames.
///
/// It turns night when that mean falls below [darkBelow]: auto-exposure
/// keeps a lit scene near mid-gray, so a picture that stays this dark is
/// one it can't brighten any more. At night the camera is made brighter
/// ([CameraRig]), which lifts the mean, so day comes back only once the
/// mean is well above where the brighter night picture settled (its
/// first full [window] after night began, [nightLevel]): 1.5 times it, at
/// least [lightAbove] and at most [lightCap]. So it doesn't flicker at
/// dusk, nor end because the exposure went up; dawn or a lamp ends it.
///
/// Frames while the scene is lit by the app (a torch or the screen, see
/// [pause]) aren't counted: that light isn't the day's.
class NightDetector {
  NightDetector({
    this.window = 40,
    this.darkBelow = 40,
    this.lightAbove = 110,
    this.lightCap = 200,
  });

  /// How many frames the mean is taken over (some 10 seconds).
  final int window;

  /// Mean luma (0–255) below which it's night.
  final double darkBelow;

  /// Mean luma above which it may be day again (see the class).
  final double lightAbove;

  /// The most the mean must reach to be day again.
  final double lightCap;

  final _means = <double>[];
  double _sum = 0;
  bool _night = false;
  double? _nightLevel;

  /// Where the brighter night picture settled, once known.
  double? get nightLevel => _nightLevel;

  /// The mean above which it's day again; null until [nightLevel] is known
  /// (or by day).
  double? get dayAbove => switch (_nightLevel) {
    final base? => (base * 1.5).clamp(lightAbove, lightCap),
    null => null,
  };

  /// Whether it's night now.
  bool get night => _night;

  /// The mean luma over the window, once it's full; null before.
  double? get level => _means.length < window ? null : _sum / _means.length;

  /// While paused, frames are ignored (the scene is lit by the app).
  bool paused = false;

  /// Adds a frame; returns whether it's night, changed or not.
  bool add(Uint8List luma) {
    if (paused || luma.isEmpty) return _night;
    var total = 0;
    for (final v in luma) {
      total += v;
    }
    final mean = total / luma.length;
    _means.add(mean);
    _sum += mean;
    if (_means.length > window) _sum -= _means.removeAt(0);
    final level = this.level;
    if (level == null) return _night;
    if (!_night) {
      if (level < darkBelow) {
        _night = true;
        // Measured again once the brighter exposure has taken.
        _clear();
      }
    } else if (_nightLevel == null) {
      _nightLevel = level;
    } else if (level > dayAbove!) {
      _night = false;
      _nightLevel = null;
      _clear();
    }
    return _night;
  }

  /// Starts over (another camera): day until its frames say otherwise.
  void reset() {
    _clear();
    _night = false;
    _nightLevel = null;
  }

  void _clear() {
    _means.clear();
    _sum = 0;
  }
}
