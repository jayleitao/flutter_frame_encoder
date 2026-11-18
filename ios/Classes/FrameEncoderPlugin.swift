import Accelerate
import AVFoundation
import Flutter

public class FrameEncoderPlugin: NSObject, FlutterPlugin {
  private var sessions: [Int: EncoderSession] = [:]
  private var nextId = 1
  private let lock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "io.github.jayleitao/flutter_frame_encoder",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(FrameEncoderPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      guard let width = args["width"] as? Int,
        let height = args["height"] as? Int,
        let fps = args["fps"] as? Int,
        let bitrate = args["bitrate"] as? Int,
        let path = args["outputPath"] as? String
      else { return result(badArgs()) }
      do {
        let session = try EncoderSession(
          width: width, height: height, fps: fps, bitrate: bitrate,
          url: URL(fileURLWithPath: path))
        lock.lock()
        let id = nextId
        nextId += 1
        sessions[id] = session
        lock.unlock()
        result(id)
      } catch {
        result(FlutterError(code: "start", message: "\(error)", details: nil))
      }
    case "addFrame":
      guard let session = session(args),
        let data = args["rgba"] as? FlutterStandardTypedData
      else { return result(badArgs()) }
      let repeatCount = args["repeat"] as? Int ?? 1
      session.queue.async {
        do {
          try session.append(rgba: data.data, repeat: repeatCount)
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "frame", message: "\(error)", details: nil))
          }
        }
      }
    case "finish":
      guard let session = session(args), let id = args["id"] as? Int else {
        return result(badArgs())
      }
      remove(id)
      let audio = (args["audioPath"] as? String).map { URL(fileURLWithPath: $0) }
      session.finish(audioURL: audio) { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case .success(let url): result(url.path)
          case .failure(let error):
            result(FlutterError(code: "finish", message: "\(error)", details: nil))
          }
        }
      }
    case "cancel":
      guard let session = session(args), let id = args["id"] as? Int else {
        return result(nil)
      }
      remove(id)
      session.cancel()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func session(_ args: [String: Any]) -> EncoderSession? {
    guard let id = args["id"] as? Int else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return sessions[id]
  }

  private func remove(_ id: Int) {
    lock.lock()
    sessions.removeValue(forKey: id)
    lock.unlock()
  }

  private func badArgs() -> FlutterError {
    FlutterError(code: "args", message: "missing or invalid arguments", details: nil)
  }
}

enum EncoderError: Error {
  case writer(String)
}

/// One AVAssetWriter writing H.264 from RGBA frames.
final class EncoderSession {
  let queue = DispatchQueue(label: "flutter_frame_encoder.session")
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let width: Int
  private let height: Int
  private let fps: Int32
  private let url: URL
  private var frameIndex: Int64 = 0

  init(width: Int, height: Int, fps: Int, bitrate: Int, url: URL) throws {
    self.width = width
    self.height = height
    self.fps = Int32(fps)
    self.url = url
    try? FileManager.default.removeItem(at: url)
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: bitrate,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoExpectedSourceFrameRateKey: fps,
          AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ],
      ])
    input.expectsMediaDataInRealTime = false
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.canAdd(input) else { throw EncoderError.writer("cannot add video input") }
    writer.add(input)
    guard writer.startWriting() else {
      throw EncoderError.writer(writer.error?.localizedDescription ?? "startWriting failed")
    }
    writer.startSession(atSourceTime: .zero)
  }

  /// Runs on [queue].
  func append(rgba: Data, repeat repeatCount: Int) throws {
    guard let pool = adaptor.pixelBufferPool else {
      throw EncoderError.writer(writer.error?.localizedDescription ?? "no pixel buffer pool")
    }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let pixelBuffer = buffer else { throw EncoderError.writer("no pixel buffer") }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    rgba.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
      var source = vImage_Buffer(
        data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
        height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: width * 4)
      var dest = vImage_Buffer(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
      // RGBA -> BGRA
      let map: [UInt8] = [2, 1, 0, 3]
      vImagePermuteChannels_ARGB8888(&source, &dest, map, vImage_Flags(kvImageNoFlags))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    for _ in 0..<repeatCount {
      while !input.isReadyForMoreMediaData {
        if writer.status == .failed {
          throw EncoderError.writer(writer.error?.localizedDescription ?? "writer failed")
        }
        Thread.sleep(forTimeInterval: 0.002)
      }
      let time = CMTime(value: frameIndex, timescale: fps)
      guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
        throw EncoderError.writer(writer.error?.localizedDescription ?? "append failed")
      }
      frameIndex += 1
    }
  }

  func finish(audioURL: URL?, completion: @escaping (Result<URL, Error>) -> Void) {
    queue.async {
      self.input.markAsFinished()
      self.writer.endSession(atSourceTime: CMTime(value: self.frameIndex, timescale: self.fps))
      self.writer.finishWriting {
        if self.writer.status != .completed {
          completion(.failure(EncoderError.writer(
            self.writer.error?.localizedDescription ?? "finishWriting failed")))
          return
        }
        guard let audioURL = audioURL else { return completion(.success(self.url)) }
        AudioMuxer.mux(video: self.url, audio: audioURL, completion: completion)
      }
    }
  }

  func cancel() {
    queue.async {
      self.writer.cancelWriting()
      try? FileManager.default.removeItem(at: self.url)
    }
  }
}

/// Adds an audio track to a finished video, trimmed to the video's length,
/// without re-encoding either track.
enum AudioMuxer {
  static func mux(video: URL, audio: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    let videoAsset = AVURLAsset(url: video)
    let audioAsset = AVURLAsset(url: audio)
    let composition = AVMutableComposition()
    do {
      guard let videoTrack = videoAsset.tracks(withMediaType: .video).first,
        let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
        let compVideo = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
        let compAudio = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw EncoderError.writer("missing video or audio track") }
      let length = videoAsset.duration
      try compVideo.insertTimeRange(
        CMTimeRange(start: .zero, duration: length), of: videoTrack, at: .zero)
      let audioLength = CMTimeMinimum(length, audioAsset.duration)
      try compAudio.insertTimeRange(
        CMTimeRange(start: .zero, duration: audioLength), of: audioTrack, at: .zero)
    } catch {
      return completion(.failure(error))
    }
    let temp = video.deletingLastPathComponent()
      .appendingPathComponent("flutter_frame_encoder_\(UUID().uuidString).mp4")
    guard let export = AVAssetExportSession(
      asset: composition, presetName: AVAssetExportPresetPassthrough)
    else { return completion(.failure(EncoderError.writer("no export session"))) }
    export.outputURL = temp
    export.outputFileType = .mp4
    export.exportAsynchronously {
      guard export.status == .completed else {
        return completion(.failure(EncoderError.writer(
          export.error?.localizedDescription ?? "export failed")))
      }
      do {
        _ = try FileManager.default.replaceItemAt(video, withItemAt: temp)
        completion(.success(video))
      } catch {
        completion(.failure(error))
      }
    }
  }
}
