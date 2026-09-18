import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/outbound_log.dart';

/// The log exists to be shown to someone worried about what left the device,
/// and its screenshots end up in bug reports — so the tests are mostly about
/// what must never appear in it.
void main() {
  group('redaction', () {
    test("SerpAPI's key never reaches the log", () {
      // SerpAPI takes the key as a query parameter, so a raw path would put a
      // live credential on screen.
      final uri = Uri.https('serpapi.com', '/search', {
        'engine': 'google',
        'q': 'ollama release notes',
        'api_key': 'sk-live-secret-value',
        'num': '5',
      });
      final path = OutboundLog.redactPath(uri);

      expect(path, isNot(contains('sk-live-secret-value')));
      expect(path, contains('api_key=<redacted>'));
      // The non-secret parts survive: the point is to see what was asked.
      expect(path, contains('q=ollama release notes'));
    });

    test('other key-shaped parameters are redacted too', () {
      for (final name in ['key', 'apikey', 'access_token', 'token', 'auth']) {
        final uri = Uri.https('example.com', '/v1', {name: 'secret'});
        expect(OutboundLog.redactPath(uri), isNot(contains('secret')),
            reason: name);
      }
    });

    test('a path with no query is left alone', () {
      expect(
        OutboundLog.redactPath(Uri.parse('http://192.168.1.10:11434/api/chat')),
        '/api/chat',
      );
    });

    test('an empty path reads as /', () {
      expect(OutboundLog.redactPath(Uri.parse('https://openrouter.ai')), '/');
    });

    test('credential headers are listed by name only', () {
      final found = OutboundLog.credentialHeaders({
        'Authorization': 'Bearer sk-or-v1-secret',
        'Content-Type': 'application/json',
        'X-Api-Key': 'another-secret',
        'HTTP-Referer': 'https://github.com/60MilesPerHour/Horizon',
      });

      expect(found, ['Authorization', 'X-Api-Key']);
      expect(found.join(), isNot(contains('secret')));
    });

    test('Cloudflare Access and ElevenLabs headers count as credentials', () {
      expect(
        OutboundLog.credentialHeaders({
          'CF-Access-Client-Id': 'id',
          'CF-Access-Client-Secret': 'secret',
          'xi-api-key': 'key',
        }).length,
        3,
      );
    });

    test('a request with no credential reports none', () {
      expect(
        OutboundLog.credentialHeaders({'Content-Type': 'application/json'}),
        isEmpty,
      );
    });
  });

  group('rolling window', () {
    OutboundRequest request(String host) => OutboundRequest(
          method: 'POST',
          host: host,
          path: '/api/chat',
          startedAt: DateTime.now(),
          requestBytes: 100,
          authHeaders: const [],
        );

    test('keeps newest first', () {
      final log = OutboundLog();
      log.record(request('a.example'));
      log.record(request('b.example'));

      expect(log.entries.first.host, 'b.example');
    });

    test('drops the oldest past capacity rather than growing', () {
      // Unbounded would make this a durable copy of session traffic, which is
      // the thing the privacy page warns about.
      final log = OutboundLog(capacity: 3);
      for (var i = 0; i < 10; i++) {
        log.record(request('host$i.example'));
      }

      expect(log.length, 3);
      expect(log.entries.first.host, 'host9.example');
      expect(log.entries.last.host, 'host7.example');
    });

    test('counts requests per host', () {
      final log = OutboundLog();
      log.record(request('openrouter.ai'));
      log.record(request('openrouter.ai'));
      log.record(request('192.168.1.10'));

      expect(log.hostCounts, {'openrouter.ai': 2, '192.168.1.10': 1});
    });

    test('clear empties it', () {
      final log = OutboundLog()..record(request('a.example'));
      log.clear();
      expect(log.entries, isEmpty);
    });

    test('a failed request is marked as such', () {
      final entry = request('unreachable.example')
        ..error = 'SocketException: Connection refused';
      expect(entry.isFailure, isTrue);
      expect(entry.isComplete, isTrue);
    });

    test('a 4xx counts as a failure, a 200 does not', () {
      expect((request('a.example')..statusCode = 401).isFailure, isTrue);
      expect((request('a.example')..statusCode = 200).isFailure, isFalse);
    });
  });
}
