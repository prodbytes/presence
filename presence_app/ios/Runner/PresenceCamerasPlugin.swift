import AVFoundation
import Flutter
import UIKit

/// The `presence/cameras` channel on iOS: the same methods as the Android
/// plugin (see `lib/cameras/native_cameras.dart`), plus the
/// `presence/motion` event stream of `{id, luma}` frames.
final class PresenceCamerasPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let textures: FlutterTextureRegistry
  private var open: [String: (camera: RollingCamera, textureId: Int64)] = [:]
  private var motionSink: FlutterEventSink?

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = PresenceCamerasPlugin(textures: registrar.textures())
    let channel = FlutterMethodChannel(
      name: "presence/cameras", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: channel)
    FlutterEventChannel(name: "presence/motion", binaryMessenger: registrar.messenger())
      .setStreamHandler(plugin)
    // A surveillance screen shouldn't go to sleep.
    UIApplication.shared.isIdleTimerDisabled = true
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    motionSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    motionSink = nil
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["id"] as? String ?? ""
    let camera = open[id]?.camera
    func int(_ key: String) -> Int { (args[key] as? NSNumber)?.intValue ?? 0 }

    switch call.method {
    case "requestPermissions":
      requestPermissions(result)
    case "listCameras":
      result(listCameras())
    case "open":
      openCamera(id: id, preRollMs: int("preRollMs"), result: result)
    case "setPreRoll":
      camera?.setPreRoll(ms: int("preRollMs"))
      result(nil)
    case "setBrightness":
      camera?.setBrightness(ev: (args["ev"] as? NSNumber)?.floatValue ?? 0)
      result(nil)
    case "requestClip":
      result(camera?.requestClip(beforeMs: int("beforeMs"), afterMs: int("afterMs")))
    case "clipPast":
      guard let camera else { return result(nil) }
      camera.clipPast(token: int("token")) { written in
        DispatchQueue.main.async { result(written.map(Self.toMap)) }
      }
    case "clipFull":
      guard let camera else { return result(nil) }
      camera.clipFull(token: int("token")) { written in
        DispatchQueue.main.async { result(written.map(Self.toMap)) }
      }
    case "captureFrame":
      guard let camera else { return result(nil) }
      DispatchQueue.global(qos: .userInitiated).async {
        let jpeg = camera.captureFrame()
        DispatchQueue.main.async { result(jpeg.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    case "close":
      guard let entry = open.removeValue(forKey: id) else { return result(nil) }
      // Reply once the session has stopped, so the next camera can start.
      entry.camera.close {
        self.textures.unregisterTexture(entry.textureId)
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermissions(_ result: @escaping FlutterResult) {
    AVCaptureDevice.requestAccess(for: .video) { camera in
      AVCaptureDevice.requestAccess(for: .audio) { microphone in
        DispatchQueue.main.async { result(["camera": camera, "microphone": microphone]) }
      }
    }
  }

  /// Every camera, back ones first (the first is the default).
  private func listCameras() -> [[String: Any]] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
    return discovery.devices
      .sorted { a, _ in a.position == .back }
      .map { device in
        [
          "id": device.uniqueID,
          "label": device.position == .front ? "Front camera" : "Back camera",
          "front": device.position == .front,
        ]
      }
  }

  private func openCamera(id: String, preRollMs: Int, result: @escaping FlutterResult) {
    if let previous = open.removeValue(forKey: id) {
      previous.camera.close { self.textures.unregisterTexture(previous.textureId) }
    }
    let withAudio = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    guard let camera = RollingCamera(id: id, withAudio: withAudio) else {
      return result(FlutterError(code: "camera", message: "Camera not found", details: nil))
    }
    camera.setPreRoll(ms: preRollMs)
    let textureId = textures.register(camera)
    camera.onPreviewFrame = { [weak self] in self?.textures.textureFrameAvailable(textureId) }
    camera.onMotionFrame = { [weak self] luma in
      DispatchQueue.main.async {
        self?.motionSink?(["id": id, "luma": FlutterStandardTypedData(bytes: luma)])
      }
    }
    camera.start { error in
      DispatchQueue.main.async {
        if let error {
          self.textures.unregisterTexture(textureId)
          return result(
            FlutterError(code: "camera", message: error.localizedDescription, details: nil))
        }
        self.open[id] = (camera, textureId)
        result([
          "textureId": textureId,
          "width": camera.width,
          "height": camera.height,
          // Frames arrive already upright (portrait).
          "sensorOrientation": 0,
          "front": camera.front,
          // iOS delivers unmirrored frames; mirror the front preview only,
          // like a selfie view. Recordings stay unmirrored.
          "mirror": camera.front,
          "audio": camera.hasAudio,
          "motion": true,
        ])
      }
    }
  }

  private static func toMap(_ written: SampleRing.Written) -> [String: Any] {
    [
      "path": written.url.path,
      "startMs": written.startMs,
      "endMs": written.endMs,
      "mimeType": "video/mp4",
    ]
  }
}
