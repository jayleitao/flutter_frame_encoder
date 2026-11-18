/// Encode frames rendered in Flutter into an H.264 MP4 with the platform's
/// own encoder (AVAssetWriter on iOS, MediaCodec on Android).
///
/// ```dart
/// final encoder = await FrameEncoder.start(
///   width: 1080, height: 1920, fps: 30, outputPath: '/tmp/reel.mp4');
/// for (final frame in frames) {
///   await encoder.addFrame(frame); // RGBA, width * height * 4 bytes
/// }
/// final path = await encoder.finish(audioPath: '/tmp/music.m4a');
/// ```
///
/// Frames are written as they arrive and are never all held in memory.
library frame_encoder;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Thrown when the platform encoder fails or is used in the wrong order.
class FrameEncoderException implements Exception {
  FrameEncoderException(this.code, this.message);

  final String code;
  final String? message;

  @override
  String toString() => 'FrameEncoderException($code): $message';
}

/// One encoding session that writes a single MP4 file.
class FrameEncoder {
  FrameEncoder._(this._id, this.width, this.height, this.fps);

  static const MethodChannel _channel =
      MethodChannel('io.github.jayleitao/frame_encoder');

  final int _id;

  /// Frame width in pixels. Even numbers only (H.264 needs it).
  final int width;

  /// Frame height in pixels. Even numbers only.
  final int height;

  /// Frames per second of the output.
  final int fps;

  int _frames = 0;
  bool _closed = false;

  /// Number of frames written so far.
  int get frameCount => _frames;

  /// Length of the video written so far.
  Duration get duration =>
      Duration(microseconds: (_frames * 1000000 / fps).round());

  /// Starts a session that writes to [outputPath] (an existing file there is
  /// replaced). [bitrate] is in bits per second; the default suits
  /// 1080x1920 social video.
  static Future<FrameEncoder> start({
    required int width,
    required int height,
    required String outputPath,
    int fps = 30,
    int bitrate = 8000000,
  }) async {
    if (width <= 0 || height <= 0 || width.isOdd || height.isOdd) {
      throw ArgumentError('width and height must be positive even numbers');
    }
    if (fps <= 0 || fps > 120) {
      throw ArgumentError.value(fps, 'fps', 'must be between 1 and 120');
    }
    final id = await _invoke<int>('start', {
      'width': width,
      'height': height,
      'fps': fps,
      'bitrate': bitrate,
      'outputPath': outputPath,
    });
    return FrameEncoder._(id!, width, height, fps);
  }

  /// Appends one frame of raw RGBA pixels, row by row with no padding
  /// (`width * height * 4` bytes), shown for 1/[fps] of a second.
  /// [repeat] writes the same frame several times, for stills.
  Future<void> addFrame(Uint8List rgba, {int repeat = 1}) async {
    _checkOpen();
    if (rgba.length != width * height * 4) {
      throw ArgumentError(
          'expected ${width * height * 4} bytes, got ${rgba.length}');
    }
    if (repeat < 1) throw ArgumentError.value(repeat, 'repeat');
    await _invoke<void>('addFrame', {
      'id': _id,
      'rgba': rgba,
      'repeat': repeat,
    });
    _frames += repeat;
  }

  /// Appends a [ui.Image] of exactly [width] x [height], for example from
  /// `RenderRepaintBoundary.toImage` or a `PictureRecorder`.
  Future<void> addImage(ui.Image image, {int repeat = 1}) async {
    if (image.width != width || image.height != height) {
      throw ArgumentError('image is ${image.width}x${image.height}, '
          'encoder is ${width}x$height');
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw FrameEncoderException('image', 'could not read image pixels');
    }
    await addFrame(data.buffer.asUint8List(), repeat: repeat);
  }

  /// Closes the file and returns its path. When [audioPath] is given (AAC in
  /// .m4a or .mp4), its first [duration] is muxed in as the soundtrack.
  Future<String> finish({String? audioPath}) async {
    _checkOpen();
    if (_frames == 0) {
      throw FrameEncoderException('empty', 'no frames were added');
    }
    _closed = true;
    final path = await _invoke<String>('finish', {
      'id': _id,
      'audioPath': audioPath,
    });
    return path!;
  }

  /// Stops the session and deletes the partial file.
  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    await _invoke<void>('cancel', {'id': _id});
  }

  void _checkOpen() {
    if (_closed) {
      throw FrameEncoderException('closed', 'this encoder is finished');
    }
  }

  static Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw FrameEncoderException(e.code, e.message);
    }
  }
}
