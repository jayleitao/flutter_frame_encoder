import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_frame_encoder/flutter_frame_encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.jayleitao/flutter_frame_encoder');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'start':
          return 7;
        case 'finish':
          return '/tmp/out.mp4';
        default:
          return null;
      }
    });
  });

  test('start, frames, finish', () async {
    final encoder = await FrameEncoder.start(
        width: 4, height: 2, fps: 10, outputPath: '/tmp/out.mp4');
    await encoder.addFrame(Uint8List(4 * 2 * 4));
    await encoder.addFrame(Uint8List(4 * 2 * 4), repeat: 9);
    expect(encoder.frameCount, 10);
    expect(encoder.duration, const Duration(seconds: 1));
    final path = await encoder.finish(audioPath: '/tmp/a.m4a');
    expect(path, '/tmp/out.mp4');
    expect(calls.map((c) => c.method),
        ['start', 'addFrame', 'addFrame', 'finish']);
    expect(calls.last.arguments, {'id': 7, 'audioPath': '/tmp/a.m4a'});
  });

  test('rejects odd sizes and wrong frame length', () async {
    expect(
        () => FrameEncoder.start(width: 3, height: 2, outputPath: '/tmp/x'),
        throwsArgumentError);
    final encoder = await FrameEncoder.start(
        width: 4, height: 2, outputPath: '/tmp/out.mp4');
    expect(() => encoder.addFrame(Uint8List(5)), throwsArgumentError);
  });

  test('cannot finish twice or without frames', () async {
    final encoder = await FrameEncoder.start(
        width: 4, height: 2, outputPath: '/tmp/out.mp4');
    expect(() => encoder.finish(), throwsA(isA<FrameEncoderException>()));
    await encoder.addFrame(Uint8List(32));
    await encoder.finish();
    expect(() => encoder.addFrame(Uint8List(32)),
        throwsA(isA<FrameEncoderException>()));
  });
}
