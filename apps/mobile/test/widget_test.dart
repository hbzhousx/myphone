import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:myphone/main.dart';

void main() {
  testWidgets('app boots into router shell', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: MyPhoneApp()));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
