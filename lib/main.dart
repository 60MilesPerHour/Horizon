import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Constants/horizon_theme.dart';
import 'package:horizon/Models/settings_route_arguments.dart';
import 'package:horizon/Pages/assistant_page/assistant_page.dart';
import 'package:horizon/Pages/chat_page/chat_page_view_model.dart';
import 'package:horizon/Pages/main_page.dart';
import 'package:horizon/Pages/ollama_models_page/ollama_models_page.dart';
import 'package:horizon/Pages/settings_page/settings_page.dart';
import 'package:horizon/Pages/settings_page/voice_settings_page.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/appearance_controller.dart';
import 'package:horizon/Services/services.dart';
import 'package:horizon/Services/voice/speech_recognition_service.dart';
import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Services/voice/stt/elevenlabs_transcriber.dart';
import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Services/voice/stt/speech_input_service.dart';
import 'package:horizon/Services/voice/stt/voice_recorder.dart';
import 'package:horizon/Services/voice/stt/mic_pcm_stream.dart';
import 'package:horizon/Services/voice/stt/streaming_speech_session.dart';
import 'package:horizon/Services/voice/stt/whisper_live_client.dart';
import 'package:horizon/Services/voice/stt/whisper_transcriber.dart';
import 'package:horizon/Services/voice/wake/wake_word_detector.dart';
import 'package:horizon/Services/voice/wake/wake_word_listener.dart';
import 'package:horizon/Utils/material_color_adapter.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:horizon/Utils/request_review_helper.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart' as sqlite3_open;

