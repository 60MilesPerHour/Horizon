import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Services/voice/stt/speech_input_service.dart';
import 'package:horizon/Services/voice/voice_session_controller.dart';
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

    if (!mounted) return;
    final synthesis = context.read<SpeechSynthesisService>();
    final controller = VoiceSessionController(
      chatProvider: chatProvider,
      recognition: context.read<SpeechInputService>(),
      synthesis: synthesis,
    )..speakReplies =
        settings.get('voice_speak_replies', defaultValue: true) as bool;

    setState(() {
      _controller = controller;
      _preparing = false;
    });

    if (widget.autoStart) await controller.startListening();
  }

  Future<void> _changeModel() async {
    final chatProvider = context.read<ChatProvider>();
    final selected = await showModelSelectionBottomSheet(
      context: context,
      title: 'Assistant Model',
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

  @override
  void dispose() {
    _controller?.dispose();
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

    return Scaffold(
      appBar: AppBar(
        // The model name, not a static title: in voice mode there's otherwise
        // nothing on screen saying which model is about to answer, and the
        // chat view puts this same control in its app bar.
        title: TextButton.icon(
          onPressed: _controller == null ? null : _changeModel,
          icon: const Icon(Icons.expand_more, size: 20),
          iconAlignment: IconAlignment.end,
          label: Text(
            context.watch<ChatProvider>().currentChat?.model ?? 'Assistant',
            overflow: TextOverflow.ellipsis,
          ),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
            textStyle: theme.textTheme.titleMedium,
          ),
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
            _buildStatusLine(theme, controller),
            const SizedBox(height: 12),
            _MicButton(
              phase: controller.phase,
              onPressed: controller.toggle,
            ),
            const SizedBox(height: 32),
          ],
        );
      },
    );
  }

  Widget _buildTranscript(ThemeData theme, VoiceSessionController controller) {
    final hasTranscript = controller.transcript.trim().isNotEmpty;
    final hasReply = controller.reply.trim().isNotEmpty;

    if (!hasTranscript && !hasReply && controller.error == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Tap to talk',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              // Whisper and Scribe transcribe a finished clip, so there are no
              // words to show while talking — without a level meter the screen
              // looks frozen.
              if (controller.phase == VoicePhase.listening &&
                  controller.showsLevelMeter) ...[
                const SizedBox(height: 24),
                _LevelMeter(levels: controller.levels),
              ],
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasTranscript)
            Text(
              controller.transcript,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (hasTranscript && (hasReply || controller.error != null))
            const SizedBox(height: 20),
          if (controller.error != null)
            SelectableText(
              controller.error!,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.error),
            )
          else if (hasReply)
            // Plain text, not Markdown: this is a caption for something being
            // spoken, and re-parsing Markdown on every streamed tick is the
            // one thing the chat view already learned not to do.
            Text(
              controller.reply,
              style: theme.textTheme.headlineSmall?.copyWith(height: 1.35),
            ),
        ],
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
              ?.copyWith(color: theme.colorScheme.tertiary),
        ),
      );
    }

    final label = switch (controller.phase) {
      VoicePhase.listening => 'Listening…',
      VoicePhase.thinking => controller.activity ?? 'Thinking…',
      VoicePhase.speaking => 'Speaking — tap to interrupt',
      VoicePhase.error => 'Tap to try again',
      VoicePhase.idle => 'Tap to talk',
    };

    return Text(
      label,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Microphone level while a recording backend captures a turn.
class _LevelMeter extends StatelessWidget {
  final Stream<double> levels;

  const _LevelMeter({required this.levels});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<double>(
      stream: levels,
      initialData: 0.0,
      builder: (context, snapshot) {
        final level = (snapshot.data ?? 0.0).clamp(0.0, 1.0);
        return SizedBox(
          height: 36,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(7, (i) {
              // Bars nearer the middle react first, so quiet speech still
              // visibly moves something.
              final threshold = (i - 3).abs() / 7.0;
              final active = level > threshold;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3.0),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 6,
                  height: active ? 12 + level * 24 : 6,
                  decoration: BoxDecoration(
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

/// The one control: a large target that changes colour and icon with phase.
class _MicButton extends StatelessWidget {
  final VoicePhase phase;
  final VoidCallback onPressed;

  const _MicButton({required this.phase, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (IconData icon, Color background) = switch (phase) {
      VoicePhase.listening => (Icons.mic, theme.colorScheme.primary),
      VoicePhase.thinking => (Icons.more_horiz, theme.colorScheme.secondary),
      VoicePhase.speaking => (Icons.stop_rounded, theme.colorScheme.secondary),
      VoicePhase.error => (Icons.refresh, theme.colorScheme.errorContainer),
      VoicePhase.idle => (Icons.mic_none, theme.colorScheme.primaryContainer),
    };

    final foreground = ThemeData.estimateBrightnessForColor(background) ==
            Brightness.dark
        ? Colors.white
        : Colors.black87;

    return Semantics(
      button: true,
      label: switch (phase) {
        VoicePhase.listening => 'Stop listening',
        VoicePhase.thinking || VoicePhase.speaking => 'Interrupt',
        _ => 'Start listening',
      },
      child: GestureDetector(
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: background,
            boxShadow: phase == VoicePhase.listening
                ? [
                    BoxShadow(
                      color: background.withValues(alpha: 0.4),
                      blurRadius: 24,
                      spreadRadius: 6,
                    )
                  ]
                : null,
          ),
          child: Icon(icon, size: 40, color: foreground),
        ),
      ),
    );
  }
}
