import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A self-hosted service that has to be reachable from two places: the LAN
/// address that works at home, and a remote address that works everywhere
/// else.
///
/// This is the generalisation of what [OllamaService] grew in v3.7.0/v3.7.3 —
/// primary plus backup, sticky on whichever last answered, with Cloudflare
/// Access service-token headers on the https candidate. The voice backends
/// never got any of it, so transcription and speech were LAN-only while chat
/// worked from anywhere: the one address they had was an RFC1918 IP, and off
/// the network it simply failed and fell back to the device recogniser.
///
/// Kept deliberately small and transport-agnostic: it decides *which base to
/// aim at and what headers to carry*, and leaves building and sending the
/// request to the caller, because the two voice backends send very different
/// things (a multipart upload and a JSON post).
class RemoteEndpoint {
  RemoteEndpoint({
    String? primary,
    String? backup,
    String? cfAccessClientId,
    String? cfAccessClientSecret,
  })  : primary = primary ?? '',
        backup = backup ?? '',
        cfAccessClientId = cfAccessClientId ?? '',
        cfAccessClientSecret = cfAccessClientSecret ?? '';

  /// The address that works at home. Usually a plaintext LAN IP.
  String primary;

  /// The address that works from anywhere. Usually a Cloudflare tunnel
  /// hostname, which is why it is the one the Access headers attach to.
  String backup;

  String cfAccessClientId;
  String cfAccessClientSecret;

  /// Whichever candidate last answered. Tried first next time.
  ///
  /// Stickiness matters far more for voice than it did for chat: off the LAN
  /// the primary costs a full 6 s connect timeout, and paying that before
  /// every transcription and every spoken sentence is the difference between
  /// a usable assistant and an unusable one.
  String? _lastGood;

  /// Forgets the sticky choice. Call when the addresses change, so editing
  /// settings can't leave requests pinned to the old server.
  void reset() => _lastGood = null;

  bool get isConfigured => primary.trim().isNotEmpty || backup.trim().isNotEmpty;

  bool get hasCfAccessToken =>
      cfAccessClientId.trim().isNotEmpty && cfAccessClientSecret.trim().isNotEmpty;

  /// True when the last successful request went to the backup address, which
  /// is what the UI shows as "connected remotely".
  bool get isOnBackup {
    final b = normalize(backup);
    return b.isNotEmpty && _lastGood == b;
  }

  /// Adds a scheme if there isn't one and strips trailing slashes, so
  /// `172.16.23.20:8001`, `http://172.16.23.20:8001/` and
  /// `http://172.16.23.20:8001` are the same address.
  ///
  /// A bare hostname gets **https**, a bare IP or anything with a port gets
  /// http: someone typing `speech.example.com` means the tunnel, and sending
  /// an Access service token to it over cleartext would defeat the point.
  static String normalize(String raw) {
    var base = raw.trim();
    if (base.isEmpty) return '';
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      final looksLocal = RegExp(r'^\d{1,3}(\.\d{1,3}){3}').hasMatch(base) ||
          base.contains(':') ||
          base.startsWith('localhost');
      base = '${looksLocal ? 'http' : 'https'}://$base';
    }
    return base.replaceAll(RegExp(r'/+$'), '');
  }

  /// Resolves [path] against [base], tolerating a base that already ends in
  /// `/v1` — which is how every OpenAI-compatible speech server is written
  /// down, and otherwise produces `/v1/v1/audio/...`.
  static Uri resolve(String base, String path) {
    final b = normalize(base);
    if (b.endsWith('/v1') && path.startsWith('/v1/')) {
      return Uri.parse('$b${path.substring('/v1'.length)}');
    }
    return Uri.parse('$b$path');
  }

  /// Candidate bases in the order they should be tried: last known good
  /// first, then primary, then backup. Never empty unless nothing is set.
  List<String> candidates() {
    final urls = <String>{};
    if (_lastGood != null) urls.add(_lastGood!);
    final p = normalize(primary);
    if (p.isNotEmpty) urls.add(p);
    final b = normalize(backup);
    if (b.isNotEmpty) urls.add(b);
    return urls.toList();
  }

  /// Headers to carry when aiming at [base].
  ///
  /// The Access service token rides only on **https** candidates. Same rule
  /// and same reason as [OllamaService.headersFor]: the primary is typically
  /// a cleartext LAN address that ignores the headers entirely, and putting
  /// a long-lived secret on the wire for a host that discards it is pure
  /// downside.
  Map<String, String> headersFor(String base, {String? bearerToken}) {
    final h = <String, String>{};
    final token = bearerToken?.trim() ?? '';
    if (token.isNotEmpty) h['Authorization'] = 'Bearer $token';
    if (hasCfAccessToken && Uri.parse(normalize(base)).scheme == 'https') {
      h['CF-Access-Client-Id'] = cfAccessClientId.trim();
      h['CF-Access-Client-Secret'] = cfAccessClientSecret.trim();
    }
    return h;
  }

  /// Runs [op] against each candidate until one succeeds.
  ///
  /// Only connection-level failures fall through to the next candidate. A
  /// server that answers with an error is a server that is reachable, and
  /// retrying that request against the other address just produces the same
  /// error twice and doubles the wait.
  ///
  /// Throws [StateError] when nothing is configured; rethrows the last
  /// transport error when every candidate failed.
  Future<T> withFailover<T>(Future<T> Function(String base) op) async {
    final urls = candidates();
    if (urls.isEmpty) {
      throw StateError('No server address configured.');
    }
    Object? lastError;
    StackTrace? lastStack;
    for (final url in urls) {
      try {
        final result = await op(url);
        _lastGood = url;
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
        // Not retried against the same base — the server may already be
        // transcribing — but the other address is still worth a try.
        lastError = e;
        lastStack = st;
      }
    }
    if (_lastGood != null && urls.contains(_lastGood)) _lastGood = null;
    Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
  }

  /// Cloudflare Access answers an unauthenticated request with a 302 to its
  /// login page, which the HTTP client follows — so a blocked request arrives
  /// as **200 OK with an HTML body**, and the caller reports a parse error
  /// rather than an auth problem. Returns an explanation when [body] is that
  /// page, and null when it isn't.
  ///
  /// The chat path learned this in v3.7.5; voice needs it for the same reason
  /// now that it can point at a tunnel.
  String? describeAccessBlock(String body, String base) {
    final head = body.trimLeft();
    if (!head.startsWith('<')) return null;
    final lower = head.toLowerCase();
    if (lower.contains('cloudflareaccess.com') ||
        lower.contains('cf-access') ||
        lower.contains('cdn-cgi/access')) {
      return hasCfAccessToken
          ? 'Cloudflare Access rejected the service token for $base. Check '
              'that the Client ID ends in ".access", the secret matches, and '
              'the Access policy Action is "Service Auth".'
          : 'Cloudflare Access is protecting $base but no service token is '
              'configured. Add one in Settings → Server → Cloudflare Access.';
    }
    return 'Got an HTML page instead of an API response from $base — '
        'something between the app and the server (proxy, captive portal, or '
        'tunnel) answered instead.';
  }
}
