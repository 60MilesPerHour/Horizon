import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as path;

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  PathProviderPlatform.instance = FakePathProviderPlatform();
  await PathManager.initialize();

  final databaseDirectory = Platform.isLinux
      ? PathManager.instance.documentsDirectory.path
      : await getDatabasesPath();

  late DatabaseService service;
  late OllamaChat source;
  late List<OllamaMessage> original;

  setUp(() async {
    const fileName = 'branching_test.db';
    await databaseFactoryFfi
        .deleteDatabase(path.join(databaseDirectory, fileName));
    service = DatabaseService();
    await service.open(fileName);

    source = await service.createChat('qwen3.8:27b');
    await service.updateChat(
      source,
      newTitle: 'Original',
      newSystemPrompt: 'be terse',
      newOptions: OllamaChatOptions(temperature: 0.42),
    );
    source = (await service.getChat(source.id))!;

    for (final entry in [
      ('first question', OllamaMessageRole.user),
      ('first answer', OllamaMessageRole.assistant),
      ('second question', OllamaMessageRole.user),
      ('second answer', OllamaMessageRole.assistant),
    ]) {
      await service.addMessage(
        OllamaMessage(entry.$1, role: entry.$2),
        chat: source,
      );
      // Distinct timestamps, so ordering is deterministic.
      await Future.delayed(const Duration(milliseconds: 2));
    }
    original = await service.getMessages(source.id);
  });

  tearDown(() async => service.close());

  test('a branch keeps history up to the cut and drops the rest', () async {
    final branch = await service.branchChat(
      source,
      throughMessageId: original[1].id, // after the first answer
    );

    final branched = await service.getMessages(branch.id);
    expect(branched.map((m) => m.content),
        ['first question', 'first answer']);

    // The original is untouched — that's the whole point, as against editing
    // or regenerating.
    expect((await service.getMessages(source.id)).length, 4);
  });

  test('a branch inherits model, provider, prompt and options', () async {
    final branch = await service.branchChat(
      source,
      throughMessageId: original[1].id,
    );

    expect(branch.model, 'qwen3.8:27b');
    expect(branch.provider, source.provider);
    expect(branch.systemPrompt, 'be terse');
    expect(branch.options.temperature, 0.42);
  });

  test('a branch records where it came from', () async {
    final branch = await service.branchChat(
      source,
      throughMessageId: original[2].id,
    );

    expect(branch.isBranch, isTrue);
    expect(branch.parentChatId, source.id);
    expect(branch.branchPointMessageId, original[2].id);

    // And survives a reload, i.e. it's really persisted.
    expect((await service.getChat(branch.id))!.parentChatId, source.id);
    expect(source.isBranch, isFalse);
  });

  test('copied messages get new ids so the originals still exist', () async {
    final branch = await service.branchChat(
      source,
      throughMessageId: original[1].id,
    );

    final branched = await service.getMessages(branch.id);
    final originalIds = original.map((m) => m.id).toSet();
    for (final message in branched) {
      expect(originalIds.contains(message.id), isFalse,
          reason: 'message_id is the primary key; a reused id would collide');
    }
    // Both copies are retrievable, so nothing was moved rather than copied.
    expect(await service.getMessage(original[1].id), isNotNull);
  });

  test('branching the last message copies the whole conversation', () async {
    final branch = await service.branchChat(
      source,
      throughMessageId: original.last.id,
    );
    expect((await service.getMessages(branch.id)).length, 4);
  });

  test('an unknown message id is refused', () async {
    expect(
      () => service.branchChat(source, throughMessageId: 'not-a-real-id'),
      throwsA(isA<Exception>()),
    );
  });

  test('deleting a branch does not delete files the original still shows',
      () async {
    // The regression this guards: branch copies reuse the parent's file
    // paths, so a naive cleanup deletes the image out from under the chat
    // that was branched from — silently, and with no way back.
    final imagesDir = Directory(
      path.join(PathManager.instance.documentsDirectory.path, 'images'),
    );
    await imagesDir.create(recursive: true);
    final shared = File(path.join(imagesDir.path, 'shared-branch-test.jpg'));
    await shared.writeAsBytes(List<int>.filled(64, 7));

    await service.addMessage(
      OllamaMessage('look at this', role: OllamaMessageRole.user,
          images: [shared]),
      chat: source,
    );
    final withImage = (await service.getMessages(source.id)).last;

    final branch = await service.branchChat(
      source,
      throughMessageId: withImage.id,
    );
    // Both chats now reference the same file on disk.
    expect((await service.getMessages(branch.id)).last.images!.single.path,
        shared.path);

    await service.deleteChat(branch.id);
    // Cleanup runs unawaited inside deleteChat.
    await Future.delayed(const Duration(milliseconds: 600));

    expect(await shared.exists(), isTrue,
        reason: 'the original chat still displays this image');

    // Once the last reference goes, it may be reclaimed.
    await service.deleteChat(source.id);
    await Future.delayed(const Duration(milliseconds: 600));
    expect(await shared.exists(), isFalse,
        reason: 'nothing references it now, so it should be cleaned up');
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
