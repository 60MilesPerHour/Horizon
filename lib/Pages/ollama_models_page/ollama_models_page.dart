import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Models/ollama_model_management.dart';
import 'package:horizon/Services/ollama_service.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

/// Manage the models on the Ollama server from inside the app:
/// see what's loaded in (V)RAM, load/unload models, pull new ones with live
/// progress, and delete installed ones. All actions report the server's real
/// error message on failure.
class OllamaModelsPage extends StatefulWidget {
  const OllamaModelsPage({super.key});

  @override
  State<OllamaModelsPage> createState() => _OllamaModelsPageState();
}

class _OllamaModelsPageState extends State<OllamaModelsPage> {
  late final OllamaService _ollama;

  List<OllamaModel> _installed = [];
  List<OllamaRunningModel> _running = [];
  bool _loading = true;
  String? _error;

  /// Models with an in-flight load/unload/delete, to disable their buttons.
  final Set<String> _busy = {};

  // Pull state
  final _pullController = TextEditingController();
  StreamSubscription<OllamaPullProgress>? _pullSubscription;
  OllamaPullProgress? _pullProgress;
  String? _pullingModel;
  String? _pullError;

  @override
  void initState() {
    super.initState();
    _ollama = context.read<OllamaService>();
    _refresh();
  }

  @override
  void dispose() {
    _pullSubscription?.cancel();
    _pullController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = _installed.isEmpty;
      _error = null;
    });

    try {
      final results = await Future.wait([
        _ollama.listModels(),
        _ollama.listRunningModels(),
      ]);
      if (!mounted) return;
      setState(() {
        _installed = (results[0] as List<OllamaModel>)
          ..sort((a, b) => a.name.compareTo(b.name));
        _running = results[1] as List<OllamaRunningModel>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _describe(e);
      });
    }
  }

  String _describe(Object e) =>
      e is OllamaException ? e.message : HttpErrorFormatter.formatException(e);

  bool _isLoaded(String name) => _running.any((m) => m.name == name);

  OllamaRunningModel? _runningInfo(String name) {
    for (final m in _running) {
      if (m.name == name) return m;
    }
    return null;
  }

  Future<void> _runAction(
    String model,
    String verb,
    Future<void> Function() action,
  ) async {
    setState(() => _busy.add(model));
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$model $verb')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to ${verb.split(' ').first.toLowerCase()} $model: ${_describe(e)}'),
            duration: const Duration(seconds: 8),
            showCloseIcon: true,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy.remove(model));
        await _refresh();
      }
    }
  }

  Future<void> _confirmDelete(String model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $model?'),
        content: const Text(
          'This removes the model from the server\'s disk. You can pull it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _runAction(model, 'deleted from server', () => _ollama.deleteModel(model));
    }
  }

  void _startPull() {
    final model = _pullController.text.trim();
    if (model.isEmpty || _pullingModel != null) return;

    setState(() {
      _pullingModel = model;
      _pullProgress = null;
      _pullError = null;
    });

    _pullSubscription = _ollama.pullModel(model).listen(
      (progress) {
        if (mounted) setState(() => _pullProgress = progress);
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _pullError = _describe(e);
            _pullingModel = null;
          });
        }
      },
      onDone: () {
        if (mounted) {
          final ok = _pullProgress?.isDone ?? false;
          setState(() => _pullingModel = null);
          if (ok) {
            _pullController.clear();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$model downloaded')),
            );
            _refresh();
          }
        }
      },
    );
  }

  void _cancelPull() {
    _pullSubscription?.cancel();
    setState(() {
      _pullingModel = null;
      _pullProgress = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server Models'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _installed.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                onPressed: _refresh,
              ),
            ],
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final loaded = _installed.where((m) => _isLoaded(m.name)).toList();
    final unloaded = _installed.where((m) => !_isLoaded(m.name)).toList();

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _buildPullSection(theme),
          const SizedBox(height: 24),
          if (_error != null) ...[
            SelectableText(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 16),
          ],
          if (loaded.isNotEmpty) ...[
            _sectionHeader(theme, 'Loaded in memory', Icons.memory),
            ...loaded.map((m) => _buildModelTile(theme, m, loaded: true)),
            const SizedBox(height: 24),
          ],
          _sectionHeader(theme, 'Installed', Icons.storage),
          if (unloaded.isEmpty && loaded.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No models installed on this server yet — pull one above.'),
            ),
          ...unloaded.map((m) => _buildModelTile(theme, m, loaded: false)),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPullSection(ThemeData theme) {
    final pulling = _pullingModel != null;
    final progress = _pullProgress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _pullController,
          enabled: !pulling,
          decoration: InputDecoration(
            labelText: 'Pull a model',
            hintText: 'e.g. qwen3.6:27b or gemma4:26b',
            border: const OutlineInputBorder(),
            errorText: _pullError,
            errorMaxLines: 5,
            suffixIcon: pulling
                ? IconButton(
                    tooltip: 'Cancel download',
                    icon: const Icon(Icons.stop),
                    onPressed: _cancelPull,
                  )
                : IconButton(
                    tooltip: 'Download to server',
                    icon: const Icon(Icons.download),
                    onPressed: _startPull,
                  ),
          ),
          onSubmitted: (_) => _startPull(),
        ),
        if (pulling) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: progress?.fraction),
          const SizedBox(height: 6),
          Text(
            progress == null
                ? 'Starting…'
                : progress.fraction != null
                    ? '${progress.status} — ${_formatBytes(progress.completed)} / ${_formatBytes(progress.total)} (${(progress.fraction! * 100).toStringAsFixed(0)}%)'
                    : progress.status,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _buildModelTile(ThemeData theme, OllamaModel model, {required bool loaded}) {
    final busy = _busy.contains(model.name);
    final info = loaded ? _runningInfo(model.name) : null;

    final subtitleParts = <String>[
      if (model.parameterSize.isNotEmpty) model.parameterSize,
      if (model.size > 0) _formatBytes(model.size),
      if (info != null && info.sizeVram > 0)
        '${_formatBytes(info.sizeVram)} in VRAM (${(info.vramFraction * 100).toStringAsFixed(0)}% on GPU)',
      if (info?.expiresAt != null) 'evicts ${_formatEviction(info!.expiresAt!)}',
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: loaded
            ? const Tooltip(
                message: 'Loaded in server memory',
                child: Icon(Icons.flash_on, color: Colors.green),
              )
            : const Icon(Icons.flash_off),
        title: Text(model.name),
        subtitle: subtitleParts.isNotEmpty ? Text(subtitleParts.join(' · ')) : null,
        trailing: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loaded)
                    IconButton(
                      tooltip: 'Unload from memory',
                      icon: const Icon(Icons.eject),
                      onPressed: () => _runAction(
                        model.name,
                        'unloaded',
                        () => _ollama.unloadModel(model.name),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: 'Load into memory',
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => _runAction(
                        model.name,
                        'loaded into memory',
                        () => _ollama.loadModel(model.name),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Delete from server',
                    icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                    onPressed: () => _confirmDelete(model.name),
                  ),
                ],
              ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '$bytes B';
  }

  static String _formatEviction(DateTime at) {
    final delta = at.difference(DateTime.now());
    if (delta.isNegative) return 'soon';
    if (delta.inHours >= 24 * 365) return 'never (kept alive)';
    if (delta.inHours >= 1) return 'in ${delta.inHours} h ${delta.inMinutes % 60} min';
    if (delta.inMinutes >= 1) return 'in ${delta.inMinutes} min';
    return 'in under a minute';
  }
}
