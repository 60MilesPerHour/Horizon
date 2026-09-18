import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:horizon/Services/outbound_log.dart';

/// Shared HTTP plumbing for every provider service.
///
/// One persistent client for the whole app instead of a throwaway client per
/// request:
///  - `connectionTimeout` bounds the TCP connect. A blackholed route (the
///    classic ZeroTier/VPN failure mode: packets silently dropped, no RST)
///    fails in seconds instead of hanging for the OS default (~2 minutes),
///    so Ollama failover reaches the backup URL fast.
///  - Persistent connections are reused across requests — one TCP/TLS
///    handshake per host instead of one per message, which matters on
///    high-latency VPN links.
class HorizonHttp {
  HorizonHttp._();

  /// Every outbound request the app makes, in a short rolling window.
  ///
  /// It lives here rather than being injected because this is the one place
  /// every provider, tool and voice backend already funnels through — a
  /// logger wired in per service is a logger the next service forgets.
  static final OutboundLog log = OutboundLog();

  static final http.Client client = _LoggingClient(
    IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 6)
        ..idleTimeout = const Duration(seconds: 90),
    ),
    log,
  );

  /// Sends a freshly-built request, retrying on connection-level errors
  /// (connection reset, closed mid-handshake, connect timeout). The request
  /// must be rebuilt per attempt because [http.Request] can only be sent once.
  ///
  /// Only errors that happen *before* any response bytes arrive are retried,
  /// so a retry can never duplicate a partially-streamed reply.
  static Future<http.StreamedResponse> sendWithRetry(
    http.Request Function() build, {
    Duration timeout = const Duration(seconds: 30),
    int retries = 1,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        return await client.send(build()).timeout(timeout);
      } on SocketException catch (e, st) {
        lastError = e;
        lastStack = st;
      } on http.ClientException catch (e, st) {
        lastError = e;
        lastStack = st;
      } on HttpException catch (e, st) {
        lastError = e;
        lastStack = st;
      }
      if (attempt < retries) {
        await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
  }
}

/// Guards a streamed response body against silent connection death: if no
/// bytes arrive for [stallTimeout], the stream errors out instead of hanging
/// forever. This is the mid-stream counterpart to `connectionTimeout` — a
/// VPN route change or Wi-Fi → cellular switch after streaming has started
/// otherwise leaves the app stuck on "Generating" with no error at all.
extension StallGuard on Stream<List<int>> {
  Stream<List<int>> stallGuard(Duration stallTimeout, String label) {
    return timeout(stallTimeout, onTimeout: (sink) {
      sink.addError(TimeoutException(
        '$label connection stalled: no data received for '
        '${stallTimeout.inSeconds}s. The connection was likely dropped '
        '(VPN route change or network switch). Retry to reconnect.',
      ));
      sink.close();
    });
  }
}


/// Records each request into [HorizonHttp.log] on its way out.
///
/// Wrapping the client rather than logging at each call site means a new
/// provider is covered the day it's added, and a request that bypasses the
/// log is a request that bypassed the shared client — which is itself worth
/// noticing.
///
/// Only metadata is kept: method, host, redacted path, byte counts, and the
/// *names* of any credential headers. Never a body, never a header value.
class _LoggingClient extends http.BaseClient {
  _LoggingClient(this._inner, this._log);

  final http.Client _inner;
  final OutboundLog _log;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final started = DateTime.now();
    final entry = _log.record(OutboundRequest(
      method: request.method,
      host: request.url.host,
      path: OutboundLog.redactPath(request.url),
      startedAt: started,
      requestBytes: request.contentLength ?? 0,
      authHeaders: OutboundLog.credentialHeaders(request.headers),
    ));

    try {
      final response = await _inner.send(request);
      entry.statusCode = response.statusCode;
      entry.responseBytes = response.contentLength ?? 0;
      entry.duration = DateTime.now().difference(started);
      _log.complete(entry);
      return response;
    } catch (e) {
      // A transport failure is the most interesting line in the log — it's
      // the one that says a request left and nothing came back.
      entry.error = e.toString();
      entry.duration = DateTime.now().difference(started);
      _log.complete(entry);
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}
