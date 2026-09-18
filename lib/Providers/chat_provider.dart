import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:notification_centre/notification_centre.dart';

import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/attachment.dart';
import 'package:horizon/Models/chat_configure_arguments.dart';
import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Services/chat_export_service.dart';
import 'package:horizon/Services/chat_history_search.dart';
import 'package:horizon/Services/chat_service_registry.dart';
import 'package:horizon/Services/database_service.dart';
import 'package:horizon/Services/generation_keepalive.dart';
import 'package:horizon/Services/tool_service.dart';
import 'package:horizon/Services/web_search_service.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

class ChatProvider extends ChangeNotifier {
  final ChatServiceRegistry _registry;
  final DatabaseService _databaseService;
  final WebSearchService _webSearch;
  final ToolService _toolService;
  final ChatHistorySearch? _chatHistorySearch;

  /// Cap on tool round-trips within a single user turn. A model that keeps
  /// searching instead of answering would otherwise loop until the user's
  /// patience or their SerpAPI quota runs out; when the cap is hit the model
  /// is told to answer with what it has.
  static const int maxToolIterations = 6;

  List<OllamaMessage> _messages = [];
  List<OllamaMessage> get messages => _messages;

  // Notifier for streaming content only — updated by the typewriter timer without
  // calling notifyListeners(), so only the streaming bubble rebuilds (not the whole page).
  final ValueNotifier<String> streamingContent = ValueNotifier<String>('');

  List<OllamaChat> _chats = [];
  List<OllamaChat> get chats => _chats;

  int _currentChatIndex = -1;
  int get selectedDestination => _currentChatIndex + 1;

  OllamaChat? get currentChat =>
      _currentChatIndex == -1 ? null : _chats[_currentChatIndex];

  final Map<String, OllamaMessage?> _activeChatStreams = {};
  final Map<String, StreamSubscription?> _streamSubscriptions = {};

  /// Chats currently running a tool or fetching search results, mapped to the
  /// label to show ("Searching for …"). Drives the activity line under the
  /// awaiting-reply indicator, distinct from plain "Generating".
  final Map<String, String> _toolActivity = {};

  bool get isCurrentChatSearching =>
      currentChat != null && _toolActivity.containsKey(currentChat?.id);

  /// Label for whatever the current chat is doing out-of-band, or null.
  String? get currentChatActivity => _toolActivity[currentChat?.id];

  bool get isCurrentChatStreaming =>
      _activeChatStreams.containsKey(currentChat?.id);

  bool get isCurrentChatThinking =>
      currentChat != null &&
      _activeChatStreams.containsKey(currentChat?.id) &&
      _activeChatStreams[currentChat?.id] == null;

  /// A map of chat errors, indexed by chat ID.
  final Map<String, OllamaException> _chatErrors = {};

  /// The current chat error. This is the error associated with the current chat.
  /// If there is no error, this will be `null`.
  ///
  /// This is used to display error messages in the chat view.
  OllamaException? get currentChatError => _chatErrors[currentChat?.id];

  /// The current chat configuration.
  ChatConfigureArguments get currentChatConfiguration {
    if (currentChat == null) {
      return _emptyChatConfiguration ?? ChatConfigureArguments.defaultArguments;
    } else {
      return ChatConfigureArguments(
        systemPrompt: currentChat!.systemPrompt,
        chatOptions: currentChat!.options,
      );
    }
  }

  /// The chat configuration for the empty chat.
  ChatConfigureArguments? _emptyChatConfiguration;

  ChatProvider({
    required ChatServiceRegistry registry,
    required DatabaseService databaseService,
    required WebSearchService webSearch,
    required ToolService toolService,
    ChatHistorySearch? chatHistorySearch,
  })  : _registry = registry,
        _databaseService = databaseService,
        _webSearch = webSearch,
        _toolService = toolService,
        _chatHistorySearch = chatHistorySearch {
    // The `search_chats` tool reads the chat list through this callback rather
    // than being handed a copy: a copy would go stale the moment a chat's
    // "share with assistant" switch was flipped, and the tool would then
    // either miss a shared chat or search one that had been unshared.
    _chatHistorySearch?.chatsSource = () => _chats;
    _initialize();
  }

