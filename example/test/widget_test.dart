import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_frame_encoder_example/main.dart';

void main() {
  testWidgets('benchmark page shows the Run button', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BenchmarkPage()));
    expect(find.text('Run'), findsOneWidget);
  });
}
