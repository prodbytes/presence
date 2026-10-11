import AVFoundation
import Flutter
import UIKit
import VideoToolbox
import XCTest

@testable import Runner

/// `SampleRing` writing clips from real H.264 (VideoToolbox) and PCM samples,
/// as the camera's encoder and microphone deliver them.
class SampleRingTests: XCTestCase {

  /// 30 fps of H.264, a keyframe a second, from [from] for [seconds].
  private func video(from: Double, seconds: Double) throws -> [SampleRing.Sample] {
    var session: VTCompressionSession?
    XCTAssertEqual(
      VTCompressionSessionCreate(
        allocator: nil, width: 320, height: 240, codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session), noErr)
    let encoder = try XCTUnwrap(session)
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
    let lock = NSLock()
    var out: [SampleRing.Sample] = []
    for i in 0..<Int(seconds * 30) {
      var pixels: CVPixelBuffer?
      CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixels)
      let buffer = try XCTUnwrap(pixels)
      CVPixelBufferLockBaseAddress(buffer, [])
      memset(CVPixelBufferGetBaseAddress(buffer), Int32(i % 255), CVPixelBufferGetDataSize(buffer))
      CVPixelBufferUnlockBaseAddress(buffer, [])
      let pts = CMTime(seconds: from + Double(i) / 30, preferredTimescale: 600)
      VTCompressionSessionEncodeFrame(
        encoder, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
        frameProperties: nil, infoFlagsOut: nil
      ) { status, _, sample in
        guard status == noErr, let sample else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
          as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        lock.lock()
        out.append(.init(
          track: .video, buffer: sample,
          pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), isKeyframe: !notSync))
        lock.unlock()
      }
    }
    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(encoder)
    return out.sorted { $0.pts < $1.pts }
  }

  /// 44.1 kHz mono 16-bit PCM, 1024 frames a buffer, from [from] for [seconds].
  private func audio(from: Double, seconds: Double) throws -> [SampleRing.Sample] {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
      mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    let description = try XCTUnwrap(format)
    var out: [SampleRing.Sample] = []
    let frames = 1024
    for i in 0..<Int(seconds * 44_100) / frames {
      var block: CMBlockBuffer?
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: frames * 2,
        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
      let data = try XCTUnwrap(block)
      CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: frames * 2)
      let start = from + Double(i * frames) / 44_100
      var sample: CMSampleBuffer?
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: data, formatDescription: description, sampleCount: frames,
        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 44_100),
        packetDescriptions: nil, sampleBufferOut: &sample)
      out.append(.init(track: .audio, buffer: try XCTUnwrap(sample), pts: start, isKeyframe: true))
    }
    return out
  }

  private func url(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ring-test-\(name).mp4")
  }

  /// Writes on another thread, failing (instead of hanging the test) if it
  /// doesn't return within [limit].
  private func write(_ ring: SampleRing, from: Double, to: Double, name: String, limit: TimeInterval = 60)
    -> SampleRing.Written?
  {
    let done = expectation(description: "written")
    var written: SampleRing.Written?
    DispatchQueue.global().async {
      written = ring.write(from: from, to: to, url: self.url(name))
      done.fulfill()
    }
    wait(for: [done], timeout: limit)
    return written
  }

  private func tracks(_ written: SampleRing.Written) async throws -> (video: Int, audio: Int, seconds: Double) {
    let asset = AVURLAsset(url: written.url)
    let video = try await asset.loadTracks(withMediaType: .video).count
    let audio = try await asset.loadTracks(withMediaType: .audio).count
    let duration = try await asset.load(.duration)
    return (video, audio, CMTimeGetSeconds(duration))
  }

  /// The order that hung: the microphone's audio well ahead of the encoded
  /// video in the ring (here, all of it first). The writer interleaves the
  /// tracks, so feeding one list in that order waited on the video input
  /// forever, and the clip never finished.
  func testAudioAheadOfVideoStillWrites() async throws {
    let ring = SampleRing()
    ring.retainSeconds = 60
    let audio = try audio(from: 100, seconds: 15)
    let video = try video(from: 100, seconds: 15)
    for sample in audio + video { ring.append(sample) }
    let written = try XCTUnwrap(write(ring, from: 100, to: 115, name: "audio-first"))
    let (videoTracks, audioTracks, seconds) = try await tracks(written)
    XCTAssertEqual(videoTracks, 1)
    XCTAssertEqual(audioTracks, 1)
    XCTAssertEqual(seconds, 15, accuracy: 0.5)
  }

  /// As the camera delivers them: interleaved, the video a little late.
  func testInterleavedWrites() async throws {
    let ring = SampleRing()
    ring.retainSeconds = 60
    let samples = (try audio(from: 200, seconds: 15).map { ($0.pts, $0) }
      + (try video(from: 200, seconds: 15)).map { ($0.pts + 0.1, $0) })
      .sorted { $0.0 < $1.0 }.map { $0.1 }
    for sample in samples { ring.append(sample) }
    let written = try XCTUnwrap(write(ring, from: 205, to: 215, name: "interleaved"))
    let (videoTracks, audioTracks, seconds) = try await tracks(written)
    XCTAssertEqual(videoTracks, 1)
    XCTAssertEqual(audioTracks, 1)
    // From the keyframe at or before the window's start.
    XCTAssertGreaterThanOrEqual(seconds, 10)
    XCTAssertLessThanOrEqual(written.startMs, 1000)
  }

  /// Video only (no microphone).
  func testVideoOnlyWrites() async throws {
    let ring = SampleRing()
    for sample in try video(from: 300, seconds: 5) { ring.append(sample) }
    let written = try XCTUnwrap(write(ring, from: 301, to: 304, name: "video-only"))
    let (videoTracks, audioTracks, _) = try await tracks(written)
    XCTAssertEqual(videoTracks, 1)
    XCTAssertEqual(audioTracks, 0)
  }
}
