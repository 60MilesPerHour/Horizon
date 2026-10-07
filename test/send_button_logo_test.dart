import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Widgets/horizon_brand.dart';

void main() {
  test('every provider the app routes to has a send-button logo', () {
    for (final provider in ['ollama', 'openrouter', 'anthropic', 'openai', 'google']) {
      expect(HorizonSendButton.logoFor(provider), isNotNull, reason: provider);
    }
    // Anything else keeps the arrow rather than pointing at a missing asset.
    expect(HorizonSendButton.logoFor(null), isNull);
    expect(HorizonSendButton.logoFor('someone-new'), isNull);
  });

  testWidgets('each logo loads and draws', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: const ValueKey('row'),
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final p in [null, 'ollama', 'openrouter', 'anthropic', 'openai', 'google'])
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: HorizonSendButton(onPressed: () {}, provider: p),
                  ),
              ]),
            ),
          ),
        ),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
