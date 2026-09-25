import AVFoundation
import CoreMedia

/// The last few seconds of encoded video (H.264) and audio (PCM), kept in
/// memory so a clip can include the moments before it was requested.
///
/// Mirrors the Android `SampleRing`: a clip is written by muxing the stored
/// samples into an MP4, starting at the video keyframe at or before the
/// window start, and the returned offsets tell the player where the window
/// lies inside the file.
///
/// Thread-safe: capture/encoder callbacks append while clips are written.
final class SampleRing {
  enum Track { case video, audio }

  struct Sample {
    let track: Track
    let buffer: CMSampleBuffer
    let pts: Double  // seconds, host clock
    let isKeyframe: Bool
  }

  /// Where a clip's window lies inside the written file.
  struct Written {
    let url: URL
    let startMs: Int
    let endMs: Int
  }

  private let condition = NSCondition()
  private var samples: [Sample] = []
  private var pins: [Int: Double] = [:]
  private var nextPin = 0

  /// How much history to keep, in seconds.
  var retainSeconds: Double = 15

  func append(_ sample: Sample) {
    condition.lock()
    samples.append(sample)
    prune(now: sample.pts)
    condition.broadcast()
    condition.unlock()
  }

  func latestVideoPts() -> Double? {
    condition.lock()
    defer { condition.unlock() }
    return samples.last(where: { $0.track == .video })?.pts
  }

  /// Keeps samples from [from] on until `unpin` is called.
  func pin(from: Double) -> Int {
    condition.lock()
    defer { condition.unlock() }
    let id = nextPin
    nextPin += 1
    pins[id] = from
    return id
  }

  func unpin(_ id: Int) {
    condition.lock()
    pins.removeValue(forKey: id)
    condition.unlock()
  }

  /// Blocks until video up to [pts] has been recorded, or [timeout] passes.
  @discardableResult
  func awaitVideo(until pts: Double, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    condition.lock()
    defer { condition.unlock() }
    while (samples.last(where: { $0.track == .video })?.pts ?? -.infinity) < pts {
      if !condition.wait(until: deadline) { return false }
    }
    return true
  }

  /// Writes [from, to] (seconds, host clock) to an MP4 at [url]. Returns nil
  /// if there's no video in that range yet.
  func write(from: Double, to: Double, url: URL) -> Written? {
    condition.lock()
    let snapshot = samples
    condition.unlock()

    guard
      let keyframe = snapshot.last(where: {
        $0.track == .video && $0.isKeyframe && $0.pts <= from
      }) ?? snapshot.first(where: { $0.track == .video && $0.isKeyframe })
    else { return nil }
    let start = keyframe.pts
    let inRange = snapshot.filter { $0.pts >= start && $0.pts <= to }
    guard let lastVideo = inRange.last(where: { $0.track == .video })?.pts,
      let videoFormat = CMSampleBufferGetFormatDescription(keyframe.buffer)
    else { return nil }
    let audioFormat = inRange.first(where: { $0.track == .audio })
      .flatMap { CMSampleBufferGetFormatDescription($0.buffer) }

    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }

    // Video is already H.264: write it as is.
    let videoInput = AVAssetWriterInput(
      mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    videoInput.expectsMediaDataInRealTime = false
    writer.add(videoInput)

    // Audio is PCM: encode to AAC while writing.
    var audioInput: AVAssetWriterInput?
    if let audioFormat,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
    {
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: asbd.mSampleRate,
          AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
          AVEncoderBitRateKey: 64_000,
        ],
        sourceFormatHint: audioFormat)
      input.expectsMediaDataInRealTime = false
      if writer.canAdd(input) {
        writer.add(input)
        audioInput = input
      }
    }

    guard writer.startWriting() else { return nil }
    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(keyframe.buffer))
    for sample in inRange {
      guard let input = sample.track == .video ? videoInput : audioInput else { continue }
      while !input.isReadyForMoreMediaData && writer.status == .writing {
        usleep(1_000)
      }
      if writer.status != .writing { break }
      input.append(sample.buffer)
    }
    videoInput.markAsFinished()
    audioInput?.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { return nil }

    let end = min(to, lastVideo)
    return Written(
      url: url,
      startMs: Int(max(0, from - start) * 1000),
      endMs: Int(max(0, end - start) * 1000))
  }

  /// Drops history older than [retainSeconds], whole GOPs at a time, and
  /// never anything a clip has pinned. Call with the lock held.
  private func prune(now: Double) {
    let keepFrom = min(now - retainSeconds - 1, pins.values.min() ?? .infinity)
    while true {
      guard
        let next = samples.dropFirst().firstIndex(where: { $0.track == .video && $0.isKeyframe }),
        samples[next].pts <= keepFrom
      else { return }
      samples.removeFirst(next)
    }
  }
}
