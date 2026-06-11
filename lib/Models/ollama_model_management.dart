/// A model currently loaded into memory on the Ollama server (from /api/ps).
class OllamaRunningModel {
  final String name;

  /// Total size of the loaded model in bytes.
  final int size;

  /// Bytes resident in VRAM (the rest spills to system RAM).
  final int sizeVram;

  /// When the server will evict the model if idle.
  final DateTime? expiresAt;

  const OllamaRunningModel({
    required this.name,
    required this.size,
    required this.sizeVram,
    this.expiresAt,
  });

  factory OllamaRunningModel.fromJson(Map<String, dynamic> json) {
    return OllamaRunningModel(
      name: (json['name'] ?? json['model'] ?? '') as String,
      size: (json['size'] as num?)?.toInt() ?? 0,
      sizeVram: (json['size_vram'] as num?)?.toInt() ?? 0,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
    );
  }

  /// Fraction of the model held in VRAM, 0..1. 1.0 = fully on GPU.
  double get vramFraction => size > 0 ? (sizeVram / size).clamp(0.0, 1.0) : 0;
}

/// One progress event from a streaming /api/pull download.
class OllamaPullProgress {
  final String status;
  final int total;
  final int completed;

  const OllamaPullProgress({
    required this.status,
    this.total = 0,
    this.completed = 0,
  });

  factory OllamaPullProgress.fromJson(Map<String, dynamic> json) {
    return OllamaPullProgress(
      status: (json['status'] ?? '') as String,
      total: (json['total'] as num?)?.toInt() ?? 0,
      completed: (json['completed'] as num?)?.toInt() ?? 0,
    );
  }

  /// Download progress 0..1, or null when this phase has no byte count
  /// (manifest verification, etc.).
  double? get fraction =>
      total > 0 ? (completed / total).clamp(0.0, 1.0) : null;

  bool get isDone => status == 'success';
}
