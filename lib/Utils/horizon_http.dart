import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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

  static final http.Client client = IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 90),
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
