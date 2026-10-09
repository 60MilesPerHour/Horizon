import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image_picker/image_picker.dart';

import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/attachment.dart';
import 'package:horizon/Models/chat_preset.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/model_capabilities.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/hermes_commands.dart';
import 'package:horizon/Services/services.dart';

class ChatPageViewModel extends ChangeNotifier {
  final ChatProvider _chatProvider;
  final PermissionService _permissionService;
  final ImageService _imageService;
  final AttachmentService _attachmentService;
  final ChatServiceRegistry _registry;

  ChatPageViewModel({
    required ChatProvider chatProvider,
    required PermissionService permissionService,
    required ImageService imageService,
    required AttachmentService attachmentService,
    required ChatServiceRegistry registry,
  })  : _chatProvider = chatProvider,
        _permissionService = permissionService,
        _imageService = imageService,
        _attachmentService = attachmentService,
        _registry = registry {
    _initialize();
  }

  // ============================================================
  // Page State
  // ============================================================

  /// The selected model for new chats
  OllamaModel? _selectedModel;
  OllamaModel? get selectedModel => _selectedModel;

  /// The list of chat presets
  List<ChatPreset> _presets = ChatPresets.randomPresets;
  List<ChatPreset> get presets => _presets;

  /// The text field controller
  final TextEditingController textFieldController = TextEditingController();

  /// Whether the text field has text
  bool get hasText => textFieldController.text.trim().isNotEmpty;

  /// The app lifecycle listener for cleanup
  late final AppLifecycleListener _appLifecycleListener;

  /// The Hive settings subscription
  late final StreamSubscription _settingsSubscription;

  bool get isServerConfigured {
    if (Hive.box('settings').get('serverAddress') != null) return true;
    return _registry.all.any((s) => s.providerId != 'ollama' && s.isConfigured);
  }

  // ============================================================
  // Initialization
  // ============================================================

  void _initialize() {
    // Listen to ChatProvider changes and forward notifications
    _chatProvider.addListener(_onChatProviderChanged);

    // Listen to text field changes to update UI (e.g., send button visibility)
    textFieldController.addListener(_onTextFieldChanged);

    // If the server address changes, reset the selected model
    _settingsSubscription = Hive.box('settings').watch(key: 'serverAddress').listen((event) {
      _selectedModel = null;
      notifyListeners();
    });

    // Listen for app exit to delete staged-but-unsent files
    _appLifecycleListener = AppLifecycleListener(onExitRequested: () async {
      await _imageService.deleteImages(imageFiles);
      await _attachmentService.deleteAll(attachments);
      return AppExitResponse.exit;
    });
  }

  void _onChatProviderChanged() {
    notifyListeners();
  }