void main() async {
  // The bundled fonts' licences, shown on the app's licences page as the OFL
  // asks of anything that ships the fonts.
  LicenseRegistry.addLicense(() async* {
    for (final (font, file) in const [
      ('Pacifico', 'assets/google_fonts/Pacifico-OFL.txt'),
      ('Source Code Pro', 'assets/google_fonts/SourceCodePro-OFL.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([font], await rootBundle.loadString(file));
    }
  });

  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux) {
    // The dart sqlite3 loader defaults to opening the unversioned
    // `libsqlite3.so`, which on Debian/Ubuntu is only shipped by
    // libsqlite3-dev. Our .deb depends on libsqlite3-0, which provides
    // `libsqlite3.so.0`. Without this override a fresh install crashes at
    // boot with "Failed to load dynamic library 'libsqlite3.so'", _db never
    // initializes, and the first send throws a LateInitializationError before
    // the message bubble renders. Try the unversioned name first (dev installs
    // / other distros), then fall back to the versioned soname.
    if (Platform.isLinux) {
      sqlite3_open.open.overrideFor(sqlite3_open.OperatingSystem.linux, () {
        try {
          return DynamicLibrary.open('libsqlite3.so');
        } catch (_) {
          return DynamicLibrary.open('libsqlite3.so.0');
        }
      });
    }

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Initialize PathManager
  await PathManager.initialize();

  // Initialize Hive
  if (Platform.isLinux) {
    Hive.init(PathManager.instance.documentsDirectory.path);
  } else {
    await Hive.initFlutter();
  }

  Hive.registerAdapter(MaterialColorAdapter());

  await Hive.openBox('settings');

  // Initialize RequestReviewHelper and request review if needed
  final reviewHelper = await RequestReviewHelper.initialize();

  await reviewHelper.incrementCount(isLaunch: true);

  final inAppReview = InAppReview.instance;
  if (await inAppReview.isAvailable() && reviewHelper.shouldRequestReview()) {
    await inAppReview.requestReview();
  }

  // Load API keys and tokens from secure storage (best-effort).
  String? ollamaToken;
  String? cfAccessClientId;
  String? cfAccessClientSecret;
  String? serpApiKey;
  String? openrouterKey;
  String? elevenLabsKey;
  String? whisperKey;
  String? ttsKey;
  String? haToken;
  String? claudeKey;
  String? openaiKey;
  String? openaiBaseUrl;
  String? geminiKey;
  String? hermesKey;
  try {
    const storage = FlutterSecureStorage();
    ollamaToken = await storage.read(key: 'ollama_api_token');
    cfAccessClientId = await storage.read(key: 'cf_access_client_id');
    cfAccessClientSecret = await storage.read(key: 'cf_access_client_secret');
    serpApiKey = await storage.read(key: 'serpapi_api_key');
    openrouterKey = await storage.read(key: 'openrouter_api_key');
    elevenLabsKey = await storage.read(key: 'elevenlabs_api_key');
    whisperKey = await storage.read(key: 'whisper_api_key');
    ttsKey = await storage.read(key: 'tts_api_key');
    haToken = await storage.read(key: 'ha_token');
    claudeKey = await storage.read(key: 'anthropic_api_key');
    openaiKey = await storage.read(key: 'openai_api_key');
    openaiBaseUrl = await storage.read(key: 'openai_base_url');
    geminiKey = await storage.read(key: 'google_api_key');
    hermesKey = await storage.read(key: 'hermes_api_key');
  } catch (_) {
    // Secure storage may be unavailable on Linux without a keyring; tolerate.
  }

  // Web-search config: backend choice + SearXNG URL live in the (non-secret)
  // settings box; the SerpAPI key lives in secure storage above.
  final settingsBox = Hive.box('settings');
  final webSearchService = WebSearchService(
    backend: WebSearchBackend.fromString(
        settingsBox.get('web_search_backend') as String?),
    serpApiKey: serpApiKey,
    searxngUrl: settingsBox.get('searxng_url') as String?,
  );

  // Hard kill switch for the one cloud backend: off means no hosted model
  // ever appears, so the app is Ollama-only until a key is pasted. It switches
  // itself on as soon as one exists — one key, every hosted model, nothing
  // else to enable.
  final openrouterEnabled = settingsBox.get(
    'enable_openrouter',
    defaultValue: openrouterKey != null && openrouterKey.isNotEmpty,
  ) as bool;
  // The direct clients are the advanced path, so each stays off until it's
  // switched on in Settings, whatever key is stored. New keys, not v3's
  // `enable_anthropic` and friends: those were never cleared, and reusing
  // them would quietly switch a provider back on for anyone who had it on in
  // v3, with a key they may have forgotten was there.
  final claudeEnabled =
      settingsBox.get('enable_direct_anthropic', defaultValue: false) as bool;
  final openaiEnabled =
      settingsBox.get('enable_direct_openai', defaultValue: false) as bool;
  final geminiEnabled =
      settingsBox.get('enable_direct_google', defaultValue: false) as bool;

  final ollamaService = OllamaService(
    apiToken: ollamaToken,
    cfAccessClientId: cfAccessClientId,
    cfAccessClientSecret: cfAccessClientSecret,
  );
  final openrouterService = OpenRouterService(
    apiKey: openrouterKey,
    enabled: openrouterEnabled,
  );
  final claudeService =
      ClaudeService(apiKey: claudeKey, enabled: claudeEnabled);
  final openaiService = OpenAIService(
    apiKey: openaiKey,
    baseUrl: openaiBaseUrl,
    enabled: openaiEnabled,
  );
  final geminiService =
      GeminiService(apiKey: geminiKey, enabled: geminiEnabled);
  // Your own Hermes agent. Same Access token as everything else: it sits
  // behind the same tunnel.
  final hermesService = HermesService(
    baseUrl: settingsBox.get('hermes_base_url') as String?,
    backupUrl: settingsBox.get('hermes_backup_url') as String?,
    apiKey: hermesKey,
    cfAccessClientId: cfAccessClientId,
    cfAccessClientSecret: cfAccessClientSecret,
    enabled: settingsBox.get('enable_hermes', defaultValue: false) as bool,
  );
  final registry = ChatServiceRegistry(
    ollama: ollamaService,
    openrouter: openrouterService,
    claude: claudeService,
    openai: openaiService,
    gemini: geminiService,
    hermes: hermesService,
  );

  // Home Assistant: the instance URL is ordinary config, the long-lived token
  // is a secret, so the two live in different stores.
  final homeAssistantService = HomeAssistantService(
    baseUrl: settingsBox.get('ha_base_url') as String?,
    token: haToken,
    toolsEnabled: settingsBox.get('ha_tools_enabled', defaultValue: true) as bool,
  );

  // `chatsSource` is wired by ChatProvider below — the search service is built
  // first, and reading the chat list through a callback means there's no
  // second copy of it here to go stale.
  final databaseService = DatabaseService();
  final chatHistorySearch = ChatHistorySearch(database: databaseService);
  final toolService = ToolService(
    webSearch: webSearchService,
    chatSearch: chatHistorySearch,
    homeAssistant: homeAssistantService,
  );

  // Voice mode. The services hold config rather than reading Hive on each
  // utterance, mirroring the chat services; Settings mutates them live.
  final speechRecognition = SpeechRecognitionService();
  final whisperTranscriber = WhisperTranscriber(
    baseUrl: settingsBox.get('whisper_base_url') as String?,
    backupUrl: settingsBox.get('whisper_backup_url') as String?,
    model: settingsBox.get('whisper_model') as String?,
    apiKey: whisperKey,
    // The same Access service token the chat path uses: one tunnel, one
    // token, and nothing extra to enter for the speech hostname.
    cfAccessClientId: cfAccessClientId,
    cfAccessClientSecret: cfAccessClientSecret,
  );
  final elevenLabsTranscriber = ElevenLabsTranscriber(apiKey: elevenLabsKey);
  // Live transcription is its own server (WhisperLive speaks a WebSocket, not
  // the OpenAI transcription API), so it gets its own address pair — and the
  // same Cloudflare Access token as everything else, because it is the same
  // tunnel.
  final whisperLive = WhisperLiveClient(
    baseUrl: settingsBox.get('live_base_url') as String?,
    backupUrl: settingsBox.get('live_backup_url') as String?,
    model: settingsBox.get('live_model') as String?,
    cfAccessClientId: cfAccessClientId,
    cfAccessClientSecret: cfAccessClientSecret,
  );
  final streamingSpeech = StreamingSpeechSession(
    mic: MicPcmStream(),
    client: whisperLive,
  );
  final speechInput = SpeechInputService(
    device: speechRecognition,
    recorder: VoiceRecorder()
      ..uploadUncompressed =
          (settingsBox.get('voice_upload_wav') as bool?) ?? false,
    whisper: whisperTranscriber,
    elevenLabs: elevenLabsTranscriber,
    streaming: streamingSpeech,
  )
    ..backend = _initialSttBackend(
      settingsBox.get('stt_backend') as String?,
      liveConfigured: whisperLive.isConfigured,
      whisperConfigured: whisperTranscriber.isConfigured,
    )
    ..localeId = (settingsBox.get('voice_locale') as String?) ?? '';
  final speechSynthesis = SpeechSynthesisService(
    engine: SpeechEngine.fromString(settingsBox.get('voice_engine') as String?),
    elevenLabsKey: elevenLabsKey,
    elevenLabsVoiceId: settingsBox.get('elevenlabs_voice_id') as String?,
    systemVoiceLocale: settingsBox.get('voice_tts_locale') as String?,
    selfHostedBaseUrl: settingsBox.get('tts_base_url') as String?,
    selfHostedBackupUrl: settingsBox.get('tts_backup_url') as String?,
    cfAccessClientId: cfAccessClientId,
    cfAccessClientSecret: cfAccessClientSecret,
    selfHostedModel: settingsBox.get('tts_model') as String?,
    selfHostedVoice: settingsBox.get('tts_voice') as String?,
    selfHostedKey: ttsKey,
    rate: (settingsBox.get('voice_rate') as num?)?.toDouble(),
  );

  // "Hey Horizon". Built here rather than in the widget tree so it outlives
  // any one screen; it opens Horizon Voice through the app's navigator.
  final wakeWord = WakeWordListener(onWake: HorizonApp.openVoice)
    ..sustain = (settingsBox.get('voice_wake_sensitivity') as String?) == 'strict'
        ? WakeWordDetector.strictSustain
        : WakeWordDetector.balancedSustain;
  unawaited(wakeWord.setEnabled(
    (settingsBox.get('voice_wake_word') as bool?) ?? false,
  ));

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: wakeWord),
        ChangeNotifierProvider(create: (_) => AppearanceController()),
        Provider(create: (_) => ollamaService),
        Provider(create: (_) => openrouterService),
        Provider(create: (_) => claudeService),
        Provider(create: (_) => openaiService),
        Provider(create: (_) => geminiService),
        Provider(create: (_) => hermesService),
        Provider(create: (_) => registry),
        Provider(create: (_) => webSearchService),
        Provider(create: (_) => homeAssistantService),
        Provider(create: (_) => chatHistorySearch),
        Provider(create: (_) => toolService),
        Provider(create: (_) => speechRecognition),
        Provider(create: (_) => speechSynthesis),
        Provider(create: (_) => whisperTranscriber),
        Provider(create: (_) => whisperLive),
        Provider(create: (_) => elevenLabsTranscriber),
        Provider(create: (_) => speechInput),
        ChangeNotifierProvider(create: (_) => OllamaHealthMonitor(ollamaService)),
        Provider(create: (_) => databaseService),
        Provider(create: (_) => PermissionService()),
        Provider(create: (_) => ImageService()),
        Provider(create: (_) => AttachmentService()),
        ChangeNotifierProvider(
          create: (context) => ChatProvider(
            registry: context.read(),
            databaseService: context.read(),
            webSearch: context.read(),
            toolService: context.read(),
            chatHistorySearch: context.read(),
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => ChatPageViewModel(
            chatProvider: context.read(),
            permissionService: context.read(),
            imageService: context.read(),
            attachmentService: context.read(),
            registry: context.read(),
          ),
        ),
      ],
      child: const HorizonApp(),
    ),
  );
}

