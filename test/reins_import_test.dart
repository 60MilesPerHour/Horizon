import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Services/chat_export_service.dart';

const _sample = '''# Weekend Plans
*4 words, a subtitle Reins sometimes adds*

Model: llama3:latest · Exported: October 1, 2026 · 9:27 PM

---

**User**

What should I do this weekend?

---

**Assistant**

Some options:

---

**User**
isn't a new turn without a rule above it — but this one is.

---

**User**

Thanks
''';

void main() {
  test('parses a Reins Markdown export', () {
    final parsed = ChatExportService().parseImport(_sample);
    expect(parsed.chat.title, 'Weekend Plans');
    expect(parsed.chat.model, 'llama3:latest');
    expect(parsed.chat.provider, 'ollama');
    expect(parsed.messages.map((m) => m.role), [
      OllamaMessageRole.user,
      OllamaMessageRole.assistant,
      OllamaMessageRole.user,
      OllamaMessageRole.user,
    ]);
    expect(parsed.messages[0].content, 'What should I do this weekend?');
    expect(parsed.messages[1].content, 'Some options:');
    expect(parsed.messages.last.content, 'Thanks');
    // Distinct, ascending, ending just before the export time.
    final times = parsed.messages.map((m) => m.createdAt).toList();
    for (int i = 1; i < times.length; i++) {
      expect(times[i].isAfter(times[i - 1]), isTrue);
    }
    expect(times.last.isBefore(DateTime(2026, 10, 1, 21, 27)), isTrue);
    expect(times.last.year, 2026);
  });

  test('CRLF Reins export parses the same', () {
    final parsed =
        ChatExportService().parseImport(_sample.replaceAll('\n', '\r\n'));
    expect(parsed.messages, hasLength(4));
  });

  test('Horizon export still round-trips', () {
    const horizon = '<!--\n{"horizon_export":1,"title":"T","model":"m",'
        '"provider":"ollama"}\n-->\n\n# T\n\n## User · 2026-01-01 10:00\n\nhi\n\n'
        '## Assistant · 2026-01-01 10:01\n\nhello\n';
    final parsed = ChatExportService().parseImport(horizon);
    expect(parsed.messages.map((m) => m.content), ['hi', 'hello']);
  });

  Uint8List reinsZip(Map<String, dynamic> chatJson) {
    final data = utf8.encode(json.encode(chatJson));
    final archive = Archive()..addFile(ArchiveFile('chat.json', data.length, data));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  test('parses a .reins archive', () {
    final bytes = reinsZip({
      'version': 1,
      'exportedAt': '2026-10-01T10:57:33.882449',
      'chat': {
        'chat_id': 'x',
        'model': 'gpt-oss:20b',
        'chat_title': 'Pixel Trial',
        'system_prompt': 'Be brief.',
        'options': '{"temperature":0.5,"top_k":20,"num_ctx":8192}',
      },
      'messages': [
        {'role': 'user', 'content': 'Hi · there', 'timestamp': 1769341075065},
        {'role': 'assistant', 'content': 'Hello', 'timestamp': 1769341093802},
      ],
    });
    expect(ChatExportService.isZip(bytes), isTrue);
    final parsed = ChatExportService().parseReinsArchive(bytes);
    expect(parsed.chat.title, 'Pixel Trial');
    expect(parsed.chat.model, 'gpt-oss:20b');
    expect(parsed.chat.systemPrompt, 'Be brief.');
    expect(parsed.chat.options.temperature, 0.5);
    expect(parsed.chat.options.topK, 20);
    expect(parsed.messages.map((m) => m.role),
        [OllamaMessageRole.user, OllamaMessageRole.assistant]);
    expect(parsed.messages.first.content, 'Hi · there');
    expect(parsed.messages.first.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1769341075065));
  });

  test('.reins without chat.json is rejected', () {
    final data = utf8.encode('nope');
    final bytes = Uint8List.fromList(ZipEncoder()
        .encode(Archive()..addFile(ArchiveFile('other.txt', data.length, data))));
    expect(() => ChatExportService().parseReinsArchive(bytes),
        throwsFormatException);
  });

  final dir = Platform.environment['REINS_DIR'];
  test('real .reins archives', () {
    final files = Directory(dir!)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.reins'));
    expect(files, isNotEmpty);
    for (final f in files) {
      final parsed = ChatExportService().parseReinsArchive(f.readAsBytesSync());
      expect(parsed.messages, isNotEmpty, reason: f.path);
      expect(parsed.chat.model, isNotEmpty, reason: f.path);
      // ignore: avoid_print
      print('${parsed.messages.length} msgs  ${parsed.chat.model}  '
          '${parsed.chat.title}');
    }
  }, skip: dir == null ? 'set REINS_DIR to check real exports' : false);

  test('real Reins backups', () {
    for (final f in Directory(dir!)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.md'))) {
      final text = f.readAsStringSync();
      final parsed = ChatExportService().parseImport(text);
      final markers =
          RegExp(r'^\*\*(User|Assistant)\*\*\s*$', multiLine: true)
              .allMatches(text)
              .length;
      // ignore: avoid_print
      print('${parsed.messages.length}/$markers  ${parsed.chat.model}  '
          '${parsed.chat.title}');
      expect(parsed.messages.length, markers, reason: f.path);
      expect(parsed.chat.model, isNotEmpty);
    }
  }, skip: dir == null ? 'set REINS_DIR to check real exports' : false);
}
