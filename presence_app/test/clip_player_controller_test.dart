import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/cameras/clip_player_controller.dart';

void main() {
  group('pictureFraction', () {
    const box = Size(160, 90);

    test('maps a click onto a video that fills the box', () {
      expect(
        ClipPlayerController.pictureFraction(
          const Offset(40, 45),
          box,
          const Size(1280, 720),
        ),
        const Offset(0.25, 0.5),
      );
    });

    test('leaves out the letterbox bars', () {
      // A 4:3 video in a 16:9 box shows 120 px wide, from x = 20.
      const video = Size(640, 480);
      expect(
        ClipPlayerController.pictureFraction(const Offset(20, 0), box, video),
        Offset.zero,
      );
      expect(
        ClipPlayerController.pictureFraction(const Offset(80, 45), box, video),
        const Offset(0.5, 0.5),
      );
      expect(
        ClipPlayerController.pictureFraction(const Offset(10, 45), box, video),
        isNull,
      );
    });

    test('is null before the video has a size', () {
      expect(
        ClipPlayerController.pictureFraction(
          const Offset(1, 1),
          box,
          Size.zero,
        ),
        isNull,
      );
    });
  });

  test('pictureTapped reports clamped fractions', () {
    Offset? got;
    final controller = ClipPlayerController();
    controller.onPictureTap = (f) => got = f;
    controller.pictureTapped(const Offset(1.2, -0.1));
    expect(got, const Offset(1, 0));
  });
}