class HorizonApp extends StatefulWidget {
  const HorizonApp({super.key});

  /// Needed to push the voice route from outside any widget's BuildContext —
  /// the platform channel and the wake word both fire from there.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Shows Horizon Voice listening, replacing rather than stacking, so
  /// repeated gestures or wake words don't build a pile of voice pages.
  static void pushVoiceRoute() {
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/assistant?autostart=1',
      (route) => route.isFirst,
    );
  }

  static const MethodChannel _channel =
      MethodChannel('com.miles.horizon/assistant');

  /// What the wake word calls. On screen, that's just the route. Behind
  /// another app, the activity has to be brought forward first — which
  /// Android only allows through the assistant role or a notification — and
  /// the route then arrives through [MainActivity.onNewIntent] like an assist
  /// gesture does.
  static void openVoice() {
    final visible =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (visible) {
      pushVoiceRoute();
      return;
    }
    unawaited(_channel.invokeMethod<String>('openVoiceFromBackground').then(
      (route) => debugPrint('voice: wake word opened Horizon via $route'),
      onError: (Object e) => debugPrint('voice: could not open Horizon: $e'),
    ));
  }

  @override
  State<HorizonApp> createState() => _HorizonAppState();
}

class _HorizonAppState extends State<HorizonApp> {
  /// Tells the wake word when the app comes and goes, so it can take the
  /// microphone service while it's allowed to and keep listening after.
  late final AppLifecycleListener _lifecycle;