  Future<void> _initialize() async {
    _bindOllamaServerAddress();

    await _databaseService.open("ollama_chat.db");
    _chats = await _databaseService.getAllChats();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscription in _streamSubscriptions.values) {
      subscription?.cancel();
    }
    _streamSubscriptions.clear();
    streamingContent.dispose();
    super.dispose();
  }

  void destinationChatSelected(int destination) {
    _currentChatIndex = destination - 1;

    if (destination == 0) {
      _resetChat();
    } else {
      _loadCurrentChat();
    }

    notifyListeners();
  }

  void _resetChat() {
    _currentChatIndex = -1;

    _messages.clear();

    notifyListeners();
  }

  Future<void> _loadCurrentChat() async {
    // Clear synchronously BEFORE the await so callers that notify before this
    // future resolves don't render the previous chat's messages under the
    // new chat header. See createNewChat() for the matching guard.
    _messages = [];

    final loaded = await _databaseService.getMessages(currentChat!.id);
    _messages = loaded;

    // Add the streaming message to the chat if it exists
    final streamingMessage = _activeChatStreams[currentChat!.id];
    if (streamingMessage != null) {
      _messages.add(streamingMessage);
    }

    // Unfocus the text field to dismiss the keyboard
    FocusManager.instance.primaryFocus?.unfocus();

    notifyListeners();
  }

  Future<void> createNewChat(OllamaModel model) async {
    await _createNewChatInternal(model, firstPrompt: null);
    notifyListeners();
  }

  /// Hive key holding the id of the chat voice mode talks to.
  static const String assistantChatIdKey = 'assistant_chat_id';

  /// Id of the chat voice mode talks to, or null before first use.
  String? get assistantChatId =>
      Hive.box('settings').get(assistantChatIdKey) as String?;

  bool isAssistantChat(OllamaChat chat) => chat.id == assistantChatId;

  /// How many messages of the assistant chat are actually sent to the model.
  ///
  /// Voice mode deliberately reuses one long-lived chat so it remembers the
  /// last thing it was asked, and nobody ever deletes it — which means that
  /// without a cap it grows forever, and every "what's the time" eventually
  /// re-sends months of conversation. Trimming what's SENT rather than what's
  /// stored: the transcript stays complete and readable in the sidebar.
  ///
  /// 24 messages is roughly a dozen exchanges — far more than a voice
  /// conversation refers back to, and small enough that the oldest turn can't
  /// dominate the bill.
  static const int assistantContextMessages = 24;

  /// Keeps roughly the last [assistantContextMessages] messages, always
  /// starting at a user turn.
  ///
  /// Starting at a user turn is not cosmetic: a tool result has to follow the
  /// assistant message that requested it, and every OpenAI-compatible
  /// endpoint rejects a transcript that opens with an orphaned one. So the cut
  /// moves BACKWARD from the window edge to the nearest user message, never
  /// forward — erring towards sending a little more history is free, while
  /// erring towards a shorter-but-invalid transcript fails the whole turn.
  static List<OllamaMessage> trimAssistantHistory(
    List<OllamaMessage> messages, {
    int keep = assistantContextMessages,
  }) {
    if (messages.length <= keep) return messages;

    var cut = messages.length - keep;
    while (cut > 0 && messages[cut].role != OllamaMessageRole.user) {
      cut--;
    }
    return messages.sublist(cut);
  }

  /// Selects an existing chat by id, loading its messages. Returns false when
  /// the chat is gone — the caller decides whether to make a new one.
  Future<bool> selectChatById(String chatId) async {
    final index = _chats.indexWhere((c) => c.id == chatId);
    if (index == -1) return false;
    _currentChatIndex = index;
    await _loadCurrentChat();
    return true;
  }

  /// Makes the assistant chat current, creating it on first use.
  ///
  /// Voice mode uses one long-lived chat rather than a fresh one per
  /// invocation, so the assistant remembers the last thing it was asked — the
  /// difference between a conversation and a search box. It's a normal chat:
  /// it shows up in the sidebar and can be read, exported, or deleted like
  /// any other.
  Future<OllamaChat?> ensureAssistantChat({
    required OllamaModel? model,
    String? systemPrompt,
  }) async {
    final settings = Hive.box('settings');
    final storedId = settings.get(assistantChatIdKey) as String?;

    if (storedId != null && await selectChatById(storedId)) {
      return currentChat;
    }

    // No model to create one with: the caller has to resolve that first, and
    // creating a chat pinned to a nonexistent model would just fail on send.
    if (model == null) return null;

    final chat = await _createNewChatInternal(model, firstPrompt: null);
    await _databaseService.updateChat(
      chat,
      newTitle: 'Assistant',
      newSystemPrompt: systemPrompt,
    );
    _chats[0] = (await _databaseService.getChat(chat.id))!;
    await settings.put(assistantChatIdKey, chat.id);
    notifyListeners();
    return _chats[0];
  }

  /// The model the assistant chat is pinned to, if it exists.
  String? get assistantChatModel {
    final storedId = Hive.box('settings').get(assistantChatIdKey) as String?;
    if (storedId == null) return null;
    final index = _chats.indexWhere((c) => c.id == storedId);
    return index == -1 ? null : _chats[index].model;
  }

  /// Atomic "create a new chat AND send the first prompt" path used when the
  /// user fires off a prompt with no current chat selected. Folds the chat
  /// creation, message seeding, and stream init into a single notify cycle so
  /// the UI never paints an intermediate state — neither the previous chat's
  /// messages nor an empty "No messages yet" placeholder.
  Future<void> createNewChatAndSendPrompt(
    OllamaModel model,
    String text, {
    List<File>? images,
    List<Attachment>? attachments,
  }) async {
    final chat = await _createNewChatInternal(model, firstPrompt: null);

    final prompt = OllamaMessage(
      text.trim(),
      images: images,
      attachments: attachments,
      role: OllamaMessageRole.user,
    );
    _messages = [prompt];
    notifyListeners();

    await _databaseService.addMessage(prompt, chat: chat);
    await _initializeChatStream(chat);
  }

  /// Internal helper: do all the synchronous work of "make a new chat" without
  /// notifying. Returns the freshly-inserted OllamaChat (already in [_chats]).
  Future<OllamaChat> _createNewChatInternal(
    OllamaModel model, {
    required OllamaMessage? firstPrompt,
  }) async {
    final chat = await _databaseService.createChat(
      model.name,
      provider: model.provider,
    );

    // Replace _messages atomically — this clears any leftover state from a
    // previously-viewed chat AND seeds the first user prompt (if any) in the
    // same step, so the upcoming notify shows the new chat fully populated.
    _messages = firstPrompt != null ? [firstPrompt] : [];

    _chats.insert(0, chat);
    _currentChatIndex = 0;

    // Apply any pre-chat configuration the user set up on the empty chat
    // screen. Update directly through the DB to avoid the extra notify that
    // updateCurrentChat would emit.
    if (_emptyChatConfiguration != null) {
      final cfg = _emptyChatConfiguration!;
      _emptyChatConfiguration = null;
      await _databaseService.updateChat(
        chat,
        newSystemPrompt: cfg.systemPrompt,
        newOptions: cfg.chatOptions,
      );
      _chats[0] = (await _databaseService.getChat(chat.id))!;
    }

    return _chats[0];
  }

  /// Forks the current chat at [message] into a new one and opens it.
  ///
  /// Everything up to and including [message] is copied; everything after it
  /// is left behind. Use it to try a different question from a point in the
  /// conversation without destroying the answer you already have — which is
  /// what editing or regenerating does.
  ///
  /// The branch keeps the parent's model, provider, system prompt and options,
  /// so the only difference is where the history stops.
  Future<OllamaChat?> branchFromMessage(OllamaMessage message) async {
    final source = currentChat;
    if (source == null) return null;

    final branch = await _databaseService.branchChat(
      source,
      throughMessageId: message.id,
      newTitle: _branchTitle(source.title),
    );

    _chats.insert(0, branch);
    _currentChatIndex = 0;
    _messages = await _databaseService.getMessages(branch.id);
    notifyListeners();
    return branch;
  }

  /// "Title" -> "Title (2)" -> "Title (3)". Numbered rather than repeatedly
  /// suffixed, so branching a branch doesn't produce
  /// "Title (branch) (branch)".
  static String _branchTitle(String title) {
    final match = RegExp(r'^(.*) \((\d+)\)$').firstMatch(title);
    if (match != null) {
      final base = match.group(1)!;
      final n = int.tryParse(match.group(2)!) ?? 1;
      return '$base (${n + 1})';
    }
    return '$title (2)';
  }

  /// The chat a branch came from, if it still exists.
  OllamaChat? parentOf(OllamaChat chat) {
    final parentId = chat.parentChatId;
    if (parentId == null) return null;
    final index = _chats.indexWhere((c) => c.id == parentId);
    return index == -1 ? null : _chats[index];
  }

  /// Opens the chat a branch was taken from. False if it's been deleted.
  Future<bool> openParentOf(OllamaChat chat) async {
    final parentId = chat.parentChatId;
    if (parentId == null) return false;
    return selectChatById(parentId);
  }

  Future<void> updateCurrentChat({
    String? newModel,
    String? newTitle,
    String? newSystemPrompt,
    OllamaChatOptions? newOptions,
    String? newProvider,
  }) async {
    await updateChat(
      currentChat,
      newModel: newModel,
      newTitle: newTitle,
      newSystemPrompt: newSystemPrompt,
      newOptions: newOptions,
      newProvider: newProvider,
    );
  }

  /// Updates the chat with the given parameters.
  ///
  /// If the chat is `null`, it updates the empty chat configuration.
  Future<void> updateChat(
    OllamaChat? chat, {
    String? newModel,
    String? newTitle,
    String? newSystemPrompt,
    OllamaChatOptions? newOptions,
    String? newProvider,
  }) async {
    if (chat == null) {
      final chatOptions = newOptions ?? _emptyChatConfiguration?.chatOptions;
      _emptyChatConfiguration = ChatConfigureArguments(
        systemPrompt: newSystemPrompt ?? _emptyChatConfiguration?.systemPrompt,
        chatOptions: chatOptions ?? OllamaChatOptions(),
      );
    } else {
      await _databaseService.updateChat(
        chat,
        newModel: newModel,
        newTitle: newTitle,
        newSystemPrompt: newSystemPrompt,
        newOptions: newOptions,
        newProvider: newProvider,
      );

      final chatIndex = _chats.indexWhere((c) => c.id == chat.id);

      if (chatIndex != -1) {
        _chats[chatIndex] = (await _databaseService.getChat(chat.id))!;
        notifyListeners();
      } else {
        throw OllamaException("Chat not found.");
      }
    }
  }

  Future<void> deleteCurrentChat() async {
    final chat = currentChat;
    if (chat == null) return;

    _resetChat();

    _chats.remove(chat);
    _activeChatStreams.remove(chat.id);

    // Forget the pointer too, or voice mode keeps trying to open a chat that
    // no longer exists and silently refuses to start.
    final settings = Hive.box('settings');
    if (settings.get(assistantChatIdKey) == chat.id) {
      await settings.delete(assistantChatIdKey);
    }

    await _databaseService.deleteChat(chat.id);
  }

  Future<void> sendPrompt(
    String text, {
    List<File>? images,
    List<Attachment>? attachments,
  }) async {
    // Save the chat where the prompt was sent
    final associatedChat = currentChat!;

    // Create a user prompt message and add it to the chat
    final prompt = OllamaMessage(
      text.trim(),
      images: images,
      attachments: attachments,
      role: OllamaMessageRole.user,
    );
    _messages.add(prompt);

    notifyListeners();

    // Save the user prompt to the database
    await _databaseService.addMessage(prompt, chat: associatedChat);

    // Initialize the chat stream with the messages in the chat
    await _initializeChatStream(associatedChat);
  }

  Future<void> _initializeChatStream(OllamaChat associatedChat) async {
    // Send a notification to inform generation begin
    NotificationCenter().postNotification(NotificationNames.generationBegin);

    // Reset the streaming buffer before the next response starts. Without
    // this, the notifier still holds the previous assistant's final text;
    // any bubble that listens to it during the "Thinking" window would
    // paint that stale content instead of its own message.content.
    streamingContent.value = '';

    // Clear the active chat streams to cancel the previous stream
    _activeChatStreams.remove(associatedChat.id);

    // Clear the error message associated with the chat
    if (_chatErrors.remove(associatedChat.id) != null) {
      notifyListeners();
      // Wait for a short time to show the user that the error message is cleared
      await Future.delayed(Duration(milliseconds: 250));
    }

    // Update the chat list to show the latest chat at the top
    _moveCurrentChatToTop();

    // Add the chat to the active chat streams to show the thinking indicator
    _activeChatStreams[associatedChat.id] = null;
    // Notify the listeners to show the thinking indicator
    notifyListeners();

    // Stream the Ollama message
    OllamaMessage? ollamaMessage;

    // Hold an Android foreground service for the duration of the stream so a
    // brief app switch doesn't freeze the process and kill the connection.
    await GenerationKeepalive.acquire();

    try {
      await _runTurn(associatedChat);
    } on OllamaException catch (error) {
      _chatErrors[associatedChat.id] = error;
      ollamaMessage = _salvagePartial(associatedChat);
    } catch (error) {
      // Never flatten to a generic message — format whatever actually
      // happened (socket drop, timeout, TLS failure, parse error, ...).
      _chatErrors[associatedChat.id] =
          OllamaException(HttpErrorFormatter.formatException(error));
      ollamaMessage = _salvagePartial(associatedChat);
    } finally {
      // Remove the chat from the active chat streams
      _activeChatStreams.remove(associatedChat.id);
      _toolActivity.remove(associatedChat.id);
      await GenerationKeepalive.release();
      notifyListeners();
    }

    // Only the salvage path lands here: _runTurn persists each message as it
    // completes, because a tool round-trip can produce several per turn.
    if (ollamaMessage != null) {
      await _databaseService.addMessage(ollamaMessage, chat: associatedChat);
    }
  }

  /// Runs one user turn to completion, including any tool round-trips.
  ///
  /// The model streams a reply; if that reply asks for tools, they're executed,
  /// their results are appended to the transcript as `tool` messages, and the
  /// model is called again with them — repeating until it answers in prose or
  /// [maxToolIterations] is hit. Every message is persisted as it completes so
  /// a crash or a dropped connection mid-loop leaves the transcript coherent
  /// rather than losing the tool work.
  Future<void> _runTurn(OllamaChat associatedChat) async {
    final (outgoing, effectiveChat, tools) = await _prepareSend(associatedChat);
    // Copied, not aliased: _prepareSend usually hands back `_messages` itself,
    // and both _streamOllamaMessage and the tool loop below append to
    // `_messages` for display. Spreading a live alias would then send the
    // assistant turn and every tool result to the provider twice.
    var conversation = List<OllamaMessage>.from(outgoing);
    var activeTools = tools;

    for (var iteration = 0;; iteration++) {
      // Past the cap the tools simply stop being offered, so the model's only
      // option is to answer with what the previous rounds returned. No notice
      // or forced extra pass needed — it can't call what isn't declared.
      final offeredTools =
          iteration < maxToolIterations ? activeTools : const <ToolDefinition>[];

      OllamaMessage? assistant;
      try {
        assistant = await _streamOllamaMessage(
          associatedChat,
          conversation,
          effectiveChat,
          tools: offeredTools,
        );
      } on OllamaException catch (error) {
        // A model that doesn't do tools usually says so with a 400 rather than
        // a capability flag. Remember it, drop the tools, and re-run the same
        // turn so the user gets an answer instead of an error they can't act
        // on. Only ever retried once per turn, since activeTools is empty
        // afterwards and the guard below can't fire again.
        if (activeTools.isNotEmpty && _looksLikeToolsUnsupported(error)) {
          _toolSupport['${effectiveChat.provider}:${effectiveChat.model}'] = false;
          activeTools = const [];
          iteration--;
          continue;
        }
        rethrow;
      }

      if (assistant == null) return; // cancelled, or nothing was produced

      await _databaseService.addMessage(assistant, chat: associatedChat);
      if (!assistant.hasToolCalls) return;

      // A model can emit a tool call even when none were declared (small ones
      // hallucinate the syntax). Running it would loop forever, so stop here
      // and leave its reply as the final word.
      if (offeredTools.isEmpty) return;

      final results = <OllamaMessage>[];
      for (final call in assistant.toolCalls!) {
        // The user can cancel mid-tool; stop before spending another request.
        if (!_activeChatStreams.containsKey(associatedChat.id)) return;

        // Say what's happening while it happens — a silent 20-second page
        // fetch is indistinguishable from a hung connection.
        _toolActivity[associatedChat.id] = _toolService.labelFor(call);
        notifyListeners();

        final result = await _toolService.execute(
          call,
          currentChatId: associatedChat.id,
        );
        final message = OllamaMessage.toolResult(call: call, result: result);
        results.add(message);
        await _databaseService.addMessage(message, chat: associatedChat);
        if (associatedChat.id == currentChat?.id) _messages.add(message);
        notifyListeners();
      }

      _toolActivity.remove(associatedChat.id);
      // Re-arm the awaiting-reply indicator for the next model pass and clear
      // the streaming buffer so the next bubble doesn't open on stale text.
      _activeChatStreams[associatedChat.id] = null;
      streamingContent.value = '';
      notifyListeners();

      conversation = [...conversation, assistant, ...results];
    }
  }

  /// True for the leading half of a UTF-16 surrogate pair.
  ///
  /// Non-BMP characters — emoji, most notably — are two code units, and any
  /// index-based split can land between them.
  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  /// Whether [error] is a provider complaining that the model can't use tools,
  /// as opposed to any other 400. Matched on text because none of the four
  /// providers expose a machine-readable code for it.
  static bool _looksLikeToolsUnsupported(OllamaException error) {
    final message = error.toString().toLowerCase();
    if (!message.contains('tool')) return false;
    return message.contains('does not support') ||
        message.contains('not supported') ||
        message.contains('unsupported') ||
        message.contains('no tool support') ||
        message.contains('does not support tools');
  }

  /// If a stream died mid-response, rescue whatever text already arrived so
  /// it gets persisted like any other message instead of silently vanishing
  /// the next time the chat loads. The error box still shows alongside it.
  OllamaMessage? _salvagePartial(OllamaChat chat) {
    final partial = _activeChatStreams[chat.id];
    if (partial == null || partial.content.isEmpty) return null;
    partial.createdAt = DateTime.now();
    return partial;
  }

  Future<OllamaMessage?> _streamOllamaMessage(
    OllamaChat associatedChat,
    List<OllamaMessage> outgoing,
    OllamaChat effectiveChat, {
    List<ToolDefinition> tools = const [],
  }) async {
    if (_messages.isEmpty) return null;

    final service = _registry.forChat(effectiveChat);
    final stream = service.chatStream(
      outgoing,
      chat: effectiveChat,
      tools: tools,
    );

    OllamaMessage? streamingMessage;
    OllamaMessage? receivedMessage;

    // Tool calls can arrive on any chunk (Ollama attaches them to the final
    // one, Gemini mid-stream, OpenAI/Anthropic reassembled at the end), and a
    // tool-calling turn often carries no text at all — so they're collected
    // separately from the typewriter path and attached once the stream ends.
    final collectedToolCalls = <ToolCall>[];

    // Typewriter buffer: incoming tokens go into [pending]; a 32 ms timer
    // drains characters into the displayed message at a steady pace.
    //
    // Why 32 ms and not 16 ms: at 120 Hz the per-frame budget is 8.3 ms, and
    // rebuilding the streaming Text widget plus relaying out the bottom
    // sliver on every 16 ms tick was burning enough of that budget to make
    // touch scrolling feel sticky during long streams. ~30 fps repaint is
    // still well above human reading rate but leaves the gesture system
    // breathing room. Drain rate is bumped proportionally so the visible
    // speed of text appearing doesn't change.
    final pending = StringBuffer();
    Timer? typewriter;

    void startTypewriter() {
      typewriter ??= Timer.periodic(const Duration(milliseconds: 32), (t) {
        if (pending.isEmpty || streamingMessage == null) return;
        final s = pending.toString();
        pending.clear();
        // Cap of 160 chars/tick (~5000 chars/s): thinking models and burst
        // arrivals can drop thousands of characters at once, and the old cap
        // of 48 left a backlog that then snapped onto screen all at once at
        // stream end. 160 drains a 4K burst in ~1s while still animating.
        var n = (s.length ~/ 4).clamp(2, 160);
        // Don't cut between the halves of a surrogate pair. `substring` works
        // on UTF-16 code units, so slicing an emoji down the middle emits a
        // lone surrogate — which renders as the unknown-glyph box for one
        // frame until the next tick appends its partner and repairs it.
        // Leaving the pair in `pending` costs one tick and never glitches.
        if (n < s.length && _isHighSurrogate(s.codeUnitAt(n - 1))) n -= 1;
        if (n <= 0) return;
        streamingMessage.content += s.substring(0, n);
        if (n < s.length) pending.write(s.substring(n));
        // Update only the ValueNotifier — avoids a full-page rebuild.
        streamingContent.value = streamingMessage.content;
      });
    }

    void flushAll() {
      typewriter?.cancel();
      typewriter = null;
      if (pending.isNotEmpty && streamingMessage != null) {
        streamingMessage.content += pending.toString();
        pending.clear();
        streamingContent.value = streamingMessage.content;
      }
    }

    /// Animates out whatever is still buffered when the stream ends, instead
    /// of dumping it onto screen in one frame. Models that "think" silently
    /// and then emit the whole answer in a burst otherwise show a few words,
    /// a long pause, then a wall of text appearing instantly.
    Future<void> drainGently() async {
      startTypewriter();
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (pending.isNotEmpty &&
          streamingMessage != null &&
          DateTime.now().isBefore(deadline) &&
          _activeChatStreams.containsKey(associatedChat.id)) {
        await Future.delayed(const Duration(milliseconds: 32));
      }
      // Whatever remains (deadline hit, or user cancelled the tail
      // animation) lands instantly — the content is already complete.
      flushAll();
    }

    bool cancelled = false;
    bool completedNormally = false;
    try {
      await for (receivedMessage in stream) {
        if (_activeChatStreams.containsKey(associatedChat.id) == false) {
          cancelled = true;
          streamingMessage?.createdAt = DateTime.now();
          return streamingMessage;
        }

        if (receivedMessage.hasToolCalls) {
          collectedToolCalls.addAll(receivedMessage.toolCalls!);
        }

        if (receivedMessage.content.isEmpty && streamingMessage == null) {
          continue;
        }

        if (streamingMessage == null) {
          // Adopt the message envelope but start with empty content so the
          // typewriter timer is the only path that writes to it.
          streamingMessage = receivedMessage;
          pending.write(streamingMessage.content);
          streamingMessage.content = '';
          streamingContent.value = '';
          _activeChatStreams[associatedChat.id] = streamingMessage;

          if (associatedChat.id == currentChat?.id) {
            _messages.add(streamingMessage);
            // One structural notify so ChatPage knows to wire the ValueNotifier
            // to the streaming bubble. Subsequent content updates go through
            // streamingContent directly, not notifyListeners().
            notifyListeners();
          }
        } else {
          pending.write(receivedMessage.content);
        }

        startTypewriter();
      }
      completedNormally = true;
    } finally {
      if (cancelled) {
        typewriter?.cancel();
        pending.clear();
      } else if (completedNormally) {
        // Natural completion: animate the buffered tail out smoothly.
        await drainGently();
      } else {
        // Error mid-stream: flush instantly so the error isn't delayed
        // behind an animation.
        flushAll();
      }
      _streamSubscriptions.remove(associatedChat.id);
    }

    if (receivedMessage != null) {
      streamingMessage?.updateMetadataFrom(receivedMessage);
    }

    // A turn that only called tools produced no text, so no bubble was ever
    // opened. Mint the assistant message now that we know what it is — the
    // transcript needs it to replay the call back to the provider, and the
    // bubble renders it as a tool card rather than an empty message.
    if (streamingMessage == null && collectedToolCalls.isNotEmpty) {
      streamingMessage = OllamaMessage(
        '',
        role: OllamaMessageRole.assistant,
        model: receivedMessage?.model ?? effectiveChat.model,
        toolCalls: collectedToolCalls,
      );
      if (associatedChat.id == currentChat?.id) {
        _messages.add(streamingMessage);
      }
    } else if (streamingMessage != null && collectedToolCalls.isNotEmpty) {
      streamingMessage.toolCalls = collectedToolCalls;
    }

    streamingMessage?.createdAt = DateTime.now();
    notifyListeners();

    return streamingMessage;
  }

  /// Per-model tool support, keyed `provider:model`. Populated from the model
  /// list (Ollama's /api/show and OpenRouter's model metadata both report it)
  /// and corrected by [_looksLikeToolsUnsupported] when a provider rejects a
  /// tool-bearing request.
  final Map<String, bool> _toolSupport = {};

  /// Records what the freshly-listed models say about tool support.
  void _rememberToolSupport(List<OllamaModel> models) {
    for (final model in models) {
      final capabilities = model.capabilities;
      if (capabilities == null) continue;
      _toolSupport['${model.provider}:${model.name}'] = capabilities.tools;
    }
  }

  /// Whether to declare tools for [chat].
  ///
  /// Prefers what the model list reported. With nothing cached — a chat
  /// reopened before any model fetch — cloud providers are assumed capable
  /// (every current hosted chat model is) while Ollama is not, because sending
  /// tools to a local model that lacks them is an outright 400 rather than a
  /// degraded answer. Either guess self-corrects on first use.
  bool _modelSupportsTools(OllamaChat chat) {
    final cached = _toolSupport['${chat.provider}:${chat.model}'];
    if (cached != null) return cached;
    return chat.provider != 'ollama';
  }

  /// Prepares the actual send: the message list to stream, the chat (with any
  /// system-prompt addons) to send it under, and the tools to declare.
  ///
  /// Two mechanisms, picked automatically:
  ///   * **Native tools** when the model supports them — the tools are
  ///     declared in the provider's own protocol and the model calls what it
  ///     needs, as many times as it needs.
  ///   * **The legacy convention pass** otherwise, and only when a search
  ///     backend is configured: a cheap decision call asks the model to reply
  ///     `<search>query</search>` or `<nosearch>`, and results are injected as
  ///     plain text. Weaker — it can only search, once, and depends on the
  ///     model obeying prose — but it works on models with no tool support.
  Future<(List<OllamaMessage>, OllamaChat, List<ToolDefinition>)> _prepareSend(
    OllamaChat chat,
  ) async {
    // The assistant chat is the one nobody prunes, so it's the one that needs
    // a ceiling on what gets sent. Every other chat is sent in full.
    var outgoing =
        isAssistantChat(chat) ? trimAssistantHistory(_messages) : _messages;
    var systemAddon = '';
    var tools = const <ToolDefinition>[];

    if (chat.options.tools) {
      final service = _registry.forChat(chat);
      final native = service.supportsTools && _modelSupportsTools(chat);

      if (native) {
        tools = _toolService.availableTools();
        if (tools.isNotEmpty) systemAddon += ToolConstants.systemPromptAddon;
      } else if (_webSearch.isConfigured) {
        systemAddon += WebSearchConstants.systemPromptAddon;
        String? context;
        try {
          context = await _runWebSearchPrePass(chat);
        } catch (_) {
          context = null; // best-effort; fall back to a normal send
        }
        if (context != null) {
          outgoing = _appendToLastUser(outgoing, context);
        }
      }
    }

    if (chat.options.artifacts) {
      systemAddon += ArtifactConstants.systemPromptAddon;
    }

    final effectiveChat =
        systemAddon.isEmpty ? chat : _withSystemAddon(chat, systemAddon);
    return (outgoing, effectiveChat, tools);
  }

  /// Runs the decision pass and, if the model asks for a search, fetches and
  /// formats results. Returns the injectable context block, or null when no
  /// search is wanted / nothing is found. Manages the "Searching…" state.
  Future<String?> _runWebSearchPrePass(OllamaChat chat) async {
    final lastUser = _messages.lastWhere(
      (m) => m.role == OllamaMessageRole.user,
      orElse: () => _messages.last,
    );

    // Decision pass — buffered, never displayed. Uses only the latest user
    // message under a focused decision system prompt to keep it cheap.
    // The decision reply is tiny (`<search>query</search>` or `<nosearch>`),
    // but a model that ignores the directive will otherwise generate a full
    // answer here that we just throw away. Cap the output hard and force
    // thinking off so the budget isn't spent reasoning before the tag. The cap
    // maps to num_predict / max_tokens / maxOutputTokens across every provider.
    final decisionChat = OllamaChat(
      id: chat.id,
      model: chat.model,
      title: chat.title,
      systemPrompt: WebSearchConstants.decisionSystemPrompt,
      options: OllamaChatOptions(maxTokens: 64, think: false),
      provider: chat.provider,
    );
    final decision = await _collectResponse(
      [OllamaMessage(lastUser.content, role: OllamaMessageRole.user)],
      decisionChat,
    );

    final query = _extractSearchQuery(decision);
    if (query == null) return null; // model chose not to search

    // Bail if the user cancelled while the decision pass ran.
    if (!_activeChatStreams.containsKey(chat.id)) return null;

    _toolActivity[chat.id] = 'Searching for "$query"…';
    notifyListeners();
    try {
      return await _webSearch.buildContext(query);
    } finally {
      _toolActivity.remove(chat.id);
      notifyListeners();
    }
  }

  /// Drains a chat stream into a single string. Used for the (short, non-
  /// displayed) web-search decision pass.
  Future<String> _collectResponse(
    List<OllamaMessage> messages,
    OllamaChat chat,
  ) async {
    final service = _registry.forChat(chat);
    final buffer = StringBuffer();
    await for (final message in service.chatStream(messages, chat: chat)) {
      buffer.write(message.content);
    }
    return buffer.toString();
  }

  /// Pulls the query out of a `<search>…</search>` directive, or null if the
  /// model didn't ask to search (e.g. it replied `<nosearch>`).
  String? _extractSearchQuery(String text) {
    final match =
        RegExp(r'<search>(.*?)</search>', dotAll: true).firstMatch(text);
    final query = match?.group(1)?.trim();
    return (query == null || query.isEmpty) ? null : query;
  }

  /// Returns a NEW message list with [extra] appended to the latest user turn's
  /// content. The stored [_messages] (and the visible bubble) are untouched —
  /// the injected context is only ever seen by the model. Appending to the
  /// existing user turn (vs. inserting a message) keeps role alternation
  /// intact, which Claude and Gemini require.
  List<OllamaMessage> _appendToLastUser(
    List<OllamaMessage> messages,
    String extra,
  ) {
    final index =
        messages.lastIndexWhere((m) => m.role == OllamaMessageRole.user);
    if (index == -1) return messages;

    final userMessage = messages[index];
    final copy = List<OllamaMessage>.from(messages);
    copy[index] = OllamaMessage(
      '${userMessage.content}\n\n$extra',
      id: userMessage.id,
      role: userMessage.role,
      images: userMessage.images,
      // Carried over or the attached documents silently vanish from the one
      // send that needed them most.
      attachments: userMessage.attachments,
      createdAt: userMessage.createdAt,
    );
    return copy;
  }

  /// Returns a derived chat whose system prompt has [addon] appended. Keeps the
  /// same id/model/options/provider — services only read those plus the system
  /// prompt — so this changes nothing about routing or persistence; it only
  /// shapes what the model is told for this one request.
  OllamaChat _withSystemAddon(OllamaChat chat, String addon) {
    final base = chat.systemPrompt ?? '';
    return OllamaChat(
      id: chat.id,
      model: chat.model,
      title: chat.title,
      systemPrompt: base + addon,
      options: chat.options,
      provider: chat.provider,
    );
  }

  Future<void> regenerateMessage(OllamaMessage message) async {
    final associatedChat = currentChat!;

    final messageIndex = _messages.indexOf(message);
    if (messageIndex == -1) return;

    final includeMessage = (message.role == OllamaMessageRole.user ? 1 : 0);

    final stayedMessages = _messages.sublist(0, messageIndex + includeMessage);
    final removeMessages = _messages.sublist(messageIndex + includeMessage);

    _messages = stayedMessages;
    notifyListeners();

    await _databaseService.deleteMessages(removeMessages);

    // Reinitialize the chat stream with the messages in the chat
    await _initializeChatStream(associatedChat);
  }

  Future<void> retryLastPrompt() async {
    if (_messages.isEmpty) return;

    final associatedChat = currentChat!;

    // Drop everything back to the last user turn. A failed turn can leave
    // several messages behind — a tool-call assistant turn plus one message
    // per tool result — and replaying with those still attached makes the
    // model answer the stale tool output instead of retrying the prompt.
    final discarded = <OllamaMessage>[];
    while (_messages.isNotEmpty &&
        _messages.last.role != OllamaMessageRole.user) {
      discarded.add(_messages.removeLast());
    }
    if (discarded.isNotEmpty) {
      await _databaseService.deleteMessages(discarded);
    }

    // Reinitialize the chat stream with the messages in the chat
    await _initializeChatStream(associatedChat);

    notifyListeners();
  }

  Future<void> updateMessage(
    OllamaMessage message, {
    String? newContent,
  }) async {
    message.content = newContent ?? message.content;
    notifyListeners();

    await _databaseService.updateMessage(message, newContent: newContent);
  }

  Future<void> deleteMessage(OllamaMessage message) async {
    await _databaseService.deleteMessage(message.id);

    // If the message is in the chat, remove it from the chat
    if (_messages.remove(message)) {
      notifyListeners();
    }
  }

  void cancelCurrentStreaming() {
    _activeChatStreams.remove(currentChat?.id);
    notifyListeners();
  }

  void _moveCurrentChatToTop() {
    if (_currentChatIndex == 0) return;

    final chat = _chats.removeAt(_currentChatIndex);
    _chats.insert(0, chat);
    _currentChatIndex = 0;
  }

  Future<List<OllamaModel>> fetchAvailableModels() async {
    final models = await _registry.listAllModels();
    _rememberToolSupport(models);
    return models;
  }

  // ============================================================
  // Export / Import
  // ============================================================

  /// Serialise [chat] (defaulting to the current chat) into a Markdown or
  /// text export. Returns null when there is no chat to export.
  Future<String?> exportChat({
    OllamaChat? chat,
    required ChatExportFormat format,
  }) async {
    final target = chat ?? currentChat;
    if (target == null) return null;

    final messages = await _databaseService.getMessages(target.id);
    final service = ChatExportService();
    switch (format) {
      case ChatExportFormat.markdown:
        return service.exportToMarkdown(target, messages);
      case ChatExportFormat.text:
        return service.exportToText(target, messages);
    }
  }

  /// Restore a chat from an exported Markdown/text string. Creates a fresh
  /// chat row and inserts every message under it (the import always mints a
  /// new chat ID so we can never collide with an existing chat). On success
  /// the imported chat is opened.
  Future<OllamaChat> importChatFromString(String content) async {
    final parsed = ChatExportService().parseImport(content);

    // Step 1 — create the chat row with the imported model/provider.
    final chat = await _databaseService.createChat(
      parsed.chat.model,
      provider: parsed.chat.provider,
    );
    // Step 2 — patch title/system prompt/options onto the new row.
    await _databaseService.updateChat(
      chat,
      newTitle: parsed.chat.title,
      newSystemPrompt: parsed.chat.systemPrompt,
      newOptions: parsed.chat.options,
    );
    // Step 3 — insert messages in order.
    for (final message in parsed.messages) {
      await _databaseService.addMessage(message, chat: chat);
    }
    // Step 4 — surface the imported chat in the sidebar and open it.
    final refreshed = (await _databaseService.getChat(chat.id))!;
    _chats.insert(0, refreshed);
    _currentChatIndex = 0;
    _messages = parsed.messages.toList();
    notifyListeners();
    return refreshed;
  }

  void _bindOllamaServerAddress() {
    final settingsBox = Hive.box('settings');
    _registry.ollama.baseUrl = settingsBox.get('serverAddress');
    _registry.ollama.backupUrl = settingsBox.get('serverAddressBackup');
    _registry.ollama.useBackup = settingsBox.get('serverUseBackup', defaultValue: true) as bool;

    settingsBox.listenable(keys: ["serverAddress", "serverAddressBackup", "serverUseBackup"]).addListener(() {
      _registry.ollama.baseUrl = settingsBox.get('serverAddress');
      _registry.ollama.backupUrl = settingsBox.get('serverAddressBackup');
      _registry.ollama.useBackup = settingsBox.get('serverUseBackup', defaultValue: true) as bool;

      // This will update empty chat state to dismiss "Tap to configure server address" message
      notifyListeners();
    });
  }

  Future<void> generateTitleForCurrentChat() async {
    final associatedChat = currentChat;
    final message = _messages.firstOrNull;
    if (associatedChat == null || message == null) return;

    // Create a temp chat with necessary system prompt
    final chat = OllamaChat(
      model: associatedChat.model,
      systemPrompt: GenerateTitleConstants.systemPrompt,
      provider: associatedChat.provider,
    );

    // Generate a title for the message
    final service = _registry.forChat(chat);
    final stream = service.generateStream(
      GenerateTitleConstants.prompt + message.content,
      chat: chat,
    );

    var title = "";
    try {
      await for (final titleMessage in stream) {
        // Ignore empty initial messages, preventing empty title
        if (title.isEmpty && titleMessage.content.isEmpty) {
          continue;
        }

        title += titleMessage.content;

        // If <think> tag exists, do not stream chat title
        if (title.startsWith("<think>")) {
          await updateChat(associatedChat, newTitle: "Thinking for a title...");
        } else {
          await updateChat(associatedChat, newTitle: title);
        }
      }
    } catch (_) {
      // Title generation is best-effort; a rate-limit or transient error
      // shouldn't surface as an unhandled exception. The user already sees
      // any chat-stream error via _chatErrors.
      return;
    }

    // Remove <think> tag and its content
    if (title.startsWith("<think>")) {
      title = title.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    }

    // Save the title as the chat title
    await updateChat(associatedChat, newTitle: title.trim());
  }
}
