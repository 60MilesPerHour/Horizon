import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Utils/http_error_formatter.dart';
import 'package:horizon/Models/api/tags_response.dart';
import 'package:horizon/Models/ollama_model_management.dart';
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

  /// True when the most recently successful URL is the backup. Used by the
  /// health indicator to surface a "degraded" state to the user.
  bool get isOnBackup => _activeUrl != null && _activeUrl == _backupUrl && _activeUrl != _baseUrl;

  /// Fired after every _withFailover() call. `success` is true if any URL
  /// served the request; false if all candidates failed. Used by
  /// OllamaHealthMonitor to update the UI without an extra round-trip.
  void Function(bool success)? onRequestComplete;

  /// The error from the most recent total failover failure (every candidate
  /// URL failed). Cleared on the next success. Lets the health indicator say
  /// WHY the server is down instead of just showing a red dot.
  Object? _lastFailure;
  Object? get lastFailure => _lastFailure;

  /// Time-to-response-headers budget for chat/generate. Ollama only writes
  /// headers after the model is loaded, so a cold load of a 27B model can
  /// legitimately take minutes. Connect-level failures surface in ~6 s via
  /// the shared client's connectionTimeout, so a long budget here doesn't
  /// slow down failover.
  static const Duration _chatHeadersTimeout = Duration(seconds: 180);

  /// Max silence between stream chunks before we declare the connection dead.
  /// Long enough for heavy prompt-eval pauses, short enough to catch a
  /// silently dropped VPN route instead of hanging on "Generating" forever.
  static const Duration _stallTimeout = Duration(seconds: 120);

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

  /// Master switch for using the backup URL. When false, failover never
  /// touches the backup even if one is configured — useful when the user
  /// is on the LAN and a stale Tailscale/ZeroTier endpoint would otherwise
  /// get picked up after a transient primary blip and "stick" via
  /// [_activeUrl]. Toggling this also clears the sticky active URL so the
  /// next request starts fresh from the primary.
  bool _useBackup = true;
  bool get useBackup => _useBackup;
  set useBackup(bool value) {
    if (value == _useBackup) return;
    _useBackup = value;
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
  /// Honors [useBackup]: when disabled, the backup URL is never tried even
  /// if `_activeUrl` happens to point at it (which can't happen after the
  /// setter clears it, but we belt-and-suspenders here for safety).
  List<String> _urlsToTry() {
    final urls = <String>{};
    if (_activeUrl != null && (_useBackup || _activeUrl != _backupUrl)) {
      urls.add(_activeUrl!);
    }
    urls.add(_baseUrl);
    if (_useBackup && _backupUrl != null) urls.add(_backupUrl!);
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
  ///
  /// Each URL is retried [retriesPerUrl] additional times on transient
  /// connection-level errors (SocketException, HttpException, ClientException)
  /// before falling over to the next candidate. This catches the common
  /// ZeroTier/VPN failure mode where the first packet fails but the link
  /// recovers a moment later. TimeoutException is NOT retried on the same
  /// URL because the server may already be processing the request, and a
  /// retry would re-trigger generation.
  Future<T> _withFailover<T>(
    Future<T> Function(String base) op, {
    int retriesPerUrl = 1,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    for (final url in _urlsToTry()) {
      for (int attempt = 0; attempt <= retriesPerUrl; attempt++) {
        try {
          final result = await op(url);
          _activeUrl = url;
          _lastFailure = null;
          onRequestComplete?.call(true);
          return result;
        } on SocketException catch (e, st) {
          lastError = e;
          lastStack = st;
        } on HttpException catch (e, st) {
          lastError = e;
          lastStack = st;
        } on http.ClientException catch (e, st) {
          lastError = e;
          lastStack = st;
        } on TimeoutException catch (e, st) {
          lastError = e;
          lastStack = st;
          break; // Don't retry timeouts: server may be processing.
        }
        if (attempt < retriesPerUrl) {
          await Future.delayed(Duration(milliseconds: 250 * (1 << attempt)));
        }
      }
    }
    _lastFailure = lastError;
    onRequestComplete?.call(false);
    Error.throwWithStackTrace(lastError ?? OllamaException('[Ollama] No server reachable.'), lastStack ?? StackTrace.current);
  }

  /// Lightweight reachability probe. Hits /api/tags through the normal
  /// failover path (so [isOnBackup] reflects reality afterwards) but with
  /// zero retries and a short timeout — the probe should fail fast.
  Future<void> ping() async {
    await _withFailover((base) async {
      final url = _build(base, '/api/tags');
      final response = await HorizonHttp.client.get(url, headers: headers).timeout(
        const Duration(seconds: 4),
        onTimeout: () => throw TimeoutException('Ollama ping timed out (no reply within 4 s)'),
      );
      if (response.statusCode != 200) {
        throw OllamaException('[Ollama] ping failed: HTTP ${response.statusCode}');
      }
    }, retriesPerUrl: 0);
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
      final response = await HorizonHttp.client.post(
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
      ).timeout(const Duration(seconds: 120), onTimeout: () {
        throw TimeoutException('Ollama did not answer /api/generate within 120 s');
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
      return HorizonHttp.client.send(request).timeout(_chatHeadersTimeout, onTimeout: () {
        throw TimeoutException(
            'Ollama accepted the connection but sent no response for ${_chatHeadersTimeout.inSeconds} s. '
            'The server may be stuck loading the model — check it with `ollama ps`.');
      });
    });

    if (response.statusCode == 200) {
      yield* _processStream(response.stream.stallGuard(_stallTimeout, '[Ollama]'));
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
      final response = await HorizonHttp.client.post(
        url,
        headers: headers,
        body: json.encode({
          "model": chat.model,
          "messages": encoded,
          "options": chat.options.toMap(),
          if (chat.options.think != null) "think": chat.options.think,
          "stream": false,
        }),
      ).timeout(const Duration(seconds: 120), onTimeout: () {
        throw TimeoutException('Ollama did not answer /api/chat within 120 s');
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
      return HorizonHttp.client.send(request).timeout(_chatHeadersTimeout, onTimeout: () {
        throw TimeoutException(
            'Ollama accepted the connection but sent no response for ${_chatHeadersTimeout.inSeconds} s. '
            'The server may be stuck loading the model — check it with `ollama ps`.');
      });
    });

    if (response.statusCode == 200) {
      yield* _processStream(response.stream.stallGuard(_stallTimeout, '[Ollama]'));
    } else if (response.statusCode == 404) {
      throw OllamaException("[Ollama] ${chat.model} not found on the server.");
    } else if (response.statusCode == 500) {
      throw OllamaException("Internal server error.");
    } else {
      final body = await response.stream.bytesToString();
      throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: body)}');
    }
  }

  Stream<OllamaMessage> _processStream(Stream<List<int>> stream) async* {
    String buffer = '';

    await for (var chunk in stream.transform(utf8.decoder)) {
      chunk = buffer + chunk;
      buffer = '';

      final lines = LineSplitter.split(chunk);

      for (var line in lines) {
        if (line.isEmpty) continue;

        Map<String, dynamic> jsonBody;
        try {
          jsonBody = json.decode(line) as Map<String, dynamic>;
        } catch (e) {
          // Partial line split across chunks — stitch it onto the next one.
          buffer = line;
          continue;
        }

        // Ollama reports mid-generation failures (OOM, model crash, context
        // overflow) as an {"error": "..."} line on an otherwise-200 stream.
        // Previously this was swallowed and the reply just stopped silently.
        final error = jsonBody['error'];
        if (error != null) {
          throw OllamaException('[Ollama] Server error during generation: $error');
        }

        yield OllamaMessage.fromJson(jsonBody);
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
      final response = await HorizonHttp.client.get(url, headers: headers).timeout(const Duration(seconds: 15), onTimeout: () {
        throw TimeoutException('Ollama did not answer /api/tags within 15 s');
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

      final response = await HorizonHttp.client.post(
        url,
        headers: headers,
        body: json.encode({"model": name}),
      ).timeout(const Duration(seconds: 10), onTimeout: () {
        throw TimeoutException('Ollama did not answer /api/show within 10 s');
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
      final response = await HorizonHttp.client.post(
        url,
        headers: headers,
        body: encoded,
      ).timeout(const Duration(seconds: 60), onTimeout: () {
        throw TimeoutException('Ollama did not answer /api/create within 60 s');
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
      final request = http.Request("DELETE", url);
      request.headers.addAll(headers);
      request.body = json.encode({"model": model});
      final streamed = await HorizonHttp.client.send(request).timeout(const Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Ollama did not answer /api/delete within 30 s');
      });
      final response = await http.Response.fromStream(streamed);

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

  // ============================================================
  // Server model management (load / unload / pull / running list)
  // ============================================================

  /// Lists models currently loaded in memory on the server (GET /api/ps).
  Future<List<OllamaRunningModel>> listRunningModels() async {
    return _withFailover((base) async {
      final url = _build(base, "/api/ps");
      final response = await HorizonHttp.client.get(url, headers: headers).timeout(const Duration(seconds: 10), onTimeout: () {
        throw TimeoutException('Ollama did not answer /api/ps within 10 s');
      });

      if (response.statusCode != 200) {
        throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
      }
      final jsonBody = json.decode(response.body) as Map<String, dynamic>;
      final models = jsonBody['models'] as List<dynamic>? ?? const [];
      return models
          .map((m) => OllamaRunningModel.fromJson(m as Map<String, dynamic>))
          .toList();
    });
  }

  /// Loads [model] into server memory by sending an empty /api/generate
  /// request. [keepAlive] follows Ollama syntax: "5m", "1h", "-1" (forever).
  /// Returns when the model is resident — a cold load of a large model can
  /// take minutes, hence the generous timeout. Not retried per URL so a slow
  /// load can't trigger a second, competing load.
  Future<void> loadModel(String model, {String keepAlive = "30m"}) async {
    await _withFailover((base) async {
      final url = _build(base, "/api/generate");
      final response = await HorizonHttp.client.post(
        url,
        headers: headers,
        body: json.encode({"model": model, "keep_alive": keepAlive, "stream": false}),
      ).timeout(const Duration(minutes: 10), onTimeout: () {
        throw TimeoutException('Loading $model took longer than 10 minutes — check the server with `ollama ps`.');
      });

      if (response.statusCode == 404) {
        throw OllamaException("[Ollama] $model is not installed on the server.");
      } else if (response.statusCode != 200) {
        throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
      }
    }, retriesPerUrl: 0);
  }

  /// Unloads [model] from server memory immediately (keep_alive: 0).
  Future<void> unloadModel(String model) async {
    await _withFailover((base) async {
      final url = _build(base, "/api/generate");
      final response = await HorizonHttp.client.post(
        url,
        headers: headers,
        body: json.encode({"model": model, "keep_alive": 0, "stream": false}),
      ).timeout(const Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Ollama did not confirm the unload within 30 s');
      });

      if (response.statusCode != 200) {
        throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
      }
    });
  }

  /// Downloads [model] onto the server (POST /api/pull), yielding progress
  /// events. Throws OllamaException with the server's message on failure
  /// (unknown model, no space, registry unreachable, ...).
  Stream<OllamaPullProgress> pullModel(String model) async* {
    final response = await _withFailover((base) async {
      final url = _build(base, "/api/pull");
      final request = http.Request("POST", url);
      request.headers.addAll(headers);
      request.body = json.encode({"model": model, "stream": true});
      return HorizonHttp.client.send(request).timeout(const Duration(seconds: 60), onTimeout: () {
        throw TimeoutException('Ollama did not start the pull within 60 s');
      });
    }, retriesPerUrl: 0);

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw OllamaException('[Ollama] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: body)}');
    }

    String buffer = '';
    // Stall guard is generous: between progress lines the server may be
    // verifying multi-GB layers, which takes a while on spinning disks.
    await for (var chunk in response.stream.stallGuard(const Duration(minutes: 5), '[Ollama pull]').transform(utf8.decoder)) {
      chunk = buffer + chunk;
      buffer = '';
      for (final line in LineSplitter.split(chunk)) {
        if (line.isEmpty) continue;
        Map<String, dynamic> jsonBody;
        try {
          jsonBody = json.decode(line) as Map<String, dynamic>;
        } catch (_) {
          buffer = line;
          continue;
        }
        final error = jsonBody['error'];
        if (error != null) {
          throw OllamaException('[Ollama] Pull failed: $error');
        }
        yield OllamaPullProgress.fromJson(jsonBody);
      }
    }
  }
}
