import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Providers/chat_provider.dart';

/// The assistant chat is never pruned by a user, so what's sent to the model
/// has to be capped. The cut has to leave a *valid* transcript: an
/// OpenAI-compatible endpoint rejects one that opens with a tool result whose
/// assistant message has been cut away, and that failure looks like "voice
/// mode is broken", not "the history got long".
void main() {
  OllamaMessage user(String text) =>
      OllamaMessage(text, role: OllamaMessageRole.user);
  OllamaMessage assistant(String text) =>
      OllamaMessage(text, role: OllamaMessageRole.assistant);

  test('a short history is sent untouched', () {
    final messages = [user('hi'), assistant('hello')];
    expect(ChatProvider.trimAssistantHistory(messages), same(messages));
  });

  test('a long history is cut to the window', () {
    final messages = [
      for (var i = 0; i < 40; i++) i.isEven ? user('q$i') : assistant('a$i'),
    ];
    final trimmed = ChatProvider.trimAssistantHistory(messages, keep: 10);
    expect(trimmed.length, lessThanOrEqualTo(10));
    expect(trimmed.last.content, 'a39');
  });

  test('the cut always lands on a user turn', () {
    final messages = [
      for (var i = 0; i < 21; i++) i.isEven ? user('q$i') : assistant('a$i'),
    ];
    // keep: 10 would start mid-exchange on an assistant turn; it has to move
    // forward to the next user message instead.
    final trimmed = ChatProvider.trimAssistantHistory(messages, keep: 10);
    expect(trimmed.first.role, OllamaMessageRole.user);
  });

  test('a tool result is never orphaned from its call', () {
    final call = ToolCall(
      id: 'call_1',
      name: 'current_time',
      arguments: const {},
    );
    final messages = [
      user('old question'),
      assistant('old answer'),
      user('what time is it'),
      OllamaMessage('', role: OllamaMessageRole.assistant, toolCalls: [call]),
      OllamaMessage.toolResult(call: call, result: const ToolResult('Tuesday')),
      assistant('It is Tuesday.'),
    ];

    // A window of 3 would start at the tool-calling assistant message and
    // leave its result behind it — valid — but a window of 2 would open on
    // the orphaned tool result.
    final trimmed = ChatProvider.trimAssistantHistory(messages, keep: 2);
    expect(trimmed.first.role, OllamaMessageRole.user);
    expect(trimmed.first.content, 'what time is it');
  });

  test('sends more than the window rather than cutting into a tool exchange',
      () {
    final call = ToolCall(id: 'c', name: 'current_time', arguments: const {});
    final messages = [
      user('go'),
      for (var i = 0; i < 6; i++)
        OllamaMessage.toolResult(call: call, result: const ToolResult('x')),
    ];
    // Every candidate cut inside the window lands on a tool result, so it
    // walks back to the user turn and sends the lot. Over-sending costs
    // tokens; under-sending would make the provider reject the turn outright.
    final trimmed = ChatProvider.trimAssistantHistory(messages, keep: 3);
    expect(trimmed.length, messages.length);
    expect(trimmed.first.role, OllamaMessageRole.user);
  });

  test('the shipped window is a dozen exchanges, not a handful', () {
    // A voice conversation refers back a few turns; a window of 4 would make
    // it forget mid-exchange, and no window would re-send everything forever.
    expect(ChatProvider.assistantContextMessages, greaterThanOrEqualTo(16));
  });
}
