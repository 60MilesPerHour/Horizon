import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as path;

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Verifies the upgrade path against databases built with the *old* schemas,
/// which are the only shapes that matter.
///
/// v2 → v3 widens a CHECK constraint, which SQLite can only do by rebuilding
/// the messages table; getting that wrong loses every message a user has.
/// v4 → v5 retires the direct cloud clients and rewrites every chat bound to
/// one, so getting that wrong leaves a chat pointing at a provider the app no
/// longer contains — it would load and then refuse to send.
void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  PathProviderPlatform.instance = FakePathProviderPlatform();
  await PathManager.initialize();

  const fileName = 'migration_test.db';
  const v4FileName = 'migration_v4_test.db';
  // Must match DatabaseService.getDatabasesPathForPlatform exactly, or the
  // service opens a different (empty) file and the migration appears to work
  // while testing nothing.
  final databaseDirectory = Platform.isLinux
      ? PathManager.instance.documentsDirectory.path
      : await getDatabasesPath();
  final databasePath = path.join(databaseDirectory, fileName);
  final v4DatabasePath = path.join(databaseDirectory, v4FileName);

  /// Creates a database exactly as v3.7.5 and earlier left it.
  Future<void> createV2Database() async {
    await databaseFactoryFfi.deleteDatabase(databasePath);
    final db = await openDatabase(
      databasePath,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE IF NOT EXISTS chats (
chat_id TEXT PRIMARY KEY,
model TEXT NOT NULL,
chat_title TEXT NOT NULL,
system_prompt TEXT,
options TEXT,
provider TEXT NOT NULL DEFAULT 'ollama'
) WITHOUT ROWID;''');
        await db.execute('''CREATE TABLE IF NOT EXISTS messages (
message_id TEXT PRIMARY KEY,
chat_id TEXT NOT NULL,
content TEXT NOT NULL,
images TEXT,
role TEXT CHECK(role IN ('user', 'assistant', 'system')) NOT NULL,
timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
) WITHOUT ROWID;''');
        await db.execute('''CREATE TABLE IF NOT EXISTS cleanup_jobs (
id INTEGER PRIMARY KEY AUTOINCREMENT,
image_paths TEXT NOT NULL
)''');
        await db.execute('''CREATE TRIGGER IF NOT EXISTS delete_images_trigger
AFTER DELETE ON messages
WHEN OLD.images IS NOT NULL
BEGIN
  INSERT INTO cleanup_jobs (image_paths) VALUES (OLD.images);
END;''');
      },
    );

    await db.insert('chats', {
      'chat_id': 'chat-1',
      'model': 'qwen3.6:27b',
      'chat_title': 'Existing conversation',
      'system_prompt': 'be terse',
      'options': '{"temperature":0.4,"web_search":true}',
      'provider': 'ollama',
    });
    await db.insert('messages', {
      'message_id': 'msg-1',
      'chat_id': 'chat-1',
      'content': 'hello from v2',
      'images': null,
      'role': 'user',
      'timestamp': 1700000000000,
    });
    await db.insert('messages', {
      'message_id': 'msg-2',
      'chat_id': 'chat-1',
      'content': 'hi back',
      'images': null,
      'role': 'assistant',
      'timestamp': 1700000001000,
    });
    await db.close();
  }

  test('v2 messages and chats survive the upgrade', () async {
    await createV2Database();

    final service = DatabaseService();
    await service.open(fileName);

    final chats = await service.getAllChats();
    expect(chats.length, 1);
    expect(chats.single.title, 'Existing conversation');
    expect(chats.single.systemPrompt, 'be terse');
    expect(chats.single.options.temperature, 0.4);

    final messages = await service.getMessages('chat-1');
    expect(messages.map((m) => m.content), ['hello from v2', 'hi back']);
    expect(messages.first.role, OllamaMessageRole.user);
    // Columns added in v3 read as absent, not as garbage.
    expect(messages.first.attachments, isNull);
    expect(messages.first.hasToolCalls, isFalse);

    await service.close();
  });

  test("a chat that had web search on keeps tools on", () async {
    await createV2Database();

    final service = DatabaseService();
    await service.open(fileName);

    // `web_search` was the pre-v3.8 key for the same switch.
    expect((await service.getAllChats()).single.options.tools, isTrue);

    await service.close();
  });

  test('the widened role CHECK accepts a tool message', () async {
    await createV2Database();

    final service = DatabaseService();
    await service.open(fileName);
    final chat = (await service.getAllChats()).single;

    final call = ToolCall(
      id: 'call_1',
      name: 'web_search',
      arguments: const {'query': 'reins 2.3'},
    );

    // On a v2 table this insert fails the CHECK constraint outright, so this
    // is the assertion that the table was actually rebuilt.
    await service.addMessage(
      OllamaMessage('', role: OllamaMessageRole.assistant, toolCalls: [call]),
      chat: chat,
    );
    await service.addMessage(
      OllamaMessage.toolResult(
        call: call,
        result: const ToolResult('[1] Reins 2.3.0 — on-device models'),
      ),
      chat: chat,
    );

    final messages = await service.getMessages(chat.id);
    expect(messages.length, 4);

    final assistant = messages[2];
    expect(assistant.hasToolCalls, isTrue);
    expect(assistant.toolCalls!.single.arguments, {'query': 'reins 2.3'});

    final toolResult = messages[3];
    expect(toolResult.role, OllamaMessageRole.tool);
    expect(toolResult.toolName, 'web_search');
    expect(toolResult.toolFailed, isFalse);
    expect(toolResult.content, contains('on-device models'));

    await service.close();
  });

  /// Creates a database exactly as v3.13.x left it: schema v4, with chats
  /// bound to the three direct cloud clients that v4.0.0 removed.
  Future<void> createV4Database() async {
    await databaseFactoryFfi.deleteDatabase(v4DatabasePath);
    final db = await openDatabase(
      v4DatabasePath,
      version: 4,
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE IF NOT EXISTS chats (
chat_id TEXT PRIMARY KEY,
model TEXT NOT NULL,
chat_title TEXT NOT NULL,
system_prompt TEXT,
options TEXT,
provider TEXT NOT NULL DEFAULT 'ollama',
parent_chat_id TEXT,
branch_point_message_id TEXT
) WITHOUT ROWID;''');
        await db.execute('''CREATE TABLE IF NOT EXISTS messages (
message_id TEXT PRIMARY KEY,
chat_id TEXT NOT NULL,
content TEXT NOT NULL,
images TEXT,
attachments TEXT,
tool_calls TEXT,
tool_call_id TEXT,
tool_name TEXT,
tool_failed INTEGER NOT NULL DEFAULT 0,
role TEXT CHECK(role IN ('user', 'assistant', 'system', 'tool')) NOT NULL,
timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
) WITHOUT ROWID;''');
        await db.execute('''CREATE TABLE IF NOT EXISTS cleanup_jobs (
id INTEGER PRIMARY KEY AUTOINCREMENT,
image_paths TEXT,
attachment_paths TEXT
)''');
      },
    );

    const rows = [
      ['claude-chat', 'claude-sonnet-4-5-20250929', 'anthropic'],
      ['gpt-chat', 'gpt-4o', 'openai'],
      ['gemini-chat', 'gemini-1.5-pro', 'google'],
      ['local-chat', 'qwen3.6:27b', 'ollama'],
      ['router-chat', 'z-ai/glm-4.6', 'openrouter'],
    ];
    for (final row in rows) {
      await db.insert('chats', {
        'chat_id': row[0],
        'model': row[1],
        'chat_title': row[0],
        'system_prompt': null,
        'options': '{"temperature":0.8}',
        'provider': row[2],
      });
      await db.insert('messages', {
        'message_id': 'msg-${row[0]}',
        'chat_id': row[0],
        'content': 'a message in ${row[0]}',
        'role': 'user',
        'tool_failed': 0,
        'timestamp': 1700000000000,
      });
    }
    await db.close();
  }

  test('v4 chats on the direct clients move to OpenRouter', () async {
    await createV4Database();

    final service = DatabaseService();
    await service.open(v4FileName);

    final chats = {
      for (final chat in await service.getAllChats()) chat.id: chat,
    };
    expect(chats.length, 5);

    // Every retired provider is gone, with the model rewritten to its slug.
    expect(chats['claude-chat']!.provider, 'openrouter');
    expect(chats['claude-chat']!.model, 'anthropic/claude-sonnet-4.5');
    expect(chats['gpt-chat']!.model, 'openai/gpt-4o');
    expect(chats['gemini-chat']!.model, 'google/gemini-pro-1.5');

    // And what each one used to be is still on the row.
    expect(chats['claude-chat']!.legacyProvider, 'anthropic');
    expect(
      chats['claude-chat']!.legacyModel,
      'claude-sonnet-4-5-20250929',
    );

    // The two providers that survive are untouched.
    expect(chats['local-chat']!.provider, 'ollama');
    expect(chats['local-chat']!.model, 'qwen3.6:27b');
    expect(chats['local-chat']!.wasMigrated, isFalse);
    expect(chats['router-chat']!.model, 'z-ai/glm-4.6');
    expect(chats['router-chat']!.wasMigrated, isFalse);

    await service.close();
  });

  test('migrated chats keep their messages', () async {
    await createV4Database();

    final service = DatabaseService();
    await service.open(v4FileName);

    // The v5 step only UPDATEs chats, but it's the first migration to run
    // after branching shipped, so prove nothing cascaded.
    expect(
      (await service.getMessages('claude-chat')).single.content,
      'a message in claude-chat',
    );
    expect((await service.getMessages('local-chat')).length, 1);

    await service.close();
  });

  test('a branch of a migrated chat inherits the record of its origin',
      () async {
    await createV4Database();

    final service = DatabaseService();
    await service.open(v4FileName);

    final source = (await service.getAllChats())
        .firstWhere((chat) => chat.id == 'claude-chat');
    final branch = await service.branchChat(
      source,
      throughMessageId: (await service.getMessages(source.id)).single.id,
    );

    expect(branch.provider, 'openrouter');
    expect(branch.legacyProvider, 'anthropic');
    expect(branch.legacyModel, 'claude-sonnet-4-5-20250929');

    await service.close();
  });

  test('upgrading twice is a no-op', () async {
    await createV2Database();

    final first = DatabaseService();
    await first.open(fileName);
    await first.close();

    // Reopening runs onUpgrade only if the version moved; it must not try to
    // rebuild the table again and fall over on the leftover name.
    final second = DatabaseService();
    await second.open(fileName);
    expect((await second.getMessages('chat-1')).length, 2);
    await second.close();
  });
}

class FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    return path.join(Directory.current.path, 'test', 'assets');
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    return path.join(Directory.current.path, 'test', 'assets');
  }
}
