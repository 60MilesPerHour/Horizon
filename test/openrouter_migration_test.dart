import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Utils/openrouter_migration.dart';

/// The mapping from a direct-API model id to an OpenRouter slug. A wrong slug
/// means a migrated chat can't send, and the failure surfaces as a 400 from
/// OpenRouter rather than anything the app can explain, so the rules are
/// pinned here per vendor.
void main() {
  group('Anthropic ids', () {
    test('drops the release date and dots the version', () {
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'anthropic',
          model: 'claude-sonnet-4-5-20250929',
        ),
        'anthropic/claude-sonnet-4.5',
      );
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'anthropic',
          model: 'claude-3-5-sonnet-20241022',
        ),
        'anthropic/claude-3.5-sonnet',
      );
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'anthropic',
          model: 'claude-opus-4-1-20250805',
        ),
        'anthropic/claude-opus-4.1',
      );
    });

    test('leaves a single-segment version alone', () {
      // `claude-3-opus` is spelled the same either side.
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'anthropic',
          model: 'claude-3-opus-20240229',
        ),
        'anthropic/claude-3-opus',
      );
    });

    test('handles the -latest alias', () {
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'anthropic',
          model: 'claude-3-5-haiku-latest',
        ),
        'anthropic/claude-3.5-haiku',
      );
    });
  });

  group('OpenAI ids', () {
    test('are prefixed unchanged', () {
      expect(
        OpenRouterMigration.slugFor(vendor: 'openai', model: 'gpt-4o'),
        'openai/gpt-4o',
      );
      expect(
        OpenRouterMigration.slugFor(vendor: 'openai', model: 'gpt-4.1-mini'),
        'openai/gpt-4.1-mini',
      );
      expect(
        OpenRouterMigration.slugFor(vendor: 'openai', model: 'o3-mini'),
        'openai/o3-mini',
      );
    });

    test('keep a -latest suffix, which OpenRouter serves verbatim', () {
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'openai',
          model: 'chatgpt-4o-latest',
        ),
        'openai/chatgpt-4o-latest',
      );
    });
  });

  group('Google ids', () {
    test('strip the models/ prefix the list endpoint adds', () {
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'google',
          model: 'models/gemini-2.5-pro',
        ),
        'google/gemini-2.5-pro',
      );
    });

    test('use the alias table where 1.5 inverted family and size', () {
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'google',
          model: 'gemini-1.5-flash-8b',
        ),
        'google/gemini-flash-1.5-8b',
      );
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'google',
          model: 'gemini-1.5-pro-latest',
        ),
        'google/gemini-pro-1.5',
      );
    });
  });

  group('migrate()', () {
    test('rewrites a retired provider and records what it was', () {
      final result = OpenRouterMigration.migrate(
        provider: 'anthropic',
        model: 'claude-sonnet-4-5-20250929',
      )!;
      expect(result.model, 'anthropic/claude-sonnet-4.5');
      expect(result.legacyProvider, 'anthropic');
      expect(result.legacyModel, 'claude-sonnet-4-5-20250929');
    });

    test('leaves Ollama and OpenRouter chats alone', () {
      expect(
        OpenRouterMigration.migrate(provider: 'ollama', model: 'qwen3.6:27b'),
        isNull,
      );
      expect(
        OpenRouterMigration.migrate(
          provider: 'openrouter',
          model: 'anthropic/claude-sonnet-4.5',
        ),
        isNull,
      );
    });

    test('never touches an Ollama model that looks cloud-ish', () {
      // Local gemma is not the Gemini API's gemma, and a colon-tagged local
      // model is never a cloud id.
      expect(
        OpenRouterMigration.migrate(provider: 'ollama', model: 'gemma3:27b'),
        isNull,
      );
      expect(
        OpenRouterMigration.migrate(provider: null, model: 'llama3.2:latest'),
        isNull,
      );
    });

    test('rescues a v1 row that has no provider at all', () {
      // Schema v1 had no `provider` column, so a cloud chat from that era is
      // identifiable only by the shape of its model id.
      final result =
          OpenRouterMigration.migrate(provider: null, model: 'gpt-4o')!;
      expect(result.model, 'openai/gpt-4o');
      expect(result.legacyProvider, 'openai');
    });

    test('an already-qualified id is not double-prefixed', () {
      expect(
        OpenRouterMigration.slugFor(
          vendor: 'anthropic',
          model: 'anthropic/claude-3.5-sonnet',
        ),
        'anthropic/claude-3.5-sonnet',
      );
    });
  });

  group('OllamaChat.fromMap', () {
    test('migrates an imported v3 chat that never saw the DB upgrade', () {
      // Chat import goes straight from an export file to an OllamaChat, so
      // this is the only place a retired provider id can still arrive.
      final chat = OllamaChat.fromMap({
        'chat_id': 'c1',
        'model': 'claude-3-7-sonnet-20250219',
        'chat_title': 'Old Claude chat',
        'provider': 'anthropic',
      });

      expect(chat.provider, 'openrouter');
      expect(chat.model, 'anthropic/claude-3.7-sonnet');
      expect(chat.wasMigrated, isTrue);
      expect(chat.legacyModel, 'claude-3-7-sonnet-20250219');
    });

    test('keeps the stored legacy columns for an already-migrated row', () {
      final chat = OllamaChat.fromMap({
        'chat_id': 'c1',
        'model': 'anthropic/claude-3.7-sonnet',
        'chat_title': 'Migrated',
        'provider': 'openrouter',
        'legacy_provider': 'anthropic',
        'legacy_model': 'claude-3-7-sonnet-20250219',
      });

      expect(chat.provider, 'openrouter');
      expect(chat.legacyProvider, 'anthropic');
      expect(chat.wasMigrated, isTrue);
    });

    test('an ordinary Ollama chat reports no migration', () {
      final chat = OllamaChat.fromMap({
        'chat_id': 'c1',
        'model': 'qwen3.6:27b',
        'chat_title': 'Local',
        'provider': 'ollama',
      });

      expect(chat.provider, 'ollama');
      expect(chat.wasMigrated, isFalse);
    });
  });
}
