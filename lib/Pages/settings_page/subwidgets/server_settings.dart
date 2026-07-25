import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:hive/hive.dart';
import 'package:horizon/Extensions/markdown_stylesheet_extension.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_request_state.dart';
import 'package:horizon/Services/ollama_service.dart';
import 'package:horizon/Utils/http_error_formatter.dart';
import 'package:horizon/Widgets/ollama_bottom_sheet_header.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

class ServerSettings extends StatefulWidget {
  final bool autoFocusServerAddress;

  const ServerSettings({super.key, this.autoFocusServerAddress = false});

  @override
  State<ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<ServerSettings> {
  final _settingsBox = Hive.box('settings');

  final _serverAddressController = TextEditingController();
  final _backupAddressController = TextEditingController();

  OllamaRequestState _requestState = OllamaRequestState.uninitialized;
  OllamaRequestState _backupRequestState = OllamaRequestState.uninitialized;
  get _isLoading => _requestState == OllamaRequestState.loading;

  String? _serverAddressErrorText;
  String? _backupAddressErrorText;

  // Mirrors the Hive 'serverUseBackup' setting; defaults to true so existing
  // installs keep their failover behavior on upgrade.
  bool _useBackup = true;

  @override
  void initState() {
    super.initState();

    _initialize();
  }

  _initialize() {
    final serverAddress = _settingsBox.get('serverAddress');
    final backupAddress = _settingsBox.get('serverAddressBackup');
    _useBackup = _settingsBox.get('serverUseBackup', defaultValue: true) as bool;

    if (serverAddress != null) {
      _serverAddressController.text = serverAddress;
      _handleConnectButton();
    }
    if (backupAddress != null) {
      _backupAddressController.text = backupAddress;
      if (_useBackup) _handleBackupConnectButton();
    }
  }

  @override
  void dispose() {
    _serverAddressController.dispose();
    _backupAddressController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Server',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 16),
        TextField(
          autofocus: widget.autoFocusServerAddress,
          controller: _serverAddressController,
          keyboardType: TextInputType.url,
          onChanged: (_) {
            setState(() {
              _serverAddressErrorText = null;
              _requestState = OllamaRequestState.uninitialized;
            });
          },
          decoration: InputDecoration(
            labelText: 'Ollama Server Address',
            border: OutlineInputBorder(),
            errorText: _serverAddressErrorText,
            suffixIcon: IconButton(
              icon: Icon(Icons.info_outline),
              onPressed: () => _showOllamaInfoBottomSheet(context),
            ),
          ),
          onTapOutside: (PointerDownEvent event) {
            FocusManager.instance.primaryFocus?.unfocus();
          },
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: 8.0,
            runSpacing: 8.0,
            alignment: (Platform.isAndroid || Platform.isIOS)
                ? WrapAlignment.spaceEvenly
                : WrapAlignment.spaceBetween,
            children: [
              ElevatedButton(
                onPressed: _isLoading ? null : _handleSearchLocalNetwork,
                child: const Text('Search Local Network'),
              ),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleConnectButton,
                child: _ConnectionStatusIndicator(
                  color: _connectionStatusColor,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _backupAddressController,
          enabled: _useBackup,
          keyboardType: TextInputType.url,
          onChanged: (_) {
            setState(() {
              _backupAddressErrorText = null;
              _backupRequestState = OllamaRequestState.uninitialized;
            });
          },
          decoration: InputDecoration(
            labelText: 'Backup Server Address (optional)',
            helperText: 'Tried when the primary is unreachable. Use a Cloudflare tunnel hostname (https://…) or a VPN address so home-LAN hosts stay private.',
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            errorText: _backupAddressErrorText,
          ),
          onTapOutside: (PointerDownEvent event) {
            FocusManager.instance.primaryFocus?.unfocus();
          },
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use backup server'),
          subtitle: const Text(
            'Turn off when you only want the primary — prevents the app sticking to a stale VPN/ZeroTier endpoint after a brief primary outage.',
          ),
          value: _useBackup,
          onChanged: (v) {
            setState(() => _useBackup = v);
            _settingsBox.put('serverUseBackup', v);
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton(
            onPressed: (_isLoading || !_useBackup) ? null : _handleBackupConnectButton,
            child: _ConnectionStatusIndicator(
              color: _backupConnectionStatusColor,
            ),
          ),
        ),
        const SizedBox(height: 24),
        const _OllamaTokenField(),
        const SizedBox(height: 24),
        const _CloudflareAccessFields(),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.memory),
          title: const Text('Manage server models'),
          subtitle: const Text(
            'See what\'s loaded in memory, load/unload, pull, and delete models on the server.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).pushNamed('/ollama-models'),
        ),
      ],
    );
  }

  Color get _backupConnectionStatusColor {
    switch (_backupRequestState) {
      case OllamaRequestState.error:
        return Colors.red;
      case OllamaRequestState.loading:
        return Colors.orange;
      case OllamaRequestState.success:
        return Colors.green;
      case OllamaRequestState.uninitialized:
        return Colors.grey;
    }
  }

  _handleBackupConnectButton() async {
    setState(() {
      _backupAddressErrorText = null;
      _backupRequestState = OllamaRequestState.loading;
    });

    final raw = _backupAddressController.text.trim();
    if (raw.isEmpty) {
      // Treat clearing the field as "remove backup".
      _settingsBox.delete('serverAddressBackup');
      setState(() => _backupRequestState = OllamaRequestState.uninitialized);
      return;
    }

    try {
      final newAddress = _validateServerAddress(raw);
      final result = await _establishServerConnection(
        Uri.parse(newAddress),
        headers: context.read<OllamaService>().headersFor(newAddress),
      );

      if (!mounted) return;

      _backupRequestState = result.$1;
      final state = result.$1;
      final addr = result.$2.toString();
      final current = _settingsBox.get('serverAddressBackup');
      // Persist the address even on failure so the user's choice survives
      // a no-network moment; failover will still try it on the next request.
      if (addr != current) {
        _settingsBox.put('serverAddressBackup', addr);
      }
      if (state == OllamaRequestState.error) {
        _backupAddressErrorText = 'Could not reach backup right now (will retry on failover).';
      }
    } on OllamaException catch (e) {
      _backupAddressErrorText = e.message;
      _backupRequestState = OllamaRequestState.error;
    } catch (_) {
      _backupAddressErrorText = 'Invalid URL format. Use: http(s)://<host>:<port>';
      _backupRequestState = OllamaRequestState.error;
    } finally {
      if (mounted) setState(() {});
    }
  }

  Color get _connectionStatusColor {
    switch (_requestState) {
      case OllamaRequestState.error:
        return Colors.red;
      case OllamaRequestState.loading:
        return Colors.orange;
      case OllamaRequestState.success:
        return Colors.green;
      case OllamaRequestState.uninitialized:
        return Colors.grey;
    }
  }

  _handleConnectButton() async {
    setState(() {
      _serverAddressErrorText = null;
      _requestState = OllamaRequestState.loading;
    });

    try {
      // Validate the server address.
      final newAddress = _validateServerAddress(_serverAddressController.text);
      // Establish a connection to the server. Access headers ride along in
      // case the user points the *primary* at the tunnel hostname too.
      final result = await _establishServerConnection(
        Uri.parse(newAddress),
        headers: context.read<OllamaService>().headersFor(newAddress),
      );

      if (!mounted) return;

      _requestState = result.$1;
      _saveServerAddressWith(result);
    } on OllamaException catch (error) {
      _serverAddressErrorText = error.message;
      _requestState = OllamaRequestState.error;
    } catch (_) {
      _serverAddressErrorText =
          'Invalid URL format. Use: http(s)://<host>:<port>';
      _requestState = OllamaRequestState.error;
    } finally {
      setState(() {});
    }
  }

  void _saveServerAddressWith((OllamaRequestState, Uri) result) {
    final state = result.$1;
    final newAddress = result.$2.toString();

    final currentAddress = _settingsBox.get('serverAddress');
    if (state == OllamaRequestState.success && newAddress != currentAddress) {
      _settingsBox.put('serverAddress', newAddress);
    }
  }

  /// Establishes a connection to the Ollama server.
  ///
  /// Returns a tuple of the request state and the given server address.
  static Future<(OllamaRequestState, Uri)> _establishServerConnection(
    Uri serverAddress, {
    Map<String, String>? headers,
  }) async {
    try {
      // 4 s: generous enough for a high-latency VPN hop (ZeroTier relayed
      // path), still fast enough for the local-network scan to finish quickly.
      // [headers] carries the Cloudflare Access service token when the address
      // is a tunnel hostname — without it Access answers 302/403 and the probe
      // would report the server as down even though it's fine.
      final response = await http
          .get(serverAddress, headers: headers)
          .timeout(const Duration(seconds: 4));

      // A Cloudflare Access login page is a 200 with an HTML body (the client
      // followed Access's 302), so status alone would light the dot green on a
      // server we can't actually talk to. Ollama's root answers plain text.
      if (response.statusCode == 200 &&
          response.body.trimLeft().startsWith('<')) {
        return (OllamaRequestState.error, serverAddress);
      }

      if (response.statusCode == 200) {
        return (OllamaRequestState.success, serverAddress);
      } else {
        return (OllamaRequestState.error, serverAddress);
      }
    } catch (e) {
      return (OllamaRequestState.error, serverAddress);
    }
  }

  String _validateServerAddress(String address) {
    if (address.isEmpty) {
      throw OllamaException('Please enter a server address.');
    }

    final url = Uri.parse(address);

    if (url.scheme.isEmpty) {
      throw OllamaException(
        'Please include the scheme. e.g. http://localhost:11434',
      );
    }

    // If user don't include the scheme and just enter host and port like 'localhost:11434'.
    // The parser will consider the host as the scheme, so host will be empty. But actually the scheme is empty.
    if (url.scheme != 'http' && url.scheme != 'https' && url.host.isEmpty) {
      throw OllamaException(
        'Please include the scheme. e.g. http://localhost:11434',
      );
    }

    if (url.host.isEmpty) {
      throw OllamaException(
        'Please include the host. e.g. http://localhost:11434',
      );
    }

    if (url.scheme != 'http' && url.scheme != 'https') {
      throw OllamaException(
        'Invalid scheme. Only http and https are supported.',
      );
    }

    final String formattedAddress =
        "${url.scheme}://${url.host}${url.hasPort ? ":${url.port}" : ""}${url.path}";
    return formattedAddress;
  }

  void _showOllamaInfoBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return _OllamaInfoBottomSheet();
      },
    );
  }

  void _handleSearchLocalNetwork() async {
    setState(() {
      _serverAddressErrorText = null;
      _requestState = OllamaRequestState.loading;
    });

    try {
      final result = await Isolate.run(() => _searchLocalNetwork());
      final foundAddress = result.$2.toString();

      if (!mounted) return;

      // Update the server address text field with the found address.
      _serverAddressController.text = foundAddress;

      _requestState = result.$1;
      _saveServerAddressWith(result);
    } on OllamaException catch (e) {
      _serverAddressErrorText = e.message;
      _requestState = OllamaRequestState.error;
    } catch (e) {
      _serverAddressErrorText =
          'Network scan failed: ${HttpErrorFormatter.formatException(e)}';
      _requestState = OllamaRequestState.error;
    } finally {
      setState(() {});
    }
  }

  static Future<(OllamaRequestState, Uri)> _searchLocalNetwork() async {
    final networkInterfaces = await NetworkInterface.list(
      includeLoopback: true,
      type: InternetAddressType.IPv4,
    );

    final futures = <Future<(OllamaRequestState, Uri)>>[];
    for (var interface in networkInterfaces) {
      for (var address in interface.addresses) {
        if (address.isLoopback) {
          final url = Uri.parse('http://${address.address}:11434');
          futures.add(_establishServerConnection(url));
        } else {
          final segments = address.address.split('.');
          for (int i = 1; i < 255; i++) {
            final url = Uri.parse(
              'http://${segments[0]}.${segments[1]}.${segments[2]}.$i:11434',
            );
            futures.add(_establishServerConnection(url));
          }
        }
      }
    }

    final results = await Future.wait(futures);

    final result = results.firstWhere(
      (result) => result.$1 == OllamaRequestState.success,
      orElse: () =>
          throw OllamaException('No Ollama server found on the local network.'),
    );

    return result;
  }
}

