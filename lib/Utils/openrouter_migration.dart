/// Rewrites chats that were bound to Horizon's retired direct cloud clients
/// (`anthropic`, `openai`, `google`) onto OpenRouter.
///
/// Horizon talked to those three APIs directly until v4.0.0: three keys, three
/// request dialects, three tool protocols, three sets of capability guesswork.
/// OpenRouter serves the same models behind one key and one protocol and
/// reports per-model capabilities, so the direct clients were deleted and
/// every chat that used one is repointed here — at the database level by
/// schema v5, and on the fly for chats imported from a v3 export file, which
/// never pass through a migration.
///
/// The only real work is the model id. A direct-API id and an OpenRouter slug
/// name the same model differently, so each is mapped with an explicit alias
/// where the two disagree and a mechanical rule where they don't. A slug this
/// produces is a best effort, not a guarantee: what the original chat was
/// using is preserved alongside it (see [MigratedModelRef.legacyProvider]) so
/// a wrong guess is visible and correctable rather than silently lost.
class OpenRouterMigration {
  /// Provider ids Horizon used to route directly, mapped to the OpenRouter
  /// vendor prefix that replaces each.
  static const Map<String, String> retiredProviders = {
    'anthropic': 'anthropic',
    'openai': 'openai',
    'google': 'google',
  };

  /// Anthropic's dated ids versus OpenRouter's. Anthropic ships
  /// `claude-sonnet-4-5-20250929`; OpenRouter serves it as
  /// `anthropic/claude-sonnet-4.5`. Handled by [_dottedVersions] rather than
  /// an entry each, since the pattern holds across the whole family.
  ///
  /// This table is only for ids where no rule gets it right.
  static const Map<String, String> _aliases = {
    // Gemini 1.5 inverted the family/size order on OpenRouter.
    'gemini-1.5-pro': 'google/gemini-pro-1.5',
    'gemini-1.5-pro-latest': 'google/gemini-pro-1.5',
    'gemini-1.5-flash': 'google/gemini-flash-1.5',
    'gemini-1.5-flash-latest': 'google/gemini-flash-1.5',
    'gemini-1.5-flash-8b': 'google/gemini-flash-1.5-8b',
    'gemini-1.5-flash-8b-latest': 'google/gemini-flash-1.5-8b',
    // Pre-1.5 Gemini had no version in the id at all.
    'gemini-pro': 'google/gemini-pro',
    'gemini-pro-vision': 'google/gemini-pro-vision',
  };

  /// A trailing Anthropic release date (`-20250929`) or `-latest`. OpenRouter
  /// pins versions in the slug itself, so the suffix has no counterpart.
  static final RegExp _versionSuffix = RegExp(r'-(?:\d{8}|latest)$');

  /// Which vendor a retired provider id belongs to, or null if [provider] was
  /// never one of them.
  static String? vendorForProvider(String? provider) => provider == null ? null : retiredProviders[provider];

  /// Guesses the vendor from the shape of a bare model id, for rows written
  /// before per-chat provider routing existed (schema v1) and so carrying a
  /// cloud model under provider `ollama` or none at all. An OpenRouter slug is
  /// already `vendor/model` and never matches these.
  static String? vendorForBareModel(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('/')) return null;
    if (lower.startsWith('claude-')) return 'anthropic';
    if (lower.startsWith('gpt-') ||
        lower.startsWith('chatgpt-') ||
        lower.startsWith('o1') ||
        lower.startsWith('o3') ||
        lower.startsWith('o4')) {
      return 'openai';
    }
    if (lower.startsWith('gemini-') || lower.startsWith('models/gemini-')) {
      return 'google';
    }
    return null;
  }

  /// The OpenRouter slug for a direct-API model id.
  static String slugFor({required String vendor, required String model}) {
    // Gemini's list endpoint returns `models/gemini-2.5-pro`.
    var id = model.startsWith('models/') ? model.substring(7) : model;
    id = id.trim();

    final alias = _aliases[id.toLowerCase()];
    if (alias != null) return alias;

    if (vendor == 'anthropic') {
      id = id.replaceFirst(_versionSuffix, '');
      id = _dottedVersions(id);
    }

    // Already qualified — a model id that arrived with a vendor prefix is
    // passed through rather than double-prefixed.
    if (id.contains('/')) return id;
    return '$vendor/$id';
  }

  /// Joins adjacent numeric segments with a dot: `claude-3-5-sonnet` becomes
  /// `claude-3.5-sonnet`, `claude-sonnet-4-5` becomes `claude-sonnet-4.5`.
  /// Anthropic writes the version with hyphens and OpenRouter with a dot; a
  /// single-numeric version (`claude-3-opus`) is the same either way and is
  /// left alone.
  static String _dottedVersions(String id) {
    final parts = id.split('-');
    final out = <String>[];
    for (final part in parts) {
      final isNumber = RegExp(r'^\d+$').hasMatch(part);
      if (isNumber && out.isNotEmpty && RegExp(r'^\d+(\.\d+)*$').hasMatch(out.last)) {
        out[out.length - 1] = '${out.last}.$part';
      } else {
        out.add(part);
      }
    }
    return out.join('-');
  }

  /// Maps a stored (provider, model) pair onto OpenRouter, or returns null if
  /// there's nothing to do — which is the case for every Ollama and OpenRouter
  /// chat, i.e. almost all of them.
  static MigratedModelRef? migrate({String? provider, required String model}) {
    if (provider == 'openrouter' || provider == 'ollama') return null;
    if (model.trim().isEmpty) return null;

    final vendor = vendorForProvider(provider) ?? vendorForBareModel(model);
    if (vendor == null) return null;

    return MigratedModelRef(
      model: slugFor(vendor: vendor, model: model),
      legacyProvider: provider ?? vendor,
      legacyModel: model,
    );
  }
}

/// A chat's model after migration, plus what it was before.
class MigratedModelRef {
  /// OpenRouter slug to use from now on.
  final String model;

  /// The retired provider id the chat was bound to.
  final String legacyProvider;

  /// The direct-API model id the chat was using.
  final String legacyModel;

  const MigratedModelRef({required this.model, required this.legacyProvider, required this.legacyModel});
}
