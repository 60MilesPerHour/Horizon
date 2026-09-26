import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Services/voice/stt/speech_input_service.dart';
import 'package:horizon/Services/voice/voice_session_controller.dart';
import 'package:horizon/Services/voice/wake/wake_word_listener.dart';
import 'package:horizon/Widgets/horizon_brand.dart';
import 'package:horizon/Widgets/model_selection_bottom_sheet.dart';

/// Full-screen hands-free voice mode.
///
/// Also what opens when Horizon is the device's digital assistant, so it has
/// to be usable from a cold launch with one tap and no reading: big button,
/// large caption text, and no navigation required to get a spoken answer.
class AssistantPage extends StatefulWidget {
  /// True when launched by the system assist gesture rather than from inside
  /// the app, in which case listening starts immediately.
  final bool autoStart;

  const AssistantPage({super.key, this.autoStart = false});

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  VoiceSessionController? _controller;
  String? _setupError;
  bool _preparing = true;

  /// Typed input is opt-in: showing a keyboard by default would undercut the
  /// point of a one-tap voice screen.
  bool _showComposer = false;
  final _composerController = TextEditingController();
  final _composerFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    // Horizon Voice needs the microphone the wake word is holding, and has
    // to have it before the first turn opens it.
    await _wakeWord.pause(_holdKey);
    _lifecycle; // start observing
    if (!mounted) return;
    final chatProvider = context.read<ChatProvider>();
    final settings = Hive.box('settings');

    // An existing assistant chat is already pinned to a model, so listing
    // models would just add a network round-trip to the assist gesture — the
    // one path where every millisecond is visible. Only resolve a model when
    // there's no chat yet.
    OllamaModel? model;
    if (chatProvider.assistantChatModel == null) {
      final preferredName = settings.get('assistant_model') as String?;
      try {
        final models = await chatProvider.fetchAvailableModels();
        if (models.isNotEmpty) {
          model = models.firstWhere(
            (m) => m.name == preferredName,
            orElse: () => models.first,
          );
        }
      } catch (e) {
        _fail('Could not reach any model provider.\n\n$e');
        return;
      }
    }

    final chat = await chatProvider.ensureAssistantChat(model: model);
    if (chat == null) {
      _fail(
        'No model is available yet. Open Horizon, set your Ollama server '
        'address or an OpenRouter key, then try again.',
      );
      return;
    }

    await _applyVoiceDefaults(chatProvider, chat);

    if (!mounted) return;
    final synthesis = context.read<SpeechSynthesisService>();
    final controller = VoiceSessionController(
      chatProvider: chatProvider,
      recognition: context.read<SpeechInputService>(),
      synthesis: synthesis,
    )
      ..speakReplies =
          settings.get('voice_speak_replies', defaultValue: true) as bool
      ..interruptByTalking = settings.get(
        'voice_interrupt_by_talking',
        defaultValue: false,
      ) as bool;

    controller.addListener(_onControllerChanged);
    setState(() {
      _controller = controller;
      _preparing = false;
    });

    // Warm the recogniser now rather than on the first tap: initialise() is a
    // platform round-trip plus a permission check, and paying for it when the
    // user taps is exactly the delay they notice.
    unawaited(context.read<SpeechInputService>().device.prewarm());
    unawaited(context.read<SpeechInputService>().prewarm());