class _ConnectionStatusIndicator extends StatelessWidget {
  final Color color;

  const _ConnectionStatusIndicator({
    super.key,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Connect'),
        const SizedBox(width: 10),
        Container(
          width: MediaQuery.of(context).textScaler.scale(10),
          height: MediaQuery.of(context).textScaler.scale(10),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _OllamaInfoBottomSheet extends StatelessWidget {
  const _OllamaInfoBottomSheet({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      minimum: EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OllamaBottomSheetHeader(title: 'What is Ollama?'),
          Divider(),
          Expanded(
            child: ListView(
              children: [
                MarkdownBody(
                  data:
                      "Ollama is a free platform that enables you to run advanced large language models (LLMs) like Llama 3.3, Phi 3, Mistral, Gemma 2, and more directly on your local machine. This setup enhances privacy, security, and control over your AI interactions. Ollama also allows you to customize and create your own models.\n\nTo get started with Ollama, visit their official website: [ollama.com](https://ollama.com). Here, you can explore various models and download the platform to begin using Ollama.",
                  styleSheet: context.markdownStyleSheet,
                  onTapLink: (_, href, __) => launchUrlString(href!),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Cloudflare Access service-token credentials, used when the backup address
/// is a tunnel hostname sitting behind an Access application. Both halves are
/// saved together — a half-configured token is worse than none, because the
/// request looks authenticated and still gets a 403.
class _CloudflareAccessFields extends StatefulWidget {
  const _CloudflareAccessFields();

  @override
  State<_CloudflareAccessFields> createState() =>
      _CloudflareAccessFieldsState();
}

class _CloudflareAccessFieldsState extends State<_CloudflareAccessFields> {
  static const _storage = FlutterSecureStorage();

  final _idController = TextEditingController();
  final _secretController = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _idController.text = await _storage.read(key: 'cf_access_client_id') ?? '';
      _secretController.text =
          await _storage.read(key: 'cf_access_client_secret') ?? '';
    } catch (_) {
      // ignore — keystore may be unavailable on Linux without a keyring
    } finally {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _save() async {
    final id = _idController.text.trim();
    final secret = _secretController.text.trim();
    final service = context.read<OllamaService>();

    Future<void> put(String key, String value) async {
      try {
        if (value.isEmpty) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: value);
        }
      } catch (_) {}
    }

    await put('cf_access_client_id', id);
    await put('cf_access_client_secret', secret);
    service.cfAccessClientId = id;
    service.cfAccessClientSecret = secret;

    if (!mounted) return;
    final String message;
    if (id.isEmpty && secret.isEmpty) {
      message = 'Access service token cleared';
    } else if (id.isEmpty || secret.isEmpty) {
      message = 'Both Client ID and Client Secret are required';
    } else {
      message = 'Access service token saved';
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _idController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cloudflare Access (optional)',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _idController,
          enabled: _loaded,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
            labelText: 'Access Client ID',
            helperText:
                'Service-token credentials for a backup address behind a Cloudflare tunnel. Sent only to https:// endpoints.',
            helperMaxLines: 3,
            hintText: '....access',
            border: OutlineInputBorder(),
          ),
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _secretController,
          enabled: _loaded,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'Access Client Secret',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                IconButton(
                  icon: const Icon(Icons.save),
                  onPressed: _save,
                ),
              ],
            ),
          ),
          onSubmitted: (_) => _save(),
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        ),
      ],
    );
  }
}

class _OllamaTokenField extends StatefulWidget {
  const _OllamaTokenField();

  @override
  State<_OllamaTokenField> createState() => _OllamaTokenFieldState();
}

class _OllamaTokenFieldState extends State<_OllamaTokenField> {
  static const _storage = FlutterSecureStorage();

  final _controller = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await _storage.read(key: 'ollama_api_token');
      if (!mounted) return;
      _controller.text = v ?? '';
    } catch (_) {
      // ignore — keystore may be unavailable on Linux without a keyring
    } finally {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    final service = context.read<OllamaService>();
    if (value.isEmpty) {
      try {
        await _storage.delete(key: 'ollama_api_token');
      } catch (_) {}
      service.apiToken = '';
    } else {
      try {
        await _storage.write(key: 'ollama_api_token', value: value);
      } catch (_) {}
      service.apiToken = value;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value.isEmpty ? 'Ollama token cleared' : 'Ollama token saved')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      enabled: _loaded,
      obscureText: _obscure,
      decoration: InputDecoration(
        labelText: 'Ollama API Token (optional)',
        helperText: 'Bearer token sent as Authorization header. Required for Ollama Cloud (ollama.com); local servers without auth ignore it.',
        helperMaxLines: 3,
        hintText: 'olc-... or your reverse-proxy token',
        border: const OutlineInputBorder(),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _save,
            ),
          ],
        ),
      ),
      onSubmitted: (_) => _save(),
    );
  }
}
