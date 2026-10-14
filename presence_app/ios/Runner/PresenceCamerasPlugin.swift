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

  /// The frame of the recording at [path] closest to [ms], upright (the
  /// track's preferred transform applied), at most [maxWidth] px wide, as a
  /// JPEG. For tagging people and pets in a clip.
  static func frame(at path: String, ms: Int, maxWidth: Int) -> Data? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: 0)
    let time = CMTime(value: CMTimeValue(ms), timescale: 1000)
    guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
    return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
  }

  /// The frames of the recording at [path] nearest each of [times] (ms),
  /// for subject recognition: the nearest keyframe (the cheapest frame to
  /// decode), each once, upright, at most [maxWidth] px wide, as raw RGBA
  /// `{ms, width, height, pixels}`. As Android's `keyframesAt`.
  static func keyframes(at path: String, times: [Int], maxWidth: Int) -> [[String: Any]] {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
    generator.appliesPreferredTrackTransform = true
    // Any tolerance: the generator takes the nearest keyframe.
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: 0)
    var seen = Set<Int>()
    var out: [[String: Any]] = []
    for ms in times {
      var actual = CMTime.zero
      // One unreadable frame doesn't lose the others.
      guard
        let image = try? generator.copyCGImage(
          at: CMTime(value: CMTimeValue(ms), timescale: 1000), actualTime: &actual)
      else { continue }
      let at = Int((CMTimeGetSeconds(actual) * 1000).rounded())
      guard seen.insert(at).inserted, let rgba = rgbaOf(image) else { continue }
      out.append([
        "ms": at, "width": image.width, "height": image.height,
        "pixels": FlutterStandardTypedData(bytes: rgba),
      ])
    }
    return out
  }

  /// [image]'s pixels as RGBA bytes, row after row, opaque.
  static func rgbaOf(_ image: CGImage) -> Data? {
    let width = image.width
    let height = image.height
    var data = Data(count: width * height * 4)
    let drawn = data.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    // noneSkipLast leaves the fourth byte undefined: opaque.
    data.withUnsafeMutableBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var i = 3
      while i < bytes.count {
        bytes[i] = 255
        i += 4
      }
    }
    return data
  }

  /// [rgba] ([width] × [height], as [keyframes] gives it) as a JPEG.
  static func jpegOf(width: Int, height: Int, rgba: Data) -> Data? {
    guard width > 0, height > 0, rgba.count == width * height * 4,
      let provider = CGDataProvider(data: rgba as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
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
    case "setTorch":
      result(camera?.setTorch(on: args["on"] as? Bool == true) ?? false)
    case "setScreenLight":
      setScreenLight(args["on"] as? Bool == true)
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
    case "frameAt":
      guard let path = args["path"] as? String else { return result(nil) }
      let ms = int("ms")
      let maxWidth = max(1, int("maxWidth"))
      DispatchQueue.global(qos: .userInitiated).async {
        let jpeg = Self.frame(at: path, ms: ms, maxWidth: maxWidth)
        DispatchQueue.main.async { result(jpeg.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    case "keyframesAt":
      guard let path = args["path"] as? String else { return result([]) }
      let times = (args["ms"] as? [NSNumber] ?? []).map { $0.intValue }
      let maxWidth = max(1, int("maxWidth"))
      DispatchQueue.global(qos: .utility).async {
        let frames = Self.keyframes(at: path, times: times, maxWidth: maxWidth)
        DispatchQueue.main.async { result(frames) }
      }
    case "encodeJpeg":
      guard let pixels = args["pixels"] as? FlutterStandardTypedData else { return result(nil) }
      let width = int("width")
      let height = int("height")
      DispatchQueue.global(qos: .utility).async {
        let jpeg = Self.jpegOf(width: width, height: height, rgba: pixels.data)
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

  /// The screen's brightness before night mode lit it, restored after.
  private var brightnessBeforeLight: CGFloat?

  /// The screen as a light for night mode: full brightness while [on],
  /// then back to what it was.
  private func setScreenLight(_ on: Bool) {
    if on {
      if brightnessBeforeLight == nil { brightnessBeforeLight = UIScreen.main.brightness }
      UIScreen.main.brightness = 1
    } else if let before = brightnessBeforeLight {
      UIScreen.main.brightness = before
      brightnessBeforeLight = nil
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
