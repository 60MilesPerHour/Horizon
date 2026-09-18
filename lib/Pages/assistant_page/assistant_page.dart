import 'dart:async';

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

    // Warm the recogniser now rather than on the first tap: initialise() is a
    // platform round-trip plus a permission check, and paying for it when the
    // user taps is exactly the delay they notice.
    unawaited(context.read<SpeechInputService>().device.prewarm());

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
                child: _VoiceOrb(
                  phase: controller.phase,
                  levels: controller.showsLevelMeter ? controller.levels : null,
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
              // The microphone level now drives the orb's halo instead of a
              // separate meter here — a widget that appeared and disappeared
              // in this column is what made everything below it jump.
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
      VoicePhase.idle => controller.endedOnSilence
          ? "Didn't catch anything — tap to start again"
          : (controller.continuousMode ? 'Tap to start talking' : 'Tap to talk'),
    };

    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// The single control: an orb that reacts in place rather than moving.
///
/// One widget for all phases, at a constant footprint, because the previous
/// version changed size and sat under content whose height changed with the
/// phase — so it visibly drifted under your thumb between turns. Everything
/// here animates scale and colour inside a fixed box.
class _VoiceOrb extends StatefulWidget {
  final VoicePhase phase;

  /// Microphone level, when the active backend has no partial words to show.
  final Stream<double>? levels;

  final VoidCallback onTap;

  const _VoiceOrb({
    required this.phase,
    required this.onTap,
    this.levels,
  });

  @override
  State<_VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<_VoiceOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  StreamSubscription<double>? _levelSub;
  double _level = 0;

  static const double _size = 104;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _syncPulse();
    _subscribeLevels();
  }

  @override
  void didUpdateWidget(covariant _VoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) _syncPulse();
    if (oldWidget.levels != widget.levels) _subscribeLevels();
  }

  void _subscribeLevels() {
    _levelSub?.cancel();
    _levelSub = widget.levels?.listen((value) {
      if (mounted) setState(() => _level = value.clamp(0.0, 1.0));
    });
  }

  /// Thinking and speaking pulse continuously; listening and idle don't, so
  /// motion means "working" rather than being constant decoration.
  void _syncPulse() {
    final shouldPulse = widget.phase == VoicePhase.thinking ||
        widget.phase == VoicePhase.speaking;
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (IconData icon, Color colour) = switch (widget.phase) {
      VoicePhase.listening => (Icons.mic, theme.colorScheme.primary),
      VoicePhase.thinking => (Icons.auto_awesome, theme.colorScheme.tertiary),
      VoicePhase.speaking => (Icons.graphic_eq, theme.colorScheme.secondary),
      VoicePhase.error => (Icons.refresh, theme.colorScheme.error),
      VoicePhase.idle => (Icons.mic_none, theme.colorScheme.primaryContainer),
    };

    final foreground =
        ThemeData.estimateBrightnessForColor(colour) == Brightness.dark
            ? Colors.white
            : Colors.black87;

    return Semantics(
      button: true,
      label: switch (widget.phase) {
        VoicePhase.listening => 'Stop listening',
        VoicePhase.thinking || VoicePhase.speaking => 'Interrupt',
        _ => 'Start listening',
      },
      child: GestureDetector(
        onTap: widget.onTap,
        // The fixed box is what keeps the orb still: the halo grows into the
        // padding instead of pushing anything around.
        child: SizedBox(
          width: _size + 28,
          height: _size + 28,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              // While listening, the halo follows the microphone. While
              // thinking or speaking it breathes on the animation clock.
              final energy = widget.phase == VoicePhase.listening
                  ? _level
                  : (_pulse.isAnimating ? _pulse.value : 0.0);

              return Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: _size + 8 + energy * 20,
                    height: _size + 8 + energy * 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colour.withValues(alpha: 0.18 + energy * 0.22),
                    ),
                  ),
                  Container(
                    width: _size,
                    height: _size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colour,
                    ),
                    child: Icon(icon, size: 42, color: foreground),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

