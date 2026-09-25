import AVFoundation
import CoreImage
import Flutter
import VideoToolbox

/// One camera that is always recording (the iOS counterpart of Android's
/// `RollingCamera`): an `AVCaptureSession` delivers portrait frames, which
/// feed the preview texture, a hardware H.264 encoder and motion sampling;
/// the microphone's audio is kept alongside. Both go into a `SampleRing`,
/// and clips are cut from it.
final class RollingCamera: NSObject, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
{
  let id: String
  let front: Bool
  let ring = SampleRing()
  private(set) var width = 0
  private(set) var height = 0
  private(set) var hasAudio = false

  /// Called with each 64×48 luma frame (about 5 per second).
  var onMotionFrame: ((Data) -> Void)?
  /// Called when a new preview frame is ready.
  var onPreviewFrame: (() -> Void)?

  private let device: AVCaptureDevice
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "presence.camera.session")
  private let videoQueue = DispatchQueue(label: "presence.camera.video")
  private let audioQueue = DispatchQueue(label: "presence.camera.audio")
  private let clipQueue = DispatchQueue(label: "presence.camera.clips")
  private var encoder: VTCompressionSession?
  private let latestLock = NSLock()
  private var latest: CVPixelBuffer?
  private var lastMotion: Double = 0
  private let ciContext = CIContext()

  private var pending: [Int: (press: Double, from: Double, to: Double, pin: Int)] = [:]
  private var nextToken = 0
  private let pendingLock = NSLock()

  static let motionWidth = 64
  static let motionHeight = 48

  init?(id: String, withAudio: Bool) {
    guard let device = AVCaptureDevice(uniqueID: id) else { return nil }
    self.id = id
    self.device = device
    self.front = device.position == .front
    super.init()
    self.hasAudio = withAudio
  }

  /// Host-clock "now", in seconds: the clock capture timestamps use.
  static func now() -> Double {
    CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
  }

  // MARK: - Start / stop

  func start(completion: @escaping (Error?) -> Void) {
    sessionQueue.async {
      do {
        try self.configure()
        self.session.startRunning()
        completion(nil)
      } catch {
        completion(error)
      }
    }
  }

  private func configure() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw CameraError("Can't use this camera") }
    session.addInput(input)

    let video = AVCaptureVideoDataOutput()
    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    video.alwaysDiscardsLateVideoFrames = true
    video.setSampleBufferDelegate(self, queue: videoQueue)
    guard session.canAddOutput(video) else { throw CameraError("Can't capture video") }
    session.addOutput(video)
    if let connection = video.connection(with: .video) {
      // Portrait frames: preview, recordings and thumbnails are all upright
      // without any rotation flag. Recordings aren't mirrored.
      if #available(iOS 17.0, *) {
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
      } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = .portrait
      }
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
      }
    }

    if hasAudio, let mic = AVCaptureDevice.default(for: .audio),
      let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput)
    {
      session.addInput(micInput)
      let audio = AVCaptureAudioDataOutput()
      audio.setSampleBufferDelegate(self, queue: audioQueue)
      if session.canAddOutput(audio) { session.addOutput(audio) } else { hasAudio = false }
    } else {
      hasAudio = false
    }

    // Up to 30 fps, but let auto-exposure slow down to 10 fps in low light
    // (brighter picture), as on Android.
    try device.lockForConfiguration()
    let ranges = device.activeFormat.videoSupportedFrameRateRanges
    if ranges.contains(where: { $0.maxFrameRate >= 30 }) {
      device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
    }
    if ranges.contains(where: { $0.minFrameRate <= 10 }) {
      device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 10)
    }
    device.unlockForConfiguration()

    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    // Rotated to portrait above.
    width = Int(min(dims.width, dims.height))
    height = Int(max(dims.width, dims.height))
    if session.sessionPreset == .hd1280x720 {
      width = 720
      height = 1280
    }
  }

  func close(completion: @escaping () -> Void) {
    onMotionFrame = nil
    onPreviewFrame = nil
    sessionQueue.async {
      self.session.stopRunning()
      self.videoQueue.sync {
        if let encoder = self.encoder {
          VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
          VTCompressionSessionInvalidate(encoder)
        }
        self.encoder = nil
      }
      DispatchQueue.main.async(execute: completion)
    }
  }

  // MARK: - Settings

  func setPreRoll(ms: Int) { ring.retainSeconds = Double(ms) / 1000 }

  /// Exposure compensation in EV, clamped to what the camera supports.
  func setBrightness(ev: Float) {
    sessionQueue.async {
      guard (try? self.device.lockForConfiguration()) != nil else { return }
      let bias = min(max(ev, self.device.minExposureTargetBias), self.device.maxExposureTargetBias)
      self.device.setExposureTargetBias(bias, completionHandler: nil)
      self.device.unlockForConfiguration()
    }
  }

  // MARK: - Clips

  func requestClip(beforeMs: Int, afterMs: Int) -> Int {
    let press = Self.now()
    let from = press - Double(beforeMs) / 1000
    let to = press + Double(afterMs) / 1000
    let pin = ring.pin(from: from - 2)
    pendingLock.lock()
    defer { pendingLock.unlock() }
    let token = nextToken
    nextToken += 1
    pending[token] = (press, from, to, pin)
    return token
  }

  /// Writes the "before" part: the window start to the press.
  func clipPast(token: Int, completion: @escaping (SampleRing.Written?) -> Void) {
    pendingLock.lock()
    let clip = pending[token]
    pendingLock.unlock()
    guard let clip else { return completion(nil) }
    clipQueue.async {
      completion(self.ring.write(from: clip.from, to: clip.press, url: self.clipURL(token, "past")))
    }
  }

  /// Waits for the "after" part, then writes the whole clip.
  func clipFull(token: Int, completion: @escaping (SampleRing.Written?) -> Void) {
    pendingLock.lock()
    let clip = pending[token]
    pendingLock.unlock()
    guard let clip else { return completion(nil) }
    DispatchQueue.global(qos: .utility).async {
      self.ring.awaitVideo(until: clip.to, timeout: max(0, clip.to - Self.now()) + 5)
      let written = self.ring.write(from: clip.from, to: clip.to, url: self.clipURL(token, "full"))
      self.ring.unpin(clip.pin)
      self.pendingLock.lock()
      self.pending.removeValue(forKey: token)
      self.pendingLock.unlock()
      completion(written)
    }
  }

  private func clipURL(_ token: Int, _ part: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("clips", isDirectory: true)
      .appendingPathComponent("clip-\(id.hashValue)-\(token)-\(part).mp4")
  }

  /// The latest frame as a JPEG, at most 480 px wide.
  func captureFrame() -> Data? {
    latestLock.lock()
    let buffer = latest
    latestLock.unlock()
    guard let buffer else { return nil }
    var image = CIImage(cvPixelBuffer: buffer)
    let scale = min(1, 480 / image.extent.width)
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return ciContext.jpegRepresentation(
      of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    latestLock.lock()
    defer { latestLock.unlock() }
    guard let latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  // MARK: - Capture callbacks

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output is AVCaptureAudioDataOutput {
      if let copy = Self.deepCopyAudio(sampleBuffer) {
        ring.append(.init(
          track: .audio, buffer: copy,
          pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(copy)), isKeyframe: true))
      }
      return
    }
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    latestLock.lock()
    latest = pixels
    latestLock.unlock()
    onPreviewFrame?()
    encode(pixels, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

    let now = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    if now - lastMotion >= 0.2, let onMotionFrame {
      lastMotion = now
      onMotionFrame(Self.luma(pixels))
    }
  }

  private func encode(_ pixels: CVPixelBuffer, pts: CMTime) {
    if encoder == nil { encoder = makeEncoder(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)) }
    guard let encoder else { return }
    VTCompressionSessionEncodeFrame(
      encoder, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
      frameProperties: nil, infoFlagsOut: nil
    ) { [weak self] status, _, buffer in
      guard status == noErr, let buffer, let self, CMSampleBufferDataIsReady(buffer) else { return }
      let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
        as? [[CFString: Any]]
      let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
      self.ring.append(.init(
        track: .video, buffer: buffer,
        pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)),
        isKeyframe: !notSync))
    }
  }

  private func makeEncoder(width: Int, height: Int) -> VTCompressionSession? {
    var session: VTCompressionSession?
    VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height),
      codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
      imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard let session else { return nil }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    // No B-frames: samples arrive in presentation order, as the ring expects.
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_500_000 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
    VTCompressionSessionPrepareToEncodeFrames(session)
    return session
  }

  /// Capture buffers come from a small pool; keeping them for the ring's
  /// history would starve it. Audio is copied into our own memory.
  private static func deepCopyAudio(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
    guard let block = CMSampleBufferGetDataBuffer(buffer),
      let format = CMSampleBufferGetFormatDescription(buffer)
    else { return nil }
    var copy: CMBlockBuffer?
    guard CMBlockBufferCreateContiguous(
      allocator: nil, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: CMBlockBufferGetDataLength(block),
      flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &copy) == noErr,
      let copy
    else { return nil }
    var out: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: nil, dataBuffer: copy, formatDescription: format,
      sampleCount: CMSampleBufferGetNumSamples(buffer),
      presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
      packetDescriptions: nil, sampleBufferOut: &out)
    return out
  }

  /// Nearest-neighbour 64×48 luma sample of a BGRA frame.
  private static func luma(_ pixels: CVPixelBuffer) -> Data {
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let w = CVPixelBufferGetWidth(pixels)
    let h = CVPixelBufferGetHeight(pixels)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    var out = Data(count: motionWidth * motionHeight)
    guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self)
    else { return out }
    out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
      for y in 0..<motionHeight {
        let row = base + (y * h / motionHeight) * stride
        for x in 0..<motionWidth {
          let p = row + (x * w / motionWidth) * 4  // BGRA
          let luma = (Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8
          dst[y * motionWidth + x] = UInt8(luma)
        }
      }
    }
    return out
  }
}

struct CameraError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
