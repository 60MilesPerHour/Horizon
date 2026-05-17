import 'package:horizon/Models/api/tags_response.dart';
import 'package:horizon/Models/api/show_response.dart';
import 'package:horizon/Models/model_capabilities.dart';

/// Domain model representing a chat model (Ollama or cloud-hosted).
class OllamaModel {
  final String name;
  final String model;
  final DateTime modifiedAt;
  final int size;
  final String digest;
  final String parameterSize;
  final ModelCapabilities? capabilities;

  /// Provider id this model belongs to: 'ollama', 'anthropic', 'openai'.
  final String provider;

  OllamaModel({
    required this.name,
    required this.model,
    required this.modifiedAt,
    required this.size,
    required this.digest,
    required this.parameterSize,
    this.capabilities,
    this.provider = 'ollama',
  });

  /// Creates an OllamaModel from /api/tags and optional /api/show response
  factory OllamaModel.from(ApiTagsModel tagsModel, ApiShowResponse? showResponse) {
    return OllamaModel(
      name: tagsModel.name,
      model: tagsModel.model,
      modifiedAt: tagsModel.modifiedAt,
      size: tagsModel.size,
      digest: tagsModel.digest,
      parameterSize: tagsModel.details.parameterSize,
      capabilities: showResponse != null ? ModelCapabilities.fromList(showResponse.capabilities) : null,
      provider: 'ollama',
    );
  }

  /// For backward compatibility with existing JSON serialization
  factory OllamaModel.fromJson(Map<String, dynamic> json) => OllamaModel(
        name: json["name"],
        model: json["model"],
        modifiedAt: DateTime.parse(json["modified_at"]),
        size: json["size"],
        digest: json["digest"],
        parameterSize: json["details"]["parameter_size"] ?? '',
        capabilities: null,
        provider: json["provider"] ?? 'ollama',
      );

  /// Builder for cloud-provider models which lack /api/tags-shaped metadata.
  factory OllamaModel.cloud({
    required String provider,
    required String id,
    String? parameterSize,
    ModelCapabilities? capabilities,
  }) => OllamaModel(
        name: id,
        model: id,
        modifiedAt: DateTime.now(),
        size: 0,
        digest: '$provider:$id',
        parameterSize: parameterSize ?? '',
        capabilities: capabilities,
        provider: provider,
      );

  Map<String, dynamic> toJson() => {
        "name": name,
        "model": model,
        "modified_at": modifiedAt.toIso8601String(),
        "size": size,
        "digest": digest,
        "parameter_size": parameterSize,
        "provider": provider,
      };

  @override
  String toString() {
    return name;
  }

  @override
  int get hashCode => digest.hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is OllamaModel && other.digest == digest;
  }
}
