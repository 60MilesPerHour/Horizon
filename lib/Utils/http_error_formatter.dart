import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A utility class for formatting HTTP errors and exceptions into human-readable messages.
///
/// Provides static methods to convert common network exceptions and HTTP status codes
/// into user-friendly error messages. The goal: never show a bare
/// "something went wrong" — always say WHAT failed so the user can fix it.
class HttpErrorFormatter {
  HttpErrorFormatter._(); // Private constructor - use static methods

  /// Converts common exceptions to human-readable error messages.
  static String formatException(Object error) {
    if (error is TimeoutException) {
      // Stall-guard and ping timeouts carry a specific, actionable message —
      // surface it verbatim instead of flattening to a generic line.
      final msg = error.message;
      if (msg != null && msg.isNotEmpty) return msg;
      return 'Connection timed out. The server did not respond in time.';
    } else if (error is SocketException) {
      final message = error.message.toLowerCase();
      final os = error.osError?.message ?? '';
      final detail = os.isNotEmpty ? os : error.message;
      if (message.contains('timed out') || os.toLowerCase().contains('timed out')) {
        return 'Could not connect: the host is not answering ($detail). '
            'It may be off, blocked by a firewall, or the VPN route may be down.';
      } else if (message.contains('no route to host') || message.contains('network is unreachable')) {
        return 'Network unreachable ($detail). Check your internet/VPN connection.';
      } else if (message.contains('connection refused')) {
        return 'Connection refused ($detail). The host is up but nothing is listening on that port — is the server running?';
      } else if (message.contains('no address associated') || message.contains('failed host lookup')) {
        return 'DNS lookup failed for the server hostname ($detail). Verify the address in settings, or use an IP.';
      } else if (message.contains('connection reset') || message.contains('broken pipe')) {
        return 'Connection dropped mid-request ($detail). The network path changed or the server closed the connection.';
      }
      return 'Network error: ${error.message}${os.isNotEmpty ? ' ($os)' : ''}';
    } else if (error is HandshakeException) {
      return 'SSL/TLS handshake failed: ${error.message}. Check the server certificate or use http:// for local servers.';
    } else if (error is TlsException) {
      return 'Secure connection failed: ${error.message}. Check the server certificate.';
    } else if (error is HttpException) {
      return 'HTTP error: ${error.message}';
    } else if (error is http.ClientException) {
      return 'Connection error: ${error.message}. The connection was likely interrupted — retry usually fixes this.';
    } else if (error is FormatException) {
      return 'Unexpected response format: ${error.message}. The address may not point at a compatible server.';
    }
    // Last resort: never hide the error class or its message.
    return 'Unexpected error (${error.runtimeType}): $error';
  }

  /// Converts HTTP status codes to human-readable error messages.
  ///
  /// [statusCode] is the HTTP status code returned by the server.
  /// [body] is the optional response body. If it is a JSON error envelope
  /// (every provider wraps the real message in one), the actual message is
  /// extracted and shown; otherwise a trimmed body is appended.
  ///
  /// Returns a formatted error message with the status code and detail.
  static String formatHttpError(int statusCode, {String? body}) {
    final reason = switch (statusCode) {
      400 => 'Bad request. The server rejected the request payload.',
      401 => 'Unauthorized. Please check your API key.',
      402 => 'Payment required. Check your account credits/billing.',
      403 => 'Access forbidden. You don\'t have permission to access this server.',
      404 => 'Resource not found. The requested model or endpoint does not exist.',
      408 => 'Request timed out. Please try again.',
      413 => 'Request too large. Trim the conversation or attachments.',
      429 => 'Too many requests / rate limited. Please wait and try again.',
      500 => 'Internal server error. The server encountered a problem.',
      502 => 'Bad gateway. There may be a problem with the server or proxy',
      503 => 'Service unavailable. The server is temporarily down or overloaded.',
      504 => 'Gateway timeout. The server took too long to respond.',
      529 => 'The API is overloaded. Please wait and try again.',
      _ => 'Server returned an error.',
    };

    final detail = _extractErrorDetail(body);

    if (detail == null) {
      return '$reason\n(HTTP $statusCode)';
    }

    return '$reason\n(HTTP $statusCode)\n\n$detail';
  }

  /// Pulls the real error message out of a provider's JSON error envelope:
  ///   Ollama:            {"error": "model 'x' not found"}
  ///   OpenAI/Anthropic:  {"error": {"message": "...", "type": "..."}}
  ///   Google:            {"error": {"message": "...", "status": "..."}}
  /// Falls back to the trimmed raw body, capped so an HTML error page from a
  /// proxy can't flood the chat with markup.
  static String? _extractErrorDetail(String? body) {
    final trimmed = body?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;

    try {
      final decoded = json.decode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is String && error.isNotEmpty) return error;
        if (error is Map<String, dynamic>) {
          final message = error['message'];
          if (message is String && message.isNotEmpty) {
            final type = error['type'] ?? error['status'] ?? error['code'];
            return type is String && type.isNotEmpty ? '$message ($type)' : message;
          }
        }
        final message = decoded['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // Not JSON — fall through to the raw-body path.
    }

    // An HTML error page (reverse proxy / captive portal) is noise, not signal.
    if (trimmed.startsWith('<')) {
      return 'The server returned an HTML page instead of an API response — '
          'likely a proxy error page or captive portal.';
    }

    return trimmed.length > 600 ? '${trimmed.substring(0, 600)}…' : trimmed;
  }
}
