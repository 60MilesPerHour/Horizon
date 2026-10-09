import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Pages/chat_page/subwidgets/horizon_composer.dart';
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

  testWidgets('the send button sits where the voice orb was', (tester) async {
    final controller = TextEditingController();
    Widget composer({required bool canSend, bool streaming = false, String? model = 'm'}) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: HorizonComposer(
                controller: controller,
                hint: 'Ask anything',
                modelLabel: model,
                provider: 'ollama',
                onModelTap: () {},
                attachButton: const SizedBox(width: 40, height: 40),
                canSend: canSend,
                streaming: streaming,
                onSend: () {},
                onStop: () {},
                onVoice: () {},
              ),
            ),
          ),
        );

    await tester.pumpWidget(composer(canSend: false));
    final orb = tester.getCenter(find.byType(VoiceOrb));
    final height = tester.getSize(find.byType(HorizonComposer)).height;

    await tester.pumpWidget(composer(canSend: true));
    await tester.pump();
    expect(tester.getCenter(find.byType(HorizonSendButton)), orb);
    expect(tester.getSize(find.byType(HorizonComposer)).height, height);

    await tester.pumpWidget(composer(canSend: true, streaming: true));
    await tester.pump();
    expect(tester.getCenter(find.byType(HorizonSendButton)), orb);

    // Nor does the model's name move it: a long one used to push it right.
    await tester.pumpWidget(composer(canSend: true, model: 'kimi-k2.6:cloud-with-a-long-name'));
    await tester.pump();
    expect(tester.getCenter(find.byType(HorizonSendButton)), orb);
    await tester.pumpWidget(composer(canSend: false, model: null));
    await tester.pump();
    expect(tester.getCenter(find.byType(VoiceOrb)), orb);
  });
}
