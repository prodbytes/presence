import 'runtime.dart';
import 'vision.dart';

/// The models with [runtime] (TensorFlow.js), on the page's own thread.
Future<Vision> loadPlatformVision(TfliteRuntime runtime) =>
    VisionModels.load(runtime);