    // Always, not only from the assist gesture: opening voice mode *is* the
    // request to talk, and a screen that then waits for a second tap on a
    // mic button is the difference between a conversation and a form.
    await controller.startListening();
  }

  /// How the assistant should talk when it is being listened to rather than
  /// read. Without it, a chat model answers a spoken question with a
  /// chat-length reply — measured at 450-570 tokens a turn, most of a minute
  /// of speech, with headings and bullets the synthesiser reads out as noise.
  static const String _voiceSystemPrompt =
      "You are Horizon, a voice assistant. Everything you write is read aloud, "
      'so talk the way a person does in conversation: answer in one to three '
      'short sentences, lead with the answer, and offer to go deeper rather '
      'than going deeper unasked. No markdown, lists, headings, code blocks, '
      'emoji or URLs. Spell out numbers and symbols the way they are said. If '
      'the question was unclear or sounds misheard, ask one short question '
      'back instead of guessing.';

  /// A later default that was rolled back. A chat that picked it up is put
  /// back on [_voiceSystemPrompt]; anything the user wrote is left alone.
  static const String _rolledBackVoiceSystemPrompt =
      "You are Horizon, a voice assistant. Everything you write is read aloud, "
      'so talk the way a person does in conversation and lead with the answer. '
      'Keep quick answers short — a sentence or three. But there is no length '
      'limit: when the user asks for something long — a story, a detailed '
      'explanation, step-by-step instructions — give them all of it; they can '
      'interrupt you whenever they like. No markdown, lists, headings, code '
      'blocks, emoji or URLs. Spell out numbers and symbols the way they are '
      'said. If the question was unclear or sounds misheard, ask one short '
      'question back instead of guessing.';

  /// Voice defaults for the assistant chat, applied only where the chat has
  /// no setting of its own — a prompt or think choice made on purpose in the
  /// chat view is left alone.
  ///
  /// Thinking off because it is silence: a reasoning model spends its first
  /// few hundred tokens where nothing can be spoken, and in voice mode that
  /// reads as the assistant having frozen.
  Future<void> _applyVoiceDefaults(ChatProvider provider, OllamaChat chat) async {
    final current = (chat.systemPrompt ?? '').trim();
    final needsPrompt = current.isEmpty || current == _rolledBackVoiceSystemPrompt;
    final needsThink = chat.options.think == null;
    // The chat was called "Assistant" before the rename; only that exact
    // default is changed, never a title the user chose.
    final needsTitle = chat.title == 'Assistant';
    if (!needsPrompt && !needsThink && !needsTitle) return;
    final options = OllamaChatOptions.fromJson(chat.options.toJson());
    if (needsThink) options.think = false;
    await provider.updateChat(
      chat,
      newTitle: needsTitle ? 'Horizon Voice' : null,
      newSystemPrompt: needsPrompt ? _voiceSystemPrompt : null,
      newOptions: needsThink ? options : null,
    );
  }

  Future<void> _changeModel() async {
    final chatProvider = context.read<ChatProvider>();
    final selected = await showModelSelectionBottomSheet(
      context: context,
      title: 'Horizon Voice model',
      currentModelName: chatProvider.currentChat?.model,
    );
    if (selected == null) return;

    // Repins the assistant chat AND the stored preference, so the choice
    // survives the chat being deleted and recreated.
    await chatProvider.updateCurrentChat(
      newModel: selected.name,
      newProvider: selected.provider,
    );
    await Hive.box('settings').put('assistant_model', selected.name);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _setupError = message;
      _preparing = false;
    });
  }

  VoicePhase? _shownPhase;

  /// The backdrop is painted above the body's own ListenableBuilder, so it
  /// only needs a rebuild when the phase — and with it the colour — changes.
  void _onControllerChanged() {
    final phase = _controller?.phase;
    if (phase == _shownPhase || !mounted) return;
    setState(() => _shownPhase = phase);
  }

  late final WakeWordListener _wakeWord = context.read<WakeWordListener>();

  /// This page's own hold on the wake word. A shared key let a replaced
  /// page's dispose clear the hold of the page that replaced it, and the
  /// wake word reopened its microphone mid-conversation.
  late final String _holdKey = 'voice#${identityHashCode(this)}';

  /// Gives the microphone back once this page's own capture has had time to
  /// close — reopening it on top of a still-closing call-mode capture could
  /// leave the wake word's recorder routed to silence.
  Future<void> _releaseWakeWord() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _wakeWord.resume(_holdKey);
  }

  /// Leaving the app ends the conversation and gives the microphone back to
  /// the wake word. Otherwise pressing home mid-conversation left this page
  /// holding the microphone in the background, and "Hey Horizon" stayed
  /// deaf until the user came back and closed it.
  ///
  /// Only once the app has *stayed* off screen, though. Opening Horizon from
  /// the wake word goes through the assistant route, and Android briefly puts
  /// the assistant session's window over the app and then removes it — a
  /// hide lasting a fraction of a second. Ending the session on that ended
  /// every wake-word conversation before the first word, and nothing started
  /// listening again when the page came back.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onHide: () {
      _leaveTimer?.cancel();
      _leaveTimer = Timer(const Duration(milliseconds: 1500), () async {
        if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
        await _controller?.stopSession();
        await _releaseWakeWord();
      });
    },
    onShow: () {
      _leaveTimer?.cancel();
      _wakeWord.pause(_holdKey);
    },
  );
  Timer? _leaveTimer;

  @override
  void dispose() {
    _leaveTimer?.cancel();
    _lifecycle.dispose();
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    unawaited(_releaseWakeWord());
    _composerController.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _toggleComposer() {
    setState(() => _showComposer = !_showComposer);
    if (_showComposer) {
      _composerFocus.requestFocus();
    } else {
      _composerFocus.unfocus();
    }
  }

  Future<void> _submitTyped() async {
    final text = _composerController.text;
    if (text.trim().isEmpty) return;
    _composerController.clear();
    await _controller?.sendText(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final phase = _controller?.phase ?? VoicePhase.idle;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: _VoiceBackdrop.forPhase(phase, theme.brightness),
      ),
      child: Theme(
        data: theme.copyWith(
          scaffoldBackgroundColor: Colors.transparent,
          appBarTheme: theme.appBarTheme.copyWith(
            backgroundColor: Colors.transparent,
            foregroundColor: _VoiceInk.of(theme.brightness).ink,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            systemOverlayStyle: theme.brightness == Brightness.light
                ? SystemUiOverlayStyle.dark
                : SystemUiOverlayStyle.light,
          ),
          iconTheme: IconThemeData(color: _VoiceInk.of(theme.brightness).ink),
        ),
        child: _scaffold(context, theme),
      ),
    );
  }

  Widget _scaffold(BuildContext context, ThemeData theme) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        // The product name, with the model underneath as its own dropdown:
        // which model is about to answer still matters, but it's a detail of
        // Horizon Voice rather than the name of the screen.
        centerTitle: true,
        title: _VoiceTitle(
          model: context.watch<ChatProvider>().currentChat?.model,
          ink: _VoiceInk.of(theme.brightness),
          onChangeModel: _controller == null ? null : _changeModel,
        ),
        actions: [
          if (_controller != null)
            IconButton(
              tooltip: _showComposer ? 'Hide keyboard' : 'Type instead',
              icon: Icon(_showComposer
                  ? Icons.keyboard_hide_outlined
                  : Icons.keyboard_outlined),
              onPressed: _toggleComposer,
            ),
          if (_controller != null)
            IconButton(
              tooltip: _controller!.speakReplies
                  ? 'Mute spoken replies'
                  : 'Speak replies',
              icon: Icon(_controller!.speakReplies
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined),
              onPressed: () {
                setState(() {
                  _controller!.speakReplies = !_controller!.speakReplies;
                });
                Hive.box('settings')
                    .put('voice_speak_replies', _controller!.speakReplies);
              },
            ),
          IconButton(
            tooltip: 'Open this conversation',
            icon: const Icon(Icons.forum_outlined),
            onPressed: () => Navigator.of(context)
                .pushNamedAndRemoveUntil('/', (route) => false),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(theme)),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_preparing) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_setupError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mic_off_outlined,
                  size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              SelectableText(
                _setupError!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _setupError = null;
                    _preparing = true;
                  });
                  _prepare();
                },
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _controller!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          children: [
            Expanded(child: _buildTranscript(theme, controller)),
            if (_showComposer) _buildComposer(theme, controller),
            // Every element below the transcript has a fixed height. The mic
            // used to drift as the status text rewrapped between phases and
            // as the level meter appeared, which reads as the button moving
            // around under your thumb.
            SizedBox(
              height: 34,
              child: Center(child: _buildStatusLine(theme, controller)),
            ),
            SizedBox(
              height: 132,
              child: Center(
                child: VoiceOrb(
                  size: 72,
                  // Swells with your voice while listening; breathes otherwise.
                  levels: controller.phase == VoicePhase.listening ? controller.levels : null,
                  active: controller.phase == VoicePhase.listening ||
                      controller.phase == VoicePhase.speaking ||
                      controller.phase == VoicePhase.thinking,
                  onTap: controller.toggle,
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: controller.continuousMode &&
                      controller.phase != VoicePhase.idle
                  ? TextButton.icon(
                      onPressed: () async {
                        await controller.stopSession();
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('End'),
                    )
                  : null,
            ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }

  /// Caption type: big, heavy, tight — read at a glance from arm's length,
  /// the way lyrics are, rather than studied like a chat bubble.
  static TextStyle _lyric(ThemeData theme) =>
      (theme.textTheme.headlineMedium ?? const TextStyle()).copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w800,
        height: 1.22,
        letterSpacing: -0.6,
        color: _VoiceInk.of(theme.brightness).ink,
      );

  /// What the user said, sitting above the reply like the line just sung.
  /// The part the recogniser is still revising is fainter again: "trans-"
  /// really does become "transcription" under you, and in full ink that
  /// looks like a bug rather than the machine thinking.
  Widget _transcriptText(ThemeData theme, VoiceSessionController controller) {
    final ink = _VoiceInk.of(theme.brightness);
    final listening = controller.phase == VoicePhase.listening;
    final base = _lyric(theme).copyWith(
      fontSize: listening ? 30 : 22,
      color: listening ? ink.ink : ink.past,
    );
    final tail = controller.liveTail.trim();
    if (tail.isEmpty) return Text(controller.transcript, style: base);
    final committed = controller.liveCommitted.trim();
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          if (committed.isNotEmpty) TextSpan(text: '$committed '),
          TextSpan(
            text: tail,
            style: base.copyWith(color: ink.ink.withValues(alpha: 0.5)),
          ),
        ],
      ),
    );
  }

  /// The reply as karaoke: what has been spoken fades back, the sentence
  /// coming out of the speaker now is full white, and what is still to come
  /// waits in dark ink. With replies muted there is nothing to follow, so it
  /// is all simply white.
  Widget _replyText(ThemeData theme, VoiceSessionController controller) {
    final ink = _VoiceInk.of(theme.brightness);
    final style = _lyric(theme);
    final reply = controller.reply;
    final range = controller.speakReplies ? controller.speakingRange : null;
    if (range == null) {
      final waiting = controller.speakReplies &&
          controller.phase != VoicePhase.idle &&
          controller.phase != VoicePhase.error;
      return Text(reply,
          style: style.copyWith(color: waiting ? ink.upcoming : ink.ink));
    }
    final (start, end) = range;
    return Text.rich(TextSpan(style: style, children: [
      if (start > 0)
        TextSpan(text: reply.substring(0, start), style: style.copyWith(color: ink.past)),
      TextSpan(
        text: reply.substring(start, end),
        style: style.copyWith(
          color: HorizonBrand.accent(context),
          shadows: theme.brightness == Brightness.dark
              ? [Shadow(color: HorizonBrand.orange.withValues(alpha: .35), blurRadius: 20)]
              : null,
        ),
      ),
      if (end < reply.length)
        TextSpan(
          text: reply.substring(end),
          style: style.copyWith(color: ink.upcoming),
        ),
    ]));
  }

  /// Who said a line: small, above it, so a scrolled-back conversation
  /// still reads as one when the colours alone would leave it ambiguous.
  Widget _speaker(ThemeData theme, _VoiceInk ink, {required bool fromUser}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          fromUser ? 'YOU' : 'HORIZON',
          style: theme.textTheme.labelSmall?.copyWith(
            color: fromUser ? ink.chrome : HorizonBrand.accent(context),
            letterSpacing: 1.4,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  /// An earlier line of this session, in the "already sung" ink.
  Widget _pastLine(ThemeData theme, _VoiceInk ink, ({bool fromUser, String text}) line) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _speaker(theme, ink, fromUser: line.fromUser),
            Text(
              line.text,
              style: _lyric(theme).copyWith(
                fontSize: line.fromUser ? 20 : 22,
                fontWeight: line.fromUser ? FontWeight.w600 : FontWeight.w800,
                color: ink.past,
              ),
            ),
          ],
        ),
      );

  Widget _buildTranscript(ThemeData theme, VoiceSessionController controller) {
    final hasTranscript = controller.transcript.trim().isNotEmpty;
    final hasReply = controller.reply.trim().isNotEmpty;

    final ink = _VoiceInk.of(theme.brightness);
    final hasHistory = controller.history.isNotEmpty;
    if (!hasTranscript && !hasReply && controller.error == null && !hasHistory) {
      final listening = controller.phase == VoicePhase.listening;
      return Align(
        alignment: const Alignment(-1, -0.2),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Text(
            listening
                ? (controller.hearing ? 'Go ahead, I\'m listening.' : 'One moment…')
                : 'Tap to talk',
            style: _lyric(theme).copyWith(
              fontSize: 36,
              color: listening ? ink.ink : ink.past,
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
      // Full width, so the lines sit on the left like lyrics; a shrink-wrapped
      // column let short lines drift to the middle.
      child: SizedBox(
        width: double.infinity,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in controller.history) _pastLine(theme, ink, line),
          if (hasHistory && (hasTranscript || hasReply)) const SizedBox(height: 6),
          if (hasTranscript) _speaker(theme, ink, fromUser: true),
          if (hasTranscript) _transcriptText(theme, controller),
          if (hasTranscript && (hasReply || controller.error != null))
            const SizedBox(height: 18),
          if (hasReply && controller.error == null) _speaker(theme, ink, fromUser: false),
          if (controller.error != null)
            SelectableText(
              controller.error!,
              style: _lyric(theme).copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: ink.ink,
              ),
            )
          else if (hasReply)
            // Plain text, not Markdown: this is a caption for something being
            // spoken, and re-parsing Markdown on every streamed tick is the
            // one thing the chat view already learned not to do.
            _replyText(theme, controller),
        ],
      ),
      ),
    );
  }

  Widget _buildComposer(ThemeData theme, VoiceSessionController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: TextField(
        controller: _composerController,
        focusNode: _composerFocus,
        enabled: !controller.isBusy,
        minLines: 1,
        maxLines: 4,
        textInputAction: TextInputAction.send,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (_) => _submitTyped(),
        decoration: InputDecoration(
          hintText: 'Type a message',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24.0),
          ),
          isDense: true,
          suffixIcon: IconButton(
            icon: const Icon(Icons.arrow_upward_rounded),
            onPressed: controller.isBusy ? null : _submitTyped,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusLine(ThemeData theme, VoiceSessionController controller) {
    // A silent fallback to the device recogniser has to be visible, or a
    // misconfigured Whisper server just looks like worse accuracy.
    final fallback = controller.fallbackNotice;
    if (fallback != null && controller.phase != VoicePhase.listening) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: Text(
          fallback,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: _VoiceInk.of(theme.brightness).chrome),
        ),
      );
    }

    final label = switch (controller.phase) {
      VoicePhase.listening => controller.hearing ? 'Listening…' : 'One moment…',
      VoicePhase.thinking => controller.activity ?? 'Thinking…',
      VoicePhase.speaking => 'Speaking — tap to interrupt',
      VoicePhase.error => 'Tap to try again',
      VoicePhase.idle => controller.endedOnSilence
          ? "Didn't catch anything — tap to start again"
          : (controller.continuousMode ? 'Tap to start talking' : 'Tap to talk'),
    };

    return Text(
      label.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(
        color: HorizonBrand.accent(context),
        letterSpacing: 1.6,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// The voice screen's colour, one gradient per phase and per theme.
///
/// Full-bleed colour rather than the chat view's black, after Spotify's
/// lyrics screen: on colour, big type reads as a caption for what you are
/// hearing instead of another page of text.
///
/// Every stop is taken from the app icon — its sky, its sun on the water,
/// its sea — so the screen and the icon are the same picture. Dark follows
/// the dark icon's dusk; light follows the daytime icon, softened so dark
/// type sits on it. Each phase is a different hour of the same scene, so
/// the screen says what it is doing before you read a word.
class _VoiceBackdrop {
  const _VoiceBackdrop._();

  /// The redesign puts voice on black (warm paper in light mode): the room
  /// goes dark and the words and the orb are the only light. The phase is
  /// carried by the orb and the status line, not the background.
  static LinearGradient forPhase(VoicePhase phase, Brightness brightness) {
    final c = brightness == Brightness.dark ? const Color(0xFF000000) : HorizonBrand.paper;
    return LinearGradient(colors: [c, c]);
  }
}

/// Type and control colours that read on [_VoiceBackdrop].
///
/// Karaoke in both themes, mirrored: in dark the line being spoken is white
/// and what's still to come waits in dark ink; in light the line being
/// spoken is the icon's navy and what's to come waits pale.
class _VoiceInk {
  const _VoiceInk({
    required this.ink,
    required this.past,
    required this.upcoming,
    required this.chrome,
    required this.orb,
    required this.orbIcon,
  });

  /// The line being spoken, and ordinary text.
  final Color ink;

  /// Already heard: readable, clearly behind you.
  final Color past;

  /// Not reached yet.
  final Color upcoming;

  /// Status line and the smaller controls.
  final Color chrome;

  final Color orb;
  final Color orbIcon;

  static const _ink = Color(0xFF1D1B1A);

  static const dark = _VoiceInk(
    ink: Colors.white,
    past: Color(0x8CFFFFFF),
    upcoming: Color(0x33FFFFFF),
    chrome: Color(0x99FFFFFF),
    orb: HorizonBrand.orange,
    orbIcon: Colors.white,
  );

  static const light = _VoiceInk(
    ink: _ink,
    past: Color(0x801D1B1A),
    upcoming: Color(0x331D1B1A),
    chrome: Color(0x991D1B1A),
    orb: HorizonBrand.orangeInk,
    orbIcon: Colors.white,
  );

  static _VoiceInk of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// "Horizon Voice", with the model beneath it as a small dropdown.
class _VoiceTitle extends StatelessWidget {
  const _VoiceTitle({
    required this.model,
    required this.ink,
    required this.onChangeModel,
  });

  final String? model;
  final _VoiceInk ink;
  final VoidCallback? onChangeModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Horizon Voice',
          style: theme.textTheme.titleMedium?.copyWith(
            color: ink.ink,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
        InkWell(
          onTap: onChangeModel,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    model ?? 'Choose a model',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: ink.chrome,
                    ),
                  ),
                ),
                Icon(Icons.expand_more, size: 16, color: ink.chrome),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