  void _onTextFieldChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _chatProvider.removeListener(_onChatProviderChanged);
    textFieldController.removeListener(_onTextFieldChanged);
    textFieldController.dispose();
    _appLifecycleListener.dispose();
    _settingsSubscription.cancel();
    super.dispose();
  }

  // ============================================================
  // ChatProvider State (Proxied)
  // ============================================================

  /// The list of messages in the current chat
  List<OllamaMessage> get messages => _chatProvider.messages;

  /// The current chat
  OllamaChat? get currentChat => _chatProvider.currentChat;

  /// Whether the current chat is streaming a response
  bool get isStreaming => _chatProvider.isCurrentChatStreaming;

  /// Notifier for in-flight streaming content. Updated by the typewriter timer
  /// without triggering a full page rebuild. Listen to this in the streaming bubble only.
  ValueNotifier<String> get streamingContent => _chatProvider.streamingContent;

  /// Whether the current chat is thinking (waiting for response)
  bool get isThinking => _chatProvider.isCurrentChatThinking;

  /// Whether the current chat is running a tool. Drives the activity label on
  /// the awaiting-reply indicator.
  bool get isSearching => _chatProvider.isCurrentChatSearching;

  /// What the current chat is doing out-of-band ("Reading example.com…"), or
  /// null when it's just generating.
  String? get activityLabel => _chatProvider.currentChatActivity;

  /// The awaiting-reply label. An agent spends most of a slow turn
  /// reasoning, which its API doesn't stream, so say that rather than
  /// "Generating" over a reply that hasn't started.
  String get statusLabel => activityLabel ?? (isHermes ? 'Thinking' : 'Generating');

  /// The current chat error, if any
  OllamaException? get currentError => _chatProvider.currentChatError;

  /// A command the Hermes agent is waiting for a yes or no on, if any.
  HermesApproval? get pendingApproval => _chatProvider.currentChatApproval;

  /// Answers [pendingApproval].
  Future<void> respondToApproval(String choice) => _chatProvider.respondToApproval(choice);

  // ============================================================
  // Hermes Commands
  // ============================================================

  HermesService get _hermes => _registry.hermes;

  /// Whether what's typed goes to a Hermes agent: the open chat's, or the
  /// model picked for the next one.
  bool get isHermes => (currentChat?.provider ?? _selectedModel?.provider) == HermesService.id;

  /// Commands matching what's being typed, for the menu over the composer.
  List<HermesCommand> get commandSuggestions =>
      isHermes ? HermesCommand.matching(textFieldController.text) : const [];

  /// Fills the composer with [command], ready for its argument or Enter.
  void pickCommand(HermesCommand command) {
    final text = '/${command.name}${command.args == null ? '' : ' '}';
    textFieldController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<HermesCommandResult> _runCommand(HermesCommand command, String arg) async {
    final chat = currentChat;
    switch (command.name) {
      case 'help':
        return HermesCommandResult('Commands', detail: [
          for (final c in HermesCommand.all)
            '/${c.name}${c.args == null ? '' : ' ${c.args}'}\n    ${c.description}',
        ].join('\n'));

      case 'new':
        if (chat == null) return const HermesCommandResult('This is already a fresh chat.');
        _selectedModel = OllamaModel.cloud(
          provider: HermesService.id,
          id: chat.model,
          capabilities: const ModelCapabilities(completion: true),
        );
        _chatProvider.destinationChatSelected(0);
        return const HermesCommandResult('New chat with the agent.');

      case 'reset':
        if (chat == null) return const HermesCommandResult('Nothing to forget yet.');
        final turns = messages.where((m) => m.role == OllamaMessageRole.user).length;
        await _hermes.resetSession(chat.id, turns);
        return const HermesCommandResult('The agent starts this chat fresh from your next message.');

      case 'think':
        if (chat == null) {
          return const HermesCommandResult('Send a message first — /think applies to a chat. '
              'The default for new chats is in Settings → Hermes Agent.');
        }
        if (arg.isEmpty) {
          final level = HermesService.thinkingLabel(_hermes.thinkingFor(chat.id));
          final own = _hermes.hasChatThinking(chat.id) ? 'set for this chat' : 'from Settings';
          return HermesCommandResult('Thinking: $level ($own).');
        }
        final level = HermesCommand.thinkingLevel(arg);
        if (level == null) return HermesCommandResult('No thinking level "$arg". Try ${command.args}.');
        await _hermes.setChatThinking(chat.id, arg.toLowerCase() == 'default' ? null : level);
        return HermesCommandResult('Thinking in this chat: ${HermesService.thinkingLabel(_hermes.thinkingFor(chat.id))}.');

      case 'stop':
        if (!isStreaming) return const HermesCommandResult('The agent isn\'t doing anything.');
        cancelStreaming();
        return const HermesCommandResult('Stopped.');

      case 'status':
        final lines = <String>[
          'Agent: ${_hermes.endpoint.primary.isEmpty ? 'not set' : _hermes.endpoint.primary}',
        ];
        if (chat == null) {
          lines.add('No chat yet — the session starts with your first message.');
        } else {
          final session = _hermes.sessionOf(chat.id);
          lines
            ..add('Session: ${session?.id ?? 'starts with your next message'}')
            ..add('Turns the agent has seen: ${session?.turns ?? 0}')
            ..add('Thinking: ${HermesService.thinkingLabel(_hermes.thinkingFor(chat.id))}');
          final last = _hermes.lastRun(chat.id);
          if (last != null) {
            final secs = (last.duration.inMilliseconds / 1000).toStringAsFixed(1);
            lines.add('Last turn: ${secs}s, ${last.inputTokens} tokens in '
                '(${last.cachedTokens} cached), ${last.outputTokens} out');
          }
        }
        return HermesCommandResult('Status', detail: lines.join('\n'));

      case 'tools':
        try {
          final sets = await _hermes.listToolsets();
          final on = sets.where((t) => t.enabled).toList();
          return HermesCommandResult('${on.length} of ${sets.length} toolsets on', detail: [
            for (final t in sets)
              '${t.enabled ? '●' : '○'} ${t.name} (${t.tools})${t.description.isEmpty ? '' : '\n    ${t.description}'}',
          ].join('\n'));
        } on OllamaException catch (e) {
          return HermesCommandResult(e.message);
        }
    }
    return HermesCommandResult('Unknown command /${command.name}.');
  }

  // ============================================================
  // ChatProvider Actions (Delegated)
  // ============================================================

  /// Cancels the current streaming response
  void cancelStreaming() {
    _chatProvider.cancelCurrentStreaming();
  }

  /// Retries the last prompt
  Future<void> retryLastPrompt() async {
    await _chatProvider.retryLastPrompt();
  }

  /// Fetches available models from the server
  Future<List<OllamaModel>> fetchAvailableModels() async {
    return await _chatProvider.fetchAvailableModels();
  }

  // ============================================================
  // Export / Import (Delegated)
  // ============================================================

  /// Returns true when there's something exportable on screen — used to gate
  /// the export menu entry.
  bool get canExportCurrentChat =>
      _chatProvider.currentChat != null && _chatProvider.messages.isNotEmpty;

  /// Builds the serialised export of the current chat. Caller is responsible
  /// for actually writing/sharing the file.
  Future<String?> exportCurrentChat(ChatExportFormat format) {
    return _chatProvider.exportChat(format: format);
  }

  /// Filename hint for the current chat in the given format. Sanitised so
  /// it's safe to drop on every desktop / mobile filesystem we ship to.
  String exportFilename(ChatExportFormat format) {
    final raw = _chatProvider.currentChat?.title ?? 'horizon-chat';
    final safe = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '-')
        .trim();
    final base = safe.isEmpty ? 'horizon-chat' : safe;
    return '$base.${format.extension}';
  }

  /// Restore a chat from an exported file string. Throws if the input can't
  /// be parsed at all (the importer is permissive, so this mostly means the
  /// file is empty / no recognisable messages).
  Future<OllamaChat> importChatFromString(String content) {
    return _chatProvider.importChatFromString(content);
  }

  // ============================================================
  // Model Selection
  // ============================================================

  /// Sets the selected model
  void setSelectedModel(OllamaModel? model) {
    _selectedModel = model;
    notifyListeners();
  }

  // ============================================================
  // Text Field
  // ============================================================

  /// Sets the text field value (e.g., for presets)
  void setTextFieldValue(String value) {
    textFieldController.text = value;
  }

  /// Gets and clears the text field value (for sending)
  String _takeTextFieldValue() {
    final value = textFieldController.text;
    textFieldController.clear();
    return value;
  }

  // ============================================================
  // Image Attachments
  // ============================================================

  final List<File> _imageFiles = [];

  /// The list of attached image files
  List<File> get imageFiles => List.unmodifiable(_imageFiles);

  /// Whether there are any image attachments
  bool get hasImageAttachments => _imageFiles.isNotEmpty;

  /// Handles image picking and compression
  Future<void> pickImages({
    VoidCallback? onPermissionDenied,
    int quality = 10,
  }) async {
    // Check permissions
    final hasPermission = await _permissionService.requestPhotoPermission(
      onDenied: onPermissionDenied,
    );
    if (!hasPermission) return;

    // Pick images
    final picker = ImagePicker();
    final pickedImage = await picker.pickImage(
      source: ImageSource.gallery,
    );
    // await _picker.pickMultiImage(limit: maxImages);

    if (pickedImage == null) return;

    // Compress and save
    final compressedFile = await _imageService.compressAndSave(
      pickedImage.path,
      quality: quality,
    );

    if (compressedFile != null) {
      _imageFiles.add(compressedFile);
      notifyListeners();
    }
  }

  /// Deletes a single image and removes it from the list
  Future<void> removeImage(File imageFile) async {
    await _imageService.deleteImage(imageFile);
    _imageFiles.remove(imageFile);
    notifyListeners();
  }

  /// Gets and clears the current images (for sending)
  List<File> _takeImages() {
    final images = _imageFiles.toList();
    _imageFiles.clear();
    return images;
  }

  // ============================================================
  // Document Attachments
  // ============================================================

  final List<Attachment> _attachments = [];

  /// Documents staged for the next message.
  List<Attachment> get attachments => List.unmodifiable(_attachments);

  bool get hasAttachments => _attachments.isNotEmpty;

  /// Whether anything at all is staged — used to let an attachment-only
  /// message send with no typed prompt.
  bool get hasStagedFiles => _imageFiles.isNotEmpty || _attachments.isNotEmpty;

  /// Opens the document picker and stages whatever parsed successfully.
  /// Per-file failures are reported through [onError] rather than aborting.
  Future<void> pickAttachments({
    void Function(String message)? onError,
  }) async {
    final picked = await _attachmentService.pickFiles(onError: onError);
    if (picked.isEmpty) return;
    _attachments.addAll(picked);
    notifyListeners();
  }

  Future<void> removeAttachment(Attachment attachment) async {
    _attachments.remove(attachment);
    notifyListeners();
    await _attachmentService.delete(attachment);
  }

  List<Attachment> _takeAttachments() {
    final taken = _attachments.toList();
    _attachments.clear();
    return taken;
  }

  // ============================================================
  // Operations
  // ============================================================

  /// Handles sending a message
  /// Returns true if the message was sent successfully
  Future<bool> sendMessage({
    required Future<void> Function() onModelSelectionRequired,
    required void Function() onServerNotConfigured,
    void Function(HermesCommandResult result)? onCommand,
  }) async {
    // A Hermes command is answered here and never sent — including /stop,
    // which is why this comes before the streaming guard.
    final command = isHermes ? HermesCommand.parse(textFieldController.text) : null;
    if (command != null && !hasStagedFiles) {
      _takeTextFieldValue();
      notifyListeners();
      final result = await _runCommand(command.$1, command.$2);
      notifyListeners();
      onCommand?.call(result);
      return false;
    }
    // Enter on a half-typed command that can only mean one thing finishes it
    // instead of sending "/th" to the agent.
    final candidates = command == null ? commandSuggestions : const <HermesCommand>[];
    if (candidates.length == 1 && textFieldController.text.length > 1) {
      pickCommand(candidates.single);
      return false;
    }

    // Early return if nothing to send or currently streaming. A message with
    // no text but a staged file is still a message — "summarise this" is
    // implied, and OllamaMessage.promptContent says so explicitly.
    if ((!hasText && !hasStagedFiles) || isStreaming) {
      return false;
    }

    // Check if server is configured
    if (!isServerConfigured) {
      onServerNotConfigured();
      return false;
    }

    // If no current chat, need to create one
    if (_chatProvider.currentChat == null) {
      // If no model selected, request selection
      if (_selectedModel == null) {
        await onModelSelectionRequired();
      }

      // If still no model after selection, abort
      if (_selectedModel == null) {
        return false;
      }

      // Take the prompt and images and refresh the presets BEFORE the chat
      // exists — we'll seed the new chat with this message in a single
      // notify so the user never sees an empty "No messages yet" frame
      // between createChat and sendPrompt.
      final prompt = _takeTextFieldValue();
      final images = _takeImages();
      final attachments = _takeAttachments();
      _presets = ChatPresets.randomPresets;
      notifyListeners();

      await _chatProvider.createNewChatAndSendPrompt(
        _selectedModel!,
        prompt,
        images: images,
        attachments: attachments,
      );

      // Generate title for the new chat (best-effort, fires in parallel
      // with the response stream).
      await _chatProvider.generateTitleForCurrentChat();
    } else {
      // Get and clear the prompt, images and attachments
      final prompt = _takeTextFieldValue();
      final images = _takeImages();
      final attachments = _takeAttachments();

      // Notify listeners (text field is cleared)
      notifyListeners();

      // Send the prompt
      await _chatProvider.sendPrompt(
        prompt,
        images: images,
        attachments: attachments,
      );
    }

    return true;
  }
}
