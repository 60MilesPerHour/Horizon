import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/voice/speech_recognition_service.dart';
import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Services/voice/voice_session_controller.dart';

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

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final chatProvider = context.read<ChatProvider>();
    final settings = Hive.box('settings');

    // Pin the assistant to whatever model Settings names, falling back to the
    // model the chat already uses, then to anything available. Failing to
    // resolve one is the only hard blocker here.
    OllamaModel? model;
    final preferredName = settings.get('assistant_model') as String?;
    try {
      final models = await chatProvider.fetchAvailableModels();
      if (models.isNotEmpty) {
        model = models.firstWhere(
          (m) => m.name == (preferredName ?? chatProvider.assistantChatModel),
          orElse: () => models.first,
        );
      }
    } catch (e) {
      // An existing assistant chat already knows its model, so a failed model
      // fetch is only fatal on first run.
      if (chatProvider.assistantChatModel == null) {
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
      recognition: context.read<SpeechRecognitionService>(),
      synthesis: synthesis,
    )
      ..localeId = (settings.get('voice_locale') as String?) ?? ''
      ..speakReplies =
          settings.get('voice_speak_replies', defaultValue: true) as bool;

    setState(() {
      _controller = controller;
      _preparing = false;
    });

    if (widget.autoStart) await controller.startListening();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assistant'),
        actions: [
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
          child: Text(
            'Tap to talk',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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

  Widget _buildStatusLine(ThemeData theme, VoiceSessionController controller) {
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
