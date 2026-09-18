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
import 'package:horizon/Services/voice/stt/whisper_transcriber.dart';
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

  final ollamaService = OllamaService(
    apiToken: ollamaToken,
    cfAccessClientId: cfAccessClientId,
    cfAccessClientSecret: cfAccessClientSecret,
  );
  final openrouterService = OpenRouterService(
    apiKey: openrouterKey,
    enabled: openrouterEnabled,
  );
  final registry = ChatServiceRegistry(
    ollama: ollamaService,
    openrouter: openrouterService,
  );

  // Home Assistant: the instance URL is ordinary config, the long-lived token
  // is a secret, so the two live in different stores.
  final homeAssistantService = HomeAssistantService(
    baseUrl: settingsBox.get('ha_base_url') as String?,
    token: haToken,
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
    model: settingsBox.get('whisper_model') as String?,
    apiKey: whisperKey,
  );
  final elevenLabsTranscriber = ElevenLabsTranscriber(apiKey: elevenLabsKey);
  final speechInput = SpeechInputService(
    device: speechRecognition,
    recorder: VoiceRecorder(),
    whisper: whisperTranscriber,
    elevenLabs: elevenLabsTranscriber,
  )
    ..backend = SttBackend.fromString(settingsBox.get('stt_backend') as String?)
    ..localeId = (settingsBox.get('voice_locale') as String?) ?? '';
  final speechSynthesis = SpeechSynthesisService(
    engine: SpeechEngine.fromString(settingsBox.get('voice_engine') as String?),
    elevenLabsKey: elevenLabsKey,
    elevenLabsVoiceId: settingsBox.get('elevenlabs_voice_id') as String?,
    systemVoiceLocale: settingsBox.get('voice_tts_locale') as String?,
    selfHostedBaseUrl: settingsBox.get('tts_base_url') as String?,
    selfHostedModel: settingsBox.get('tts_model') as String?,
    selfHostedVoice: settingsBox.get('tts_voice') as String?,
    selfHostedKey: ttsKey,
    rate: (settingsBox.get('voice_rate') as num?)?.toDouble(),
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppearanceController()),
        Provider(create: (_) => ollamaService),
        Provider(create: (_) => openrouterService),
        Provider(create: (_) => registry),
        Provider(create: (_) => webSearchService),
        Provider(create: (_) => homeAssistantService),
        Provider(create: (_) => chatHistorySearch),
        Provider(create: (_) => toolService),
        Provider(create: (_) => speechRecognition),
        Provider(create: (_) => speechSynthesis),
        Provider(create: (_) => whisperTranscriber),
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

  @override
  State<HorizonApp> createState() => _HorizonAppState();
}

class _HorizonAppState extends State<HorizonApp> {
  /// Needed to push the assistant route from the platform channel, which
  /// fires outside any widget's BuildContext.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

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
      final navigator = _navigatorKey.currentState;
      if (navigator == null) return null;
      // Replace rather than stack, so repeated gestures don't build a pile of
      // assistant pages behind each other.
      navigator.pushNamedAndRemoveUntil(
        '/assistant?autostart=1',
        (route) => route.isFirst,
      );
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // One listener for every appearance setting, rather than naming Hive keys
    // here — which is how a new setting used to end up applying only after a
    // restart.
    final appearance = context.watch<AppearanceController>().appearance;

    return MaterialApp(
          navigatorKey: _navigatorKey,
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
