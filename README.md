# frame_encoder

Turn frames you draw in Flutter into an MP4 video, on the phone, with the platform's own hardware encoder. No ffmpeg, no server.

- **iOS:** `AVAssetWriter` (H.264), RGBA to BGRA with Accelerate.
- **Android:** `MediaCodec` (H.264) through an input Surface, `MediaMuxer` for the file.
- Optional AAC soundtrack (`.m4a`), trimmed to the video length, muxed without re-encoding.
- Frames are written as they arrive, so a long video never sits in memory.

Made for slideshow-style reels (photos with zoom and pan, captions, maps) drawn with Flutter's `Canvas` or captured with `RepaintBoundary`.

## Use

```dart
import 'package:frame_encoder/frame_encoder.dart';

final encoder = await FrameEncoder.start(
  width: 1080,
  height: 1920,
  fps: 30,
  outputPath: '${dir.path}/reel.mp4',
);

// Raw RGBA bytes (width * height * 4)...
await encoder.addFrame(rgbaBytes);
// ...or a ui.Image, e.g. from RenderRepaintBoundary.toImage().
await encoder.addImage(image);
// A still shown for one second:
await encoder.addImage(titleCard, repeat: 30);

final path = await encoder.finish(audioPath: '${dir.path}/music.m4a');
```

Call `cancel()` to stop and delete the partial file.

## Requirements

| Platform | Minimum |
| --- | --- |
| iOS | 13.0 |
| Android | API 23 (6.0) |

Width and height must be even. Web and desktop are not supported yet.

## Benchmark app

`example/` encodes 30 seconds of 1080x1920 frames at 30 fps and reports the time and file size:

```sh
cd example
flutter create --platforms=ios,android .
flutter run --release
```

## Status

0.1.0 is a first version. Not yet supported: video clips between frames, audio fades, HEVC, web. Issues and pull requests are welcome.

## Licence

MIT, see [LICENSE](LICENSE).
