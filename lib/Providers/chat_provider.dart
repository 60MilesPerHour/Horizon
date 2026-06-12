import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:notification_centre/notification_centre.dart';

import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/chat_configure_arguments.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Services/chat_export_service.dart';
import 'package:horizon/Services/chat_service_registry.dart';
import 'package:horizon/Services/database_service.dart';
import 'package:horizon/Services/generation_keepalive.dart';
import 'package:horizon/Services/web_search_service.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

class ChatProvider extends ChangeNotifier {
  final ChatServiceRegistry _registry;
  final DatabaseService _databaseService;
  final WebSearchService _webSearch;

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

  /// Chats currently in the web-search fetch phase. Drives the "Searching…"
  /// indicator, distinct from the normal "Generating" thinking state.
  final Set<String> _searchingChats = {};

  bool get isCurrentChatSearching =>
      currentChat != null && _searchingChats.contains(currentChat?.id);

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
  })  : _registry = registry,
        _databaseService = databaseService,
        _webSearch = webSearch {
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

  /// Atomic "create a new chat AND send the first prompt" path used when the
  /// user fires off a prompt with no current chat selected. Folds the chat
  /// creation, message seeding, and stream init into a single notify cycle so
  /// the UI never paints an intermediate state — neither the previous chat's
  /// messages nor an empty "No messages yet" placeholder.
  Future<void> createNewChatAndSendPrompt(
    OllamaModel model,
    String text, {
    List<File>? images,
  }) async {
    final chat = await _createNewChatInternal(model, firstPrompt: null);

    final prompt = OllamaMessage(
      text.trim(),
      images: images,
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

    await _databaseService.deleteChat(chat.id);
  }

  Future<void> sendPrompt(String text, {List<File>? images}) async {
    // Save the chat where the prompt was sent
    final associatedChat = currentChat!;

    // Create a user prompt message and add it to the chat
    final prompt = OllamaMessage(
      text.trim(),
      images: images,
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
      // Build the outgoing message list and effective system prompt. When web
      // search is on, this runs a decision pass and (only if the model asks)
      // a search, surfacing the "Searching…" state — see _prepareSend.
      final (outgoing, effectiveChat) = await _prepareSend(associatedChat);
      ollamaMessage =
          await _streamOllamaMessage(associatedChat, outgoing, effectiveChat);
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
      _searchingChats.remove(associatedChat.id);
      await GenerationKeepalive.release();
      notifyListeners();
    }

    // Save the Ollama message to the database
    if (ollamaMessage != null) {
      await _databaseService.addMessage(ollamaMessage, chat: associatedChat);
    }
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
    OllamaChat effectiveChat,
  ) async {
    if (_messages.isEmpty) return null;

    final service = _registry.forChat(effectiveChat);
    final stream = service.chatStream(outgoing, chat: effectiveChat);

    OllamaMessage? streamingMessage;
    OllamaMessage? receivedMessage;

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
        final n = (s.length ~/ 4).clamp(2, 160);
        streamingMessage!.content += s.substring(0, n);
        if (n < s.length) pending.write(s.substring(n));
        // Update only the ValueNotifier — avoids a full-page rebuild.
        streamingContent.value = streamingMessage!.content;
      });
    }

    void flushAll() {
      typewriter?.cancel();
      typewriter = null;
      if (pending.isNotEmpty && streamingMessage != null) {
        streamingMessage!.content += pending.toString();
        pending.clear();
        streamingContent.value = streamingMessage!.content;
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

    streamingMessage?.createdAt = DateTime.now();
    notifyListeners();

    return streamingMessage;
  }

  /// Prepares the actual send: returns the message list to stream and the chat
  /// (with any system-prompt addons) to send it under.
  ///
  /// Web search, when enabled, runs a two-step client-side loop:
  ///   1. A cheap *decision pass* asks the model whether the latest message
  ///      needs fresh external info. The model replies with a `<search>` query
  ///      or `<nosearch>` — so we don't search every message.
  ///   2. Only if it asked, we fetch results (surfacing "Searching…") and
  ///      append them to the latest user turn for the answer pass.
  /// The web-search and artifacts system-prompt addons are appended to the
  /// chat's own system prompt regardless of what that prompt says.
  Future<(List<OllamaMessage>, OllamaChat)> _prepareSend(
    OllamaChat chat,
  ) async {
    var outgoing = _messages;
    var systemAddon = '';

    if (chat.options.webSearch && _webSearch.isConfigured) {
      systemAddon += WebSearchConstants.systemPromptAddon;
      String? context;
      try {
        context = await _runWebSearchPrePass(chat);
      } catch (_) {
        context = null; // best-effort; fall back to a normal send
      }
      if (context != null) {
        outgoing = _appendToLastUser(_messages, context);
      }
    }

    if (chat.options.artifacts) {
      systemAddon += ArtifactConstants.systemPromptAddon;
    }

    final effectiveChat =
        systemAddon.isEmpty ? chat : _withSystemAddon(chat, systemAddon);
    return (outgoing, effectiveChat);
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

    _searchingChats.add(chat.id);
    notifyListeners();
    try {
      return await _webSearch.buildContext(query);
    } finally {
      _searchingChats.remove(chat.id);
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

    if (_messages.last.role == OllamaMessageRole.assistant) {
      final message = _messages.removeLast();
      await _databaseService.deleteMessage(message.id);
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
    return await _registry.listAllModels();
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
