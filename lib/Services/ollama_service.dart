import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:horizon/Utils/http_error_formatter.dart';
import 'package:horizon/Models/api/tags_response.dart';
import 'package:horizon/Models/api/show_response.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Models/api/create_request.dart';
import 'package:horizon/Services/chat_service.dart';

class OllamaService extends ChatService {
  @override
  String get providerId => 'ollama';

  /// True only when the user has set a non-empty primary server address.
  /// Without this we'd always try localhost and dirty the model list.
  bool _userSetAddress = false;

  @override
  bool get isConfigured => _userSetAddress;

  /// Primary URL. Tried first on every request.
  String _baseUrl;

  /// Optional backup URL. Used when the primary fails with a network error.
  /// Common case: primary is a home-LAN address, backup is a Tailscale/VPN
  /// hostname for when the user is off-network. Whichever connects first
  /// becomes the active URL for subsequent requests until it fails.
  String? _backupUrl;

  /// Tracks which URL most recently succeeded. Subsequent requests try this
  /// first to avoid wasting a round-trip on the known-down endpoint.
  String? _activeUrl;

  String get baseUrl => _activeUrl ?? _baseUrl;

  set baseUrl(String? value) {
    _userSetAddress = value != null && value.isNotEmpty;
    _baseUrl = (value == null || value.isEmpty) ? "http://localhost:11434" : value;
    _activeUrl = null;
  }

  String? get backupUrl => _backupUrl;

  set backupUrl(String? value) {
    _backupUrl = (value == null || value.isEmpty) ? null : value;
    _activeUrl = null;
  }

  /// Optional bearer token for authenticated Ollama servers — primarily
  /// Ollama Cloud (ollama.com), but also works with any reverse-proxy that
  /// gates a self-hosted Ollama behind Authorization. Sent as
  /// `Authorization: Bearer <token>` on every request when set. Local
  /// servers without auth simply ignore the header.
  String _apiToken = '';
  String get apiToken => _apiToken;
  set apiToken(String? value) {
    _apiToken = value ?? '';
  }

  /// The headers to include in all network requests. Built per-request so
  /// the bearer token reflects the current setting.
  Map<String, String> get headers {
    final h = <String, String>{'Content-Type': 'application/json'};
    if (_apiToken.isNotEmpty) {
      h['Authorization'] = 'Bearer $_apiToken';
    }
    return h;
  }

  /// Creates a new instance of the Ollama service.
  OllamaService({String? baseUrl, String? backupUrl, String? apiToken})
      : _baseUrl = baseUrl ?? "http://localhost:11434",
        _backupUrl = (backupUrl == null || backupUrl.isEmpty) ? null : backupUrl,
        _apiToken = apiToken ?? '',
        _userSetAddress = baseUrl != null && baseUrl.isNotEmpty;

  /// Ordered list of URLs to try for the next request. Starts with whichever
  /// last succeeded, then falls back to the other(s). Always non-empty.
  List<String> _urlsToTry() {
    final urls = <String>{};
    if (_activeUrl != null) urls.add(_activeUrl!);
    urls.add(_baseUrl);
    if (_backupUrl != null) urls.add(_backupUrl!);
    return urls.toList();
  }

  /// Constructs a URL by resolving the provided path against a given base.
  Uri _build(String base, String path) {
    final baseUri = Uri.parse(base);
    final segments = baseUri.pathSegments.where((s) => s.isNotEmpty).toList();
    final extraSegments = path.split('/').where((s) => s.isNotEmpty).toList();
    return baseUri.replace(pathSegments: [...segments, ...extraSegments]);
  }

  /// Backward-compatible single-URL builder, against the active base URL.
  Uri constructUrl(String path) => _build(baseUrl, path);

  /// Runs [op] against each candidate URL until one succeeds or all fail
  /// with network-level errors. Higher-level HTTP failures (non-200) are
  /// surfaced from whichever URL was active when they happened — they do
  /// NOT trigger failover, because they imply the server is reachable but
  /// rejecting the request.
  Future<T> _withFailover<T>(Future<T> Function(String base) op) async {
    Object? lastError;
    StackTrace? lastStack;
    for (final url in _urlsToTry()) {
      try {
        final result = await op(url);
        _activeUrl = url;
        return result;
      } on SocketException catch (e, st) {
        lastError = e;
        lastStack = st;
      } on TimeoutException catch (e, st) {
        lastError = e;
        lastStack = st;
      } on HttpException catch (e, st) {
        lastError = e;
        lastStack = st;
      }
    }
    Error.throwWithStackTrace(lastError ?? OllamaException('[Ollama] No server reachable.'), lastStack ?? StackTrace.current);
  }

