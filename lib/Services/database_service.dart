import 'dart:convert';
import 'dart:io';

import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as path;

class DatabaseService {
  late Database _db;

  Future<String> getDatabasesPathForPlatform() async {
    if (Platform.isLinux) {
      return PathManager.instance.documentsDirectory.path;
    } else {
      return await getDatabasesPath();
    }
  }

  /// Current schema version.
  ///   1 → original
  ///   2 → chats.provider
  ///   3 → message attachments + tool calls (and 'tool' as a legal role)
  ///   4 → chat lineage, for branching
  static const int schemaVersion = 4;

  Future<void> open(String databaseFile) async {
    _db = await openDatabase(
      path.join(await getDatabasesPathForPlatform(), databaseFile),
      version: schemaVersion,
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE chats ADD COLUMN provider TEXT NOT NULL DEFAULT 'ollama';",
          );
        }
        if (oldVersion < 3) {
          await _upgradeToV3(db);
        }
        if (oldVersion < 4) {
          // Plain column additions, unlike v3: no CHECK constraint is
          // involved, so no table rebuild.
          await db.execute('ALTER TABLE chats ADD COLUMN parent_chat_id TEXT;');
          await db.execute(
            'ALTER TABLE chats ADD COLUMN branch_point_message_id TEXT;',
          );
        }
      },
      onCreate: (Database db, int version) async {
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

        await db.execute(_createMessagesTable('messages'));
        await db.execute(_createCleanupJobsTable);
        await db.execute(_createCleanupTrigger);
      },
    );
  }

  static String _createMessagesTable(String name) => '''CREATE TABLE IF NOT EXISTS $name (
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
) WITHOUT ROWID;''';

  static const String _createCleanupJobsTable =
      '''CREATE TABLE IF NOT EXISTS cleanup_jobs (
id INTEGER PRIMARY KEY AUTOINCREMENT,
image_paths TEXT,
attachment_paths TEXT
)''';

  /// Queues a deleted message's files for removal from disk. Fires for images
  /// and document attachments alike; either column may be null.
  static const String _createCleanupTrigger =
      '''CREATE TRIGGER IF NOT EXISTS delete_images_trigger
AFTER DELETE ON messages
WHEN OLD.images IS NOT NULL OR OLD.attachments IS NOT NULL
BEGIN
  INSERT INTO cleanup_jobs (image_paths, attachment_paths)
  VALUES (OLD.images, OLD.attachments);
END;''';

  /// v3 adds the attachment/tool columns AND widens the `role` CHECK to admit
  /// 'tool'. SQLite can't alter a CHECK constraint in place, so the messages
  /// table is rebuilt: copy rows across, swap the table, recreate the trigger.
  /// The trigger is dropped first because it names `messages` directly and
  /// SQLite would otherwise rewrite it to point at the temporary table during
  /// the rename.
  static Future<void> _upgradeToV3(Database db) async {
    await db.execute('DROP TRIGGER IF EXISTS delete_images_trigger;');
    await db.execute(_createMessagesTable('messages_v3'));
    await db.execute('''INSERT INTO messages_v3
(message_id, chat_id, content, images, role, timestamp)
SELECT message_id, chat_id, content, images, role, timestamp FROM messages;''');
    await db.execute('DROP TABLE messages;');
    await db.execute('ALTER TABLE messages_v3 RENAME TO messages;');
    await db.execute(_createCleanupTrigger);

    // cleanup_jobs predates attachments and had image_paths NOT NULL, which
    // the widened trigger would violate for an attachment-only message.
    await db.execute('DROP TABLE IF EXISTS cleanup_jobs;');
    await db.execute(_createCleanupJobsTable);
  }

  Future<void> close() async => _db.close();

  // Chat Operations

  Future<OllamaChat> createChat(
    String model, {
    String provider = 'ollama',
    String? parentChatId,
    String? branchPointMessageId,
  }) async {
    final id = Uuid().v4();

    await _db.insert('chats', {
      'chat_id': id,
      'model': model,
      'chat_title': 'New Chat',
      'system_prompt': null,
      'options': null,
      'provider': provider,
      'parent_chat_id': parentChatId,
      'branch_point_message_id': branchPointMessageId,
    });

    return (await getChat(id))!;
  }

  /// Copies [source] and its messages up to and including [throughMessageId]
  /// into a new chat, recording where it came from.
  ///
  /// The copies get fresh message ids but keep their original timestamps, so
  /// the branch reads in the right order and the same file paths are reused
  /// rather than the images and attachments being duplicated on disk. Sharing
  /// paths is why [_cleanupDeletedImages] has to check for other references
  /// before deleting anything.
  Future<OllamaChat> branchChat(
    OllamaChat source, {
    required String throughMessageId,
    String? newTitle,
  }) async {
    final messages = await getMessages(source.id);
    final cutoff = messages.indexWhere((m) => m.id == throughMessageId);
    if (cutoff == -1) {
      throw OllamaException('That message is no longer in the chat.');
    }

    final branch = await createChat(
      source.model,
      provider: source.provider,
      parentChatId: source.id,
      branchPointMessageId: throughMessageId,
    );
    await updateChat(
      branch,
      newTitle: newTitle ?? source.title,
      newSystemPrompt: source.systemPrompt,
      newOptions: source.options,
    );

    await _db.transaction((txn) async {
      for (final message in messages.take(cutoff + 1)) {
        await txn.insert('messages', {
          ...message.toDatabaseMap(),
          'chat_id': branch.id,
          // A fresh id: the original message keeps existing, and message_id is
          // the primary key.
          'message_id': Uuid().v4(),
        });
      }
    });

    return (await getChat(branch.id))!;
  }

  Future<OllamaChat?> getChat(String chatId) async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );

    if (maps.isEmpty) {
      return null;
    } else {
      return OllamaChat.fromMap(maps.first);
    }
  }

  Future<void> updateChat(
    OllamaChat chat, {
    String? newModel,
    String? newTitle,
    String? newSystemPrompt,
    OllamaChatOptions? newOptions,
    String? newProvider,
  }) async {
    await _db.update(
      'chats',
      {
        'model': newModel ?? chat.model,
        'chat_title': newTitle ?? chat.title,
        'system_prompt': newSystemPrompt ?? chat.systemPrompt,
        'options': newOptions?.toJson() ?? chat.options.toJson(),
        'provider': newProvider ?? chat.provider,
        'parent_chat_id': chat.parentChatId,
        'branch_point_message_id': chat.branchPointMessageId,
      },
      where: 'chat_id = ?',
      whereArgs: [chat.id],
    );
  }

  Future<void> deleteChat(String chatId) async {
    await _db.delete(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );

    await _db.delete(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );

    // ? Should we run with Isolate.run?
    _cleanupDeletedImages();
  }

  Future<List<OllamaChat>> getAllChats() async {
    final List<Map<String, dynamic>> maps = await _db.rawQuery(
        '''SELECT chats.chat_id, chats.model, chats.chat_title, chats.system_prompt, chats.options, chats.provider, chats.parent_chat_id, chats.branch_point_message_id, MAX(messages.timestamp) AS last_update
FROM chats
LEFT JOIN messages ON chats.chat_id = messages.chat_id
GROUP BY chats.chat_id
ORDER BY last_update DESC;''');

    return List.generate(maps.length, (i) {
      return OllamaChat.fromMap(maps[i]);
    });
  }

  // Message Operations

  Future<void> addMessage(
    OllamaMessage message, {
    required OllamaChat chat,
  }) async {
    await _db.insert('messages', {
      'chat_id': chat.id,
      ...message.toDatabaseMap(),
    });
  }

  Future<OllamaMessage?> getMessage(String messageId) async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );

    if (maps.isEmpty) {
      return null;
    } else {
      return OllamaMessage.fromDatabase(maps.first);
    }
  }

  Future<void> updateMessage(
    OllamaMessage message, {
    String? newContent,
  }) async {
    await _db.update(
      'messages',
      {
        'content': newContent ?? message.content,
      },
      where: 'message_id = ?',
      whereArgs: [message.id],
    );
  }

  Future<void> deleteMessage(String messageId) async {
    await _db.delete(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );

    _cleanupDeletedImages();
  }

  Future<List<OllamaMessage>> getMessages(String chatId) async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
    );

    return List.generate(maps.length, (i) {
      return OllamaMessage.fromDatabase(maps[i]);
    });
  }

  Future<void> deleteMessages(List<OllamaMessage> messages) async {
    await _db.transaction((txn) async {
      for (final message in messages) {
        await txn.delete(
          'messages',
          where: 'message_id = ?',
          whereArgs: [message.id],
        );
      }
    });

    _cleanupDeletedImages();
  }

  // ? Should we trigger this cleanup on every message deletion?
  // ? Or should we run it on every app start?
  Future<void> _cleanupDeletedImages() async {
    final List<Map<String, dynamic>> results = await _db.query(
      'cleanup_jobs',
      columns: ['id', 'image_paths', 'attachment_paths'],
    );

    // Branching copies messages while reusing their file paths, so a path
    // queued for cleanup may still belong to a live message in another chat.
    // Deleting it would blank out the image in the chat that was branched
    // FROM, which is a silent data loss the user can't undo. So collect
    // everything still referenced and never touch those paths.
    final referenced = await _referencedFilePaths();

    for (final result in results) {
      try {
        final files = <File>[
          ...?_constructImages(result['image_paths'] as String?),
          ...?_constructAttachments(result['attachment_paths'] as String?),
        ];

        for (final file in files) {
          if (referenced.contains(file.path)) continue;
          if (await file.exists()) {
            await file.delete();
          }
        }

        // Delete the row after the files are gone
        await _db.delete(
          'cleanup_jobs',
          where: 'id = ?',
          whereArgs: [result['id']],
        );
      } catch (_) {}
    }
  }

  /// Absolute paths of every image and attachment still referenced by a
  /// message that exists. Used to keep cleanup from deleting a file that a
  /// branched copy still points at.
  Future<Set<String>> _referencedFilePaths() async {
    final rows = await _db.query(
      'messages',
      columns: ['images', 'attachments'],
      where: 'images IS NOT NULL OR attachments IS NOT NULL',
    );

    final paths = <String>{};
    for (final row in rows) {
      for (final file in _constructImages(row['images'] as String?) ?? const []) {
        paths.add(file.path);
      }
      for (final file
          in _constructAttachments(row['attachments'] as String?) ?? const []) {
        paths.add(file.path);
      }
    }
    return paths;
  }

  static List<File>? _constructImages(String? raw) {
    if (raw != null) {
      final List<dynamic> decoded = jsonDecode(raw);
      return decoded.map((imageRelativePath) {
        return File(path.join(
          PathManager.instance.documentsDirectory.path,
          imageRelativePath,
        ));
      }).toList();
    }

    return null;
  }

  /// Attachments serialise as objects, not bare paths, so the stored blob is
  /// a different shape from `images` — pick the `path` field out of each.
  static List<File>? _constructAttachments(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return decoded
        .whereType<Map>()
        .map((entry) => (entry['path'] ?? '').toString())
        .where((relative) => relative.isNotEmpty)
        .map((relative) => File(path.join(
              PathManager.instance.documentsDirectory.path,
              relative,
            )))
        .toList();
  }
}
