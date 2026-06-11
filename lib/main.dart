import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/settings_route_arguments.dart';
import 'package:horizon/Pages/chat_page/chat_page_view_model.dart';
import 'package:horizon/Pages/main_page.dart';
import 'package:horizon/Pages/ollama_models_page/ollama_models_page.dart';
import 'package:horizon/Pages/settings_page/settings_page.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/services.dart';
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

  // Load cloud-provider API keys from secure storage (best-effort).
  String? claudeKey;
  String? openaiKey;
  String? openaiBaseUrl;
  String? geminiKey;
  String? ollamaToken;
  String? serpApiKey;
  try {
    const storage = FlutterSecureStorage();
    claudeKey = await storage.read(key: 'anthropic_api_key');
    openaiKey = await storage.read(key: 'openai_api_key');
    openaiBaseUrl = await storage.read(key: 'openai_base_url');
    geminiKey = await storage.read(key: 'google_api_key');
    ollamaToken = await storage.read(key: 'ollama_api_token');
    serpApiKey = await storage.read(key: 'serpapi_api_key');
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

  final ollamaService = OllamaService(apiToken: ollamaToken);
  final claudeService = ClaudeService(apiKey: claudeKey);
  final openaiService = OpenAIService(apiKey: openaiKey, baseUrl: openaiBaseUrl);
  final geminiService = GeminiService(apiKey: geminiKey);
  final registry = ChatServiceRegistry(
    ollama: ollamaService,
    claude: claudeService,
    openai: openaiService,
    gemini: geminiService,
  );

  runApp(
    MultiProvider(
      providers: [
        Provider(create: (_) => ollamaService),
        Provider(create: (_) => claudeService),
        Provider(create: (_) => openaiService),
        Provider(create: (_) => geminiService),
        Provider(create: (_) => registry),
        Provider(create: (_) => webSearchService),
        ChangeNotifierProvider(create: (_) => OllamaHealthMonitor(ollamaService)),
        Provider(create: (_) => DatabaseService()),
        Provider(create: (_) => PermissionService()),
        Provider(create: (_) => ImageService()),
        ChangeNotifierProvider(
          create: (context) => ChatProvider(
            registry: context.read(),
            databaseService: context.read(),
            webSearch: context.read(),
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => ChatPageViewModel(
            chatProvider: context.read(),
            permissionService: context.read(),
            imageService: context.read(),
            registry: context.read(),
          ),
        ),
      ],
      child: const HorizonApp(),
    ),
  );
}

class HorizonApp extends StatelessWidget {
  const HorizonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box('settings').listenable(
        keys: ['color', 'brightness'],
      ),
      builder: (context, box, _) {
        final brightness = _brightness ?? MediaQuery.platformBrightnessOf(context);
        final seedColor = box.get('color', defaultValue: Colors.grey) as Color;

        return MaterialApp(
          title: AppConstants.appName,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              brightness: Brightness.light,
              dynamicSchemeVariant: DynamicSchemeVariant.neutral,
              seedColor: seedColor,
            ),
            appBarTheme: const AppBarTheme(centerTitle: true),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              brightness: Brightness.dark,
              dynamicSchemeVariant: DynamicSchemeVariant.neutral,
              seedColor: seedColor,
              surface: const Color(0xFF000000),
            ),
            scaffoldBackgroundColor: const Color(0xFF000000),
            appBarTheme: const AppBarTheme(centerTitle: true),
            useMaterial3: true,
          ),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => ResponsiveBreakpoints.builder(
            breakpoints: [
              const Breakpoint(start: 0, end: 450, name: MOBILE),
              const Breakpoint(start: 451, end: 800, name: TABLET),
              const Breakpoint(start: 801, end: 1920, name: DESKTOP),
            ],
            useShortestSide: true,
            child: child!,
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

            assert(false, 'Need to implement ${settings.name}');
            return null;
          },
        );
      },
    );
  }

  Brightness? get _brightness {
    final brightnessValue = Hive.box('settings').get('brightness');
    if (brightnessValue == null) return null;
    return brightnessValue == 1 ? Brightness.light : Brightness.dark;
  }
}
