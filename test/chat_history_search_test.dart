import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Services/chat_history_search.dart';
import 'package:horizon/Services/database_service.dart';
import 'package:horizon/Services/home_assistant_service.dart';
import 'package:horizon/Services/tool_service.dart';
import 'package:horizon/Services/web_search_service.dart';
import 'package:horizon/Models/chat_tool.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `search_chats` is the context-bridging mechanism, so the tests are about
/// its boundary: only shared chats, never the current one, and no excerpt for
/// a query the search can't actually answer.
void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  PathProviderPlatform.instance = FakePathProviderPlatform();
  await PathManager.initialize();

  late DatabaseService database;
  late ChatHistorySearch search;
  late OllamaChat shared;
  late OllamaChat private;
  late OllamaChat current;

  setUp(() async {
    final dir = Platform.isLinux
        ? PathManager.instance.documentsDirectory.path
        : await getDatabasesPath();
    await databaseFactoryFfi
        .deleteDatabase(path.join(dir, 'history_search_test.db'));

    database = DatabaseService();
    await database.open('history_search_test.db');

    shared = await database.createChat('qwen3.6:27b');
    shared.options.bridge = true;
    await database.updateChat(shared, newTitle: 'Mazda maintenance');

    private = await database.createChat('qwen3.6:27b');
    await database.updateChat(private, newTitle: 'Private notes');

    current = await database.createChat('qwen3.6:27b');
    current.options.bridge = true;
    await database.updateChat(current, newTitle: 'Assistant');

    await database.addMessage(
      OllamaMessage('the oil filter for the mazda is a Wix 57055',
          role: OllamaMessageRole.user),
      chat: shared,
    );
    await database.addMessage(
      OllamaMessage('noted, Wix 57055 it is', role: OllamaMessageRole.assistant),
      chat: shared,
    );
    await database.addMessage(
      OllamaMessage('the safe combination is 12345', role: OllamaMessageRole.user),
      chat: private,
    );
    await database.addMessage(
      OllamaMessage('what was that mazda filter again',
          role: OllamaMessageRole.user),
      chat: current,
    );

    // Re-read so the chats carry the persisted options, then hand the live
    // list to the search service the way ChatProvider does.
    final all = await database.getAllChats();
    search = ChatHistorySearch(database: database)..chatsSource = () => all;
  });

  tearDown(() async => database.close());

  test('finds a message in a shared chat', () async {
    final result = await search.searchFormatted('mazda oil filter');
    expect(result, contains('Wix 57055'));
    expect(result, contains('Mazda maintenance'));
  });

  test('never returns anything from a chat that is not shared', () async {
    final result = await search.searchFormatted('safe combination');
    expect(result, isNot(contains('12345')));
    expect(result, contains('No messages'));
  });

  test('excludes the chat doing the asking', () async {
    // Without the exclusion this matches the current chat's own question,
    // spending the result budget on text already in the prompt.
    final result = await search.searchFormatted(
      'mazda filter',
      excludeChatId: current.id,
    );
    expect(result, isNot(contains('what was that mazda filter again')));
    expect(result, contains('Wix 57055'));
  });

  test('a query of nothing but filler words finds nothing', () async {
    // Every term has to match, so "what did i say about it" would otherwise
    // return the newest message in every shared chat.
    expect(await search.searchFormatted('what did I say about it'), isNull);
  });

  test('is unconfigured when no chat is shared', () async {
    final none = ChatHistorySearch(database: database)
      ..chatsSource = () => [private];
    expect(none.isConfigured, isFalse);
    expect(search.isConfigured, isTrue);
  });

  test('bridge survives a round trip through the database', () async {
    final reloaded = (await database.getAllChats())
        .firstWhere((chat) => chat.id == shared.id);
    expect(reloaded.options.bridge, isTrue);

    final untouched = (await database.getAllChats())
        .firstWhere((chat) => chat.id == private.id);
    expect(untouched.options.bridge, isFalse);
  });

  _haUrlTests();

  group('tool declaration', () {
    test('search_chats is offered only when a chat is shared', () {
      final withShared = ToolService(
        webSearch: WebSearchService(),
        chatSearch: search,
      );
      expect(
        withShared.availableTools().map((t) => t.name),
        contains('search_chats'),
      );

      final withoutShared = ToolService(
        webSearch: WebSearchService(),
        chatSearch: ChatHistorySearch(database: database)
          ..chatsSource = () => [private],
      );
      expect(
        withoutShared.availableTools().map((t) => t.name),
        isNot(contains('search_chats')),
      );
    });

    test('Home Assistant tools appear only when configured', () {
      final unconfigured = ToolService(
        webSearch: WebSearchService(),
        homeAssistant: HomeAssistantService(),
      );
      expect(
        unconfigured.availableTools().map((t) => t.name),
        isNot(contains('ha_call_service')),
      );

      final configured = ToolService(
        webSearch: WebSearchService(),
        homeAssistant: HomeAssistantService(
          baseUrl: 'http://homeassistant.local:8123',
          token: 'token',
        ),
      );
      expect(
        configured.availableTools().map((t) => t.name),
        containsAll(['ha_list_entities', 'ha_get_state', 'ha_call_service']),
      );
    });

    test('an unconfigured chat search reports how to turn it on', () async {
      final service = ToolService(webSearch: WebSearchService());
      final result = await service.execute(
        const ToolCall(id: '1', name: 'search_chats', arguments: {'query': 'x'}),
      );
      expect(result.isError, isTrue);
      expect(result.content, contains('Share with assistant'));
    });
  });
}

class FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      path.join(Directory.current.path, 'test', 'assets');

  @override
  Future<String?> getApplicationSupportPath() async =>
      path.join(Directory.current.path, 'test', 'assets');
}

/// Home Assistant URL handling, which is where a "wrong token" report usually
/// turns out to be a wrong address.
void _haUrlTests() {
  group('Home Assistant endpoints', () {
    test('a bare host gets a scheme and /api', () {
      expect(
        HomeAssistantService.endpointFor('homeassistant.local:8123', '/states')
            .toString(),
        'http://homeassistant.local:8123/api/states',
      );
    });

    test('a trailing slash does not double up', () {
      expect(
        HomeAssistantService.endpointFor('http://10.0.0.5:8123/', '/config')
            .toString(),
        'http://10.0.0.5:8123/api/config',
      );
    });

    test('a pasted /api suffix is not repeated', () {
      expect(
        HomeAssistantService.endpointFor('https://ha.example.com/api', '/states')
            .toString(),
        'https://ha.example.com/api/states',
      );
    });

    test('https is preserved', () {
      expect(
        HomeAssistantService.endpointFor('https://ha.example.com', '/states')
            .scheme,
        'https',
      );
    });

    test('isConfigured needs both the URL and the token', () {
      expect(HomeAssistantService(baseUrl: 'http://x:8123').isConfigured, isFalse);
      expect(HomeAssistantService(token: 'abc').isConfigured, isFalse);
      expect(
        HomeAssistantService(baseUrl: 'http://x:8123', token: 'abc').isConfigured,
        isTrue,
      );
    });
  });
}