  /// Generates an OllamaMessage.
  ///
  /// This method is responsible for generating an instance of
  /// [OllamaMessage] based on the provided prompt and options.
  ///
  /// [prompt] is the input string used to generate the message.
  /// [options] is a map of additional options that can be used to
  /// customize the generation process. It defaults to an empty map.
  ///
  /// Returns a [Future] that completes with an [OllamaMessage].
  Future<OllamaMessage> generate(
    String prompt, {
    required OllamaChat chat,
  }) async {
    return _withFailover((base) async {
      final url = _build(base, "/api/generate");
      final response = await http.post(
        url,
        headers: headers,
        body: json.encode({
          "model": chat.model,
          "prompt": prompt,
          "system": chat.systemPrompt,
          "options": chat.options.toMap(),
          if (chat.options.think != null) "think": chat.options.think,
          "stream": false,
        }),
      ).timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Request timed out');
      });

      if (response.statusCode == 200) {
        try {
          final jsonBody = json.decode(response.body);
          return OllamaMessage.fromJson(jsonBody);
        } catch (e) {
          throw OllamaException("Invalid response format: ${e.toString()}");
        }
      } else if (response.statusCode == 404) {
        throw OllamaException("[Ollama] ${chat.model} not found on the server.");
      } else if (response.statusCode == 500) {
        throw OllamaException("Internal server error.");
      } else {
        throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
      }
    });
  }

  Stream<OllamaMessage> generateStream(
    String prompt, {
    required OllamaChat chat,
  }) async* {
    final response = await _withFailover((base) async {
      final url = _build(base, '/api/generate');
      final request = http.Request("POST", url);
      request.headers.addAll(headers);
      request.body = json.encode({
        "model": chat.model,
        "prompt": prompt,
        "system": chat.systemPrompt,
        "options": chat.options.toMap(),
        if (chat.options.think != null) "think": chat.options.think,
        "stream": true,
      });
      return request.send().timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Request timed out');
      });
    });

    if (response.statusCode == 200) {
      yield* _processStream(response.stream);
    } else if (response.statusCode == 404) {
      throw OllamaException("[Ollama] ${chat.model} not found on the server.");
    } else if (response.statusCode == 500) {
      throw OllamaException("Internal server error.");
    } else {
      final body = await response.stream.bytesToString();
      throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: body)}');
    }
  }

  /// Sends a chat message to the Ollama service and returns the response.
  ///
  /// This method takes a message and sends it to the Ollama service, which
  /// processes the message and returns a response. The response is then
  /// encapsulated in an [OllamaMessage] object.
  ///
  /// Returns an [OllamaMessage] containing the response from the Ollama service.
  ///
  /// Throws an [Exception] if there is an error during the communication with
  /// the Ollama service.
  Future<OllamaMessage> chat(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
  }) async {
    final encoded = await _prepareMessagesWithSystemPrompt(messages, chat.systemPrompt);
    return _withFailover((base) async {
      final url = _build(base, "/api/chat");
      final response = await http.post(
        url,
        headers: headers,
        body: json.encode({
          "model": chat.model,
          "messages": encoded,
          "options": chat.options.toMap(),
          if (chat.options.think != null) "think": chat.options.think,
          "stream": false,
        }),
      ).timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Request timed out');
      });

      if (response.statusCode == 200) {
        try {
          final jsonBody = json.decode(response.body);
          return OllamaMessage.fromJson(jsonBody);
        } catch (e) {
          throw OllamaException("Invalid response format: ${e.toString()}");
        }
      } else if (response.statusCode == 404) {
        throw OllamaException("[Ollama] ${chat.model} not found on the server.");
      } else if (response.statusCode == 500) {
        throw OllamaException("Internal server error.");
      } else {
        throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
      }
    });
  }

  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
  }) async* {
    final encoded = await _prepareMessagesWithSystemPrompt(messages, chat.systemPrompt);
    final response = await _withFailover((base) async {
      final url = _build(base, '/api/chat');
      final request = http.Request("POST", url);
      request.headers.addAll(headers);
      request.body = json.encode({
        "model": chat.model,
        "messages": encoded,
        "options": chat.options.toMap(),
        if (chat.options.think != null) "think": chat.options.think,
        "stream": true,
      });
      return request.send().timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Request timed out');
      });
    });

    if (response.statusCode == 200) {
      yield* _processStream(response.stream);
    } else if (response.statusCode == 404) {
      throw OllamaException("[Ollama] ${chat.model} not found on the server.");
    } else if (response.statusCode == 500) {
      throw OllamaException("Internal server error.");
    } else {
      final body = await response.stream.bytesToString();
      throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: body)}');
    }
  }

  Stream<OllamaMessage> _processStream(Stream stream) async* {
    String buffer = '';

    await for (var chunk in stream.transform(utf8.decoder)) {
      chunk = buffer + chunk;
      buffer = '';

      final lines = LineSplitter.split(chunk);

      for (var line in lines) {
        if (line.isEmpty) continue;
        try {
          final jsonBody = json.decode(line);
          yield OllamaMessage.fromJson(jsonBody);
        } catch (e) {
          buffer = line;
        }
      }
    }
  }

  // Serializes chat messages with a system prompt.
  Future<List<Map<String, dynamic>>> _prepareMessagesWithSystemPrompt(
    List<OllamaMessage> messages,
    String? systemPrompt,
  ) async {
    final jsonMessages = await Future.wait(messages.map((m) async => await m.toChatJson()));

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      final sp = OllamaMessage(systemPrompt, role: OllamaMessageRole.system);
      jsonMessages.insert(0, await sp.toChatJson());
    }

    return jsonMessages;
  }

  /// Lists the available models on the Ollama service.
  ///
  /// Fetches models from /api/tags and enriches each with capabilities
  /// from /api/show. If /api/show fails for a model, capabilities will be null.
  Future<List<OllamaModel>> listModels() async {
    final tagsResponse = await _fetchTags();

    // Fetch capabilities for each model in parallel
    final models = await Future.wait(
      tagsResponse.models.map((model) async {
        final showResponse = await _showModel(model.name);
        return OllamaModel.from(model, showResponse);
      }),
    );

    return models;
  }

  /// Fetches the list of models from /api/tags
  Future<ApiTagsResponse> _fetchTags() async {
    return _withFailover((base) async {
      final url = _build(base, "/api/tags");
      final response = await http.get(url, headers: headers).timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Request timed out');
      });

      if (response.statusCode == 200) {
        try {
          final jsonBody = json.decode(response.body);
          return ApiTagsResponse.fromJson(jsonBody);
        } catch (e) {
          throw OllamaException("Invalid response format: ${e.toString()}");
        }
      } else if (response.statusCode == 500) {
        throw OllamaException("Internal server error.");
      } else {
        throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
      }
    });
  }

  /// Fetches detailed model information from /api/show
  ///
  /// Returns null if the endpoint is unavailable or returns an error.
  /// This ensures graceful degradation for older Ollama versions. /api/show
  /// is informational, so we DON'T fail over here — we just hit whichever URL
  /// the registry has settled on.
  Future<ApiShowResponse?> _showModel(String name) async {
    try {
      final url = _build(baseUrl, "/api/show");

      final response = await http.post(
        url,
        headers: headers,
        body: json.encode({"model": name}),
      ).timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Request timed out');
      });

      if (response.statusCode == 200) {
        try {
          final jsonBody = json.decode(response.body);
          return ApiShowResponse.fromJson(jsonBody);
        } catch (e) {
          return null;
        }
      }
    } catch (_) {
      // Silently ignore - endpoint may not exist on older Ollama versions
    }

    return null;
  }

  Future<void> createModel(
    String model, {
    required OllamaChat chat,
    List<OllamaMessage>? messages,
  }) async {
    final request = ApiCreateRequest.fromChat(
      model,
      chat: chat,
      messages: messages,
    );
    final encoded = json.encode(await request.toJson());

    await _withFailover((base) async {
      final url = _build(base, "/api/create");
      final response = await http.post(
        url,
        headers: headers,
        body: encoded,
      ).timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Request timed out');
      });

      if (response.statusCode == 200) {
        return;
      } else if (response.statusCode == 500) {
        throw OllamaException("Internal server error.");
      } else {
        throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
      }
    });
  }

  Future<void> deleteModel(String model) async {
    await _withFailover((base) async {
      final url = _build(base, "/api/delete");
      final response = await http.delete(
        url,
        headers: headers,
        body: json.encode({"model": model}),
      ).timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Request timed out');
      });

      if (response.statusCode == 200) {
        return;
      } else if (response.statusCode == 404) {
        throw OllamaException("$model not found on the server.");
      } else if (response.statusCode == 500) {
        throw OllamaException("Internal server error.");
      } else {
        throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
      }
    });
  }
}