  static const MethodChannel _assistantChannel =
      MethodChannel('com.miles.horizon/assistant');

  @override
  void initState() {
    super.initState();
    // getInitialRoute on the Android side covers a cold launch; this covers an
    // assist gesture against an already-running process, which reuses the
    // activity and so never re-reads the initial route.
    _assistantChannel.setMethodCallHandler((call) async {
      if (call.method != 'openAssistant') return null;
      HorizonApp.pushVoiceRoute();
      return null;
    });
    // An assist launch that reached the native side before this isolate was
    // listening — a cold start from the gesture, or the wake word bringing
    // a closed window back.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final pending = await _assistantChannel.invokeMethod<bool>('takePendingAssist');
        if (pending == true) HorizonApp.pushVoiceRoute();
      } catch (_) {
        // No such channel off Android.
      }
    });
    final wakeWord = context.read<WakeWordListener>();
    _lifecycle = AppLifecycleListener(
      onResume: wakeWord.appVisible,
      onHide: wakeWord.appHidden,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // One listener for every appearance setting, rather than naming Hive keys
    // here — which is how a new setting used to end up applying only after a
    // restart.
    final appearance = context.watch<AppearanceController>().appearance;

    return MaterialApp(
          navigatorKey: HorizonApp.navigatorKey,
          title: AppConstants.appName,
          theme: HorizonTheme.light(appearance),
          darkTheme: HorizonTheme.dark(appearance),
          themeMode: appearance.themeMode,
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            // Multiplies the platform's own scale rather than replacing it, so
            // a user who has set a system-wide text size keeps it.
            minScaleFactor:
                MediaQuery.textScalerOf(context).scale(1) * appearance.textScale,
            maxScaleFactor:
                MediaQuery.textScalerOf(context).scale(1) * appearance.textScale,
            child: ResponsiveBreakpoints.builder(
              breakpoints: [
                const Breakpoint(start: 0, end: 450, name: MOBILE),
                const Breakpoint(start: 451, end: 800, name: TABLET),
                const Breakpoint(start: 801, end: 1920, name: DESKTOP),
              ],
              useShortestSide: true,
              child: child!,
            ),
          ),
          onGenerateRoute: (settings) {
            if (settings.name == '/') {
              return MaterialPageRoute(
                builder: (context) => const HorizonMainPage(),
              );
            }

            if (settings.name == '/settings') {
              final args = settings.arguments as SettingsRouteArguments?;

              return MaterialPageRoute(
                builder: (context) => SettingsPage(arguments: args),
              );
            }

            if (settings.name == '/ollama-models') {
              return MaterialPageRoute(
                builder: (context) => const OllamaModelsPage(),
              );
            }

            // Launched by the assist gesture (autostart=1, so the mic opens
            // without a tap) or from the app's own voice button.
            final routeUri = Uri.tryParse(settings.name ?? '');
            if (settings.name == '/settings/voice') {
              return MaterialPageRoute(
                builder: (context) => const VoiceSettingsPage(),
              );
            }

            if (routeUri?.path == '/assistant') {
              final autoStart = routeUri?.queryParameters['autostart'] == '1';
              return MaterialPageRoute(
                builder: (context) => AssistantPage(autoStart: autoStart),
              );
            }

            assert(false, 'Need to implement ${settings.name}');
            return null;
          },
        );
  }
}

/// The speech-to-text backend to start with.
///
/// An explicit choice always wins. Without one, the best configured server
/// rather than the device recogniser: that default quietly assumes Google's
/// recogniser is installed, and on a phone without it the "device" backend
/// is routed through whichever assistant app happens to register a
/// recognition service — voice mode then hears nothing and says nothing.
SttBackend _initialSttBackend(
  String? stored, {
  required bool liveConfigured,
  required bool whisperConfigured,
}) {
  if (stored != null && stored.isNotEmpty) return SttBackend.fromString(stored);
  if (liveConfigured) return SttBackend.live;
  if (whisperConfigured) return SttBackend.whisper;
  return SttBackend.device;
}
