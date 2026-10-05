import 'runtime.dart';
import 'vision.dart';
import 'vision_worker.dart';

/// The models in their own worker isolate ([WorkerVision]), which runs
/// LiteRT itself ([runtime] only says it can). Throws if they can't load.
Future<Vision> loadPlatformVision(TfliteRuntime runtime) async {
  final vision = WorkerVision();
  await vision.start();
  return vision;
}
