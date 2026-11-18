// Benchmark: draws 30 s of 1080x1920 frames at 30 fps (900 frames) with a
// PictureRecorder, encodes them to MP4 and reports time and file size.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_frame_encoder/flutter_frame_encoder.dart';

void main() => runApp(const MaterialApp(home: BenchmarkPage()));

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  static const width = 1080, height = 1920, fps = 30, seconds = 30;
  String _status = 'Tap Run to encode $seconds s at ${width}x$height';
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    final out = '${Directory.systemTemp.path}/flutter_frame_encoder_benchmark.mp4';
    final watch = Stopwatch()..start();
    try {
      final encoder = await FrameEncoder.start(
          width: width, height: height, fps: fps, outputPath: out);
      const total = fps * seconds;
      for (var i = 0; i < total; i++) {
        final image = await _drawFrame(i / total);
        await encoder.addImage(image);
        image.dispose();
        if (i % 30 == 0) setState(() => _status = 'Frame $i of $total');
      }
      final path = await encoder.finish();
      final size = await File(path).length();
      setState(() => _status = 'Done in ${watch.elapsed.inMilliseconds} ms\n'
          '${(size / 1e6).toStringAsFixed(1)} MB\n$path');
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  /// A moving gradient and a counter, so frames differ and timing is visible.
  Future<ui.Image> _drawFrame(double t) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
              Offset(0, height * t), Offset(width.toDouble(), height * (1 - t)),
              [Colors.teal, Colors.orange]));
    final paragraph = (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 160))
          ..pushStyle(ui.TextStyle(color: Colors.white))
          ..addText((t * seconds).toStringAsFixed(1)))
        .build()
      ..layout(const ui.ParagraphConstraints(width: 1000));
    canvas.drawParagraph(paragraph, Offset(80, height / 2 - 100));
    return recorder.endRecording().toImage(width, height);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('flutter_frame_encoder benchmark')),
        body: Center(child: Text(_status, textAlign: TextAlign.center)),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _running ? null : _run,
          label: Text(_running ? 'Running' : 'Run'),
        ),
      );
}
