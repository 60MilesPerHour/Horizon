/// Slash commands for a chat on a Hermes agent.
///
/// The Runs API takes text and nothing else: the commands Hermes answers on
/// Telegram (`/new`, `/stop`, …) live in its messaging gateway, which runs
/// never pass through, so `/new` sent as a message is just the word "new" to
/// the model. These are Horizon's own, mapped onto what the API does offer.
class HermesCommand {
  final String name;

  /// Shown after the name in the menu: `[off|low|…]`.
  final String? args;
  final String description;

  const HermesCommand(this.name, this.description, {this.args});

  static const List<HermesCommand> all = [
    HermesCommand('new', 'Start a fresh chat with the agent'),
    HermesCommand('reset', 'The agent forgets this chat; the transcript stays here'),
    HermesCommand('think', 'How hard the agent thinks in this chat — off is fastest',
        args: '[off|minimal|low|medium|high|default]'),
    HermesCommand('stop', 'Stop the agent mid-turn'),
    HermesCommand('status', 'Session, thinking level, and what the last turn cost'),
    HermesCommand('tools', 'The toolsets the agent has switched on'),
    HermesCommand('help', 'List these commands'),
  ];

  /// Commands whose name starts with what's typed so far, for the menu. Only
  /// while the first word is still being typed: once there's a space, the
  /// menu has done its job.
  static List<HermesCommand> matching(String text) {
    if (!text.startsWith('/') || text.contains(RegExp(r'\s'))) return const [];
    final typed = text.substring(1).toLowerCase();
    return [for (final c in all) if (c.name.startsWith(typed)) c];
  }

  /// The command [text] invokes and its argument, or null if it isn't one.
  ///
  /// Only a known name counts. A message that merely starts with a slash —
  /// "/home/miles/x won't open" — goes to the agent as written.
  static (HermesCommand, String)? parse(String text) {
    final match = RegExp(r'^/(\w+)(?:\s+(.*))?$', dotAll: true).firstMatch(text.trim());
    if (match == null) return null;
    final name = match.group(1)!.toLowerCase();
    for (final c in all) {
      if (c.name == name) return (c, (match.group(2) ?? '').trim());
    }
    return null;
  }

  /// `/think` arguments to Hermes' reasoning_effort, '' being the model's own
  /// default. Null for anything else.
  static String? thinkingLevel(String arg) => switch (arg.toLowerCase()) {
        'off' || 'none' => 'none',
        'minimal' || 'low' || 'medium' || 'high' => arg.toLowerCase(),
        'default' => '',
        _ => null,
      };
}

/// What a command has to say back. [detail] goes in a sheet; a one-liner
/// is a snackbar.
class HermesCommandResult {
  final String message;
  final String? detail;

  const HermesCommandResult(this.message, {this.detail});
}
