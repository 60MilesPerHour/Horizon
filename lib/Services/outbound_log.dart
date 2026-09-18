import 'dart:collection';

/// A record of one HTTP request Horizon actually made.
///
/// Recorded at the transport, not built from application state: the whole
/// point is to be evidence rather than a second description of what the code
/// intends to do. A panel that reconstructs "what we would have sent" agrees
/// with the bug that sent something else.
class OutboundRequest {
  OutboundRequest({
    required this.method,
    required this.host,
    required this.path,
    required this.startedAt,
    required this.requestBytes,
    required this.authHeaders,
    this.chatLabel,
  });

  final String method;
  final String host;

  /// Path plus query, with the value of anything key-shaped replaced. SerpAPI
  /// takes its key as `?api_key=`, so logging a raw query string would put a
  /// live credential on screen.
  final String path;

  final DateTime startedAt;

  /// Body size in bytes. Not the body: a log holding message text would be a
  /// second copy of every conversation.
  final int requestBytes;

  /// Names of the credential-bearing headers that were attached, never their
  /// values — screenshots of this page end up in bug reports.
  final List<String> authHeaders;

  /// Which chat the request belongs to, when the caller knows.
  final String? chatLabel;

  int? statusCode;
  int responseBytes = 0;
  Duration? duration;

  /// Transport-level failure (no response at all).
  String? error;

  bool get isComplete => statusCode != null || error != null;
  bool get isFailure => error != null || (statusCode != null && statusCode! >= 400);
  bool get hasCredential => authHeaders.isNotEmpty;
}

/// A short rolling window of outbound requests, held in memory only.
///
/// Deliberately not persisted. An on-disk traffic log would outlive the
/// session it describes and become exactly the thing this feature exists to
/// warn about: a durable plaintext record of everything you sent.
class OutboundLog {
  OutboundLog({this.capacity = 200});

  /// Oldest entries are dropped past this. Enough to cover a conversation and
  /// its tool calls, small enough to stay cheap.
  final int capacity;

  final ListQueue<OutboundRequest> _entries = ListQueue<OutboundRequest>();

  /// Newest first, which is the order anyone reads a log in.
  List<OutboundRequest> get entries => _entries.toList().reversed.toList();

  int get length => _entries.length;

  /// Bumped on every change so the viewer can rebuild without the log having
  /// to be a ChangeNotifier that every service then depends on.
  int revision = 0;

  OutboundRequest record(OutboundRequest request) {
    _entries.addLast(request);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    revision++;
    return request;
  }

  void complete(OutboundRequest request) => revision++;

  void clear() {
    _entries.clear();
    revision++;
  }

  /// Hosts seen this session, with how many requests went to each.
  Map<String, int> get hostCounts {
    final counts = <String, int>{};
    for (final entry in _entries) {
      counts[entry.host] = (counts[entry.host] ?? 0) + 1;
    }
    return counts;
  }

  /// Query parameters whose value is a credential rather than a query. Every
  /// one of these is something Horizon itself sends, so the list is closed
  /// rather than a guess at what a key looks like.
  static const Set<String> _secretParams = {
    'api_key',
    'apikey',
    'key',
    'access_token',
    'token',
    'auth',
  };

  /// Request headers that carry a credential.
  static const Set<String> _secretHeaders = {
    'authorization',
    'x-api-key',
    'x-goog-api-key',
    'cf-access-client-id',
    'cf-access-client-secret',
    'xi-api-key',
  };

  /// Path and query with secret values replaced. Keeps the parameter *names*,
  /// because "it sent an api_key" is the useful part; the value never is.
  static String redactPath(Uri uri) {
    if (uri.queryParameters.isEmpty) {
      return uri.path.isEmpty ? '/' : uri.path;
    }
    final redacted = <String, String>{
      for (final entry in uri.queryParameters.entries)
        entry.key: _secretParams.contains(entry.key.toLowerCase())
            ? '<redacted>'
            : entry.value,
    };
    final query = redacted.entries
        .map((e) => '${e.key}=${e.value}')
        .join('&');
    return '${uri.path.isEmpty ? '/' : uri.path}?$query';
  }

  /// Names of the credential-bearing headers on a request.
  static List<String> credentialHeaders(Map<String, String> headers) {
    final found = <String>[];
    for (final name in headers.keys) {
      if (_secretHeaders.contains(name.toLowerCase())) found.add(name);
    }
    found.sort();
    return found;
  }
}
