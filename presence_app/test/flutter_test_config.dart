import 'dart:async';

import 'package:presence_app/crypto/media_seal.dart';

/// Every test file seals media with a fixed test key, as the app does with
/// its device's key once storage opens.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  MediaSeal.instance = MediaSeal.forTests();
  await testMain();
}
