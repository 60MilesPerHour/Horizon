import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/hermes_commands.dart';

void main() {
  test('a known command parses with its argument', () {
    final (command, arg) = HermesCommand.parse('/think  low ')!;
    expect(command.name, 'think');
    expect(arg, 'low');
    expect(HermesCommand.parse('/RESET')!.$1.name, 'reset');
  });

  test('a message that only starts with a slash goes to the agent', () {
    expect(HermesCommand.parse('/home/miles/x will not open'), isNull);
    expect(HermesCommand.parse('/etc is full'), isNull);
    expect(HermesCommand.parse('hello /new'), isNull);
    expect(HermesCommand.parse('/'), isNull);
  });

  test('the menu matches the first word only', () {
    expect(HermesCommand.matching('/'), hasLength(HermesCommand.all.length));
    expect(HermesCommand.matching('/st').map((c) => c.name), ['stop', 'status']);
    expect(HermesCommand.matching('/think '), isEmpty);
    expect(HermesCommand.matching('think'), isEmpty);
  });

  test('thinking levels map onto reasoning_effort', () {
    expect(HermesCommand.thinkingLevel('off'), 'none');
    expect(HermesCommand.thinkingLevel('High'), 'high');
    expect(HermesCommand.thinkingLevel('default'), '');
    expect(HermesCommand.thinkingLevel('turbo'), isNull);
  });
}
