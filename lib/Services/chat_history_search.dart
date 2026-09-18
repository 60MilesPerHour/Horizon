import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Services/database_service.dart';

/// Searches your other conversations on the model's behalf, for the
/// `search_chats` tool.
///
/// Context bridging as a *tool* rather than an injection: the alternative —
/// rolling summaries of every bridged chat pushed into the system prompt — is
/// paid for on every single turn whether or not it's relevant, and the voice
/// assistant does short turns constantly. Here nothing leaves a chat until the
/// model decides it needs history and asks for it.
///
/// Scope is opt-in per chat ([OllamaChatOptions.bridge]). A chat that isn't
/// bridged is invisible to this, which is the whole point of the switch.
class ChatHistorySearch {
  ChatHistorySearch({required DatabaseService database}) : _database = database;

  final DatabaseService _database;

  /// Supplies the live chat list. Set by `ChatProvider` at construction
  /// rather than passed in, because this service is built before it — and
  /// reading through a callback means there's no cached copy of the chat list
  /// here to go stale when a chat's bridge switch is flipped.
  List<OllamaChat> Function()? chatsSource;

  /// How many matching messages are handed back at most. Small on purpose:
  /// this lands in the prompt, and six relevant excerpts beat thirty that
  /// push the actual question out of the context window.
  static const int maxHits = 6;

  /// Characters kept per excerpt.
  static const int excerptChars = 400;

  List<OllamaChat> get bridgedChats =>
      (chatsSource?.call() ?? const <OllamaChat>[]).where((chat) => chat.options.bridge).toList();

  /// Whether the tool is worth declaring at all.
  bool get isConfigured => bridgedChats.isNotEmpty;

  /// Runs the search and formats it for the model, or returns null when there
  /// is nothing to search.
  Future<String?> searchFormatted(String query, {String? excludeChatId}) async {
    final chats = bridgedChats.where((chat) => chat.id != excludeChatId).toList();
    if (chats.isEmpty) return null;

    final terms = _terms(query);
    if (terms.isEmpty) return null;

    final hits = await _database.searchMessages(chatIds: chats.map((c) => c.id).toList(), terms: terms, limit: maxHits);
    if (hits.isEmpty) {
      return 'No messages in the shared conversations '
          '(${chats.map((c) => '"${c.title}"').join(', ')}) match "$query".';
    }

    final buffer = StringBuffer(
      'Found ${hits.length} message${hits.length == 1 ? '' : 's'} in your '
      'other conversations matching "$query":\n',
    );
    for (final hit in hits) {
      buffer.writeln();
      final who = hit.role == 'user' ? 'You' : 'Assistant';
      buffer.writeln('[${hit.chatTitle} · ${_formatDate(hit.timestamp)} · $who]');
      buffer.writeln(_excerpt(hit.content, terms));
    }
    return buffer.toString();
  }

  /// Splits a query into search terms, dropping the words that would match
  /// nearly every message. A model asked to search often writes a whole
  /// question ("what did I say about the oil filter for the mazda"), and every
  /// term has to match, so the filler has to go or nothing is ever found.
  static List<String> _terms(String query) {
    const stopWords = {
      'the',
      'a',
      'an',
      'and',
      'or',
      'of',
      'to',
      'in',
      'on',
      'for',
      'with',
      'about',
      'what',
      'when',
      'where',
      'who',
      'why',
      'how',
      'did',
      'do',
      'does',
      'is',
      'are',
      'was',
      'were',
      'i',
      'me',
      'my',
      'we',
      'you',
      'your',
      'it',
      'that',
      'this',
      'say',
      'said',
      'tell',
      'told',
      'talk',
      'talked',
      'mention',
      'mentioned',
      'chat',
      'conversation',
      'discuss',
      'discussed',
    };
    return query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9À-ɏ]+'))
        .where((word) => word.length > 2 && !stopWords.contains(word))
        .toSet()
        .take(6)
        .toList();
  }

  /// A window around the first matching term, rather than the first N
  /// characters — the match is usually in the middle of a long message, and a
  /// head-truncated excerpt cuts off exactly the part that was searched for.
  static String _excerpt(String content, List<String> terms) {
    final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= excerptChars) return flat;

    var index = -1;
    for (final term in terms) {
      index = flat.toLowerCase().indexOf(term);
      if (index != -1) break;
    }
    if (index == -1) return '${flat.substring(0, excerptChars)}…';

    final start = (index - excerptChars ~/ 3).clamp(0, flat.length);
    final end = (start + excerptChars).clamp(0, flat.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < flat.length ? '…' : '';
    return '$prefix${flat.substring(start, end)}$suffix';
  }

  static String _formatDate(DateTime when) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${when.day} ${months[when.month - 1]} ${when.year}';
  }
}
