import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/Utils/remote_endpoint.dart';

void main() {
  group('normalize', () {
    test('a bare IP or host:port is assumed to be plaintext LAN', () {
      expect(RemoteEndpoint.normalize('172.16.23.20:8001'),
          'http://172.16.23.20:8001');
      expect(RemoteEndpoint.normalize('localhost:8001'),
          'http://localhost:8001');
    });

    test('a bare hostname is assumed to be a tunnel, so https', () {
      // The whole point of the remote field is a Cloudflare hostname, and an
      // Access service token must never go out over cleartext.
      expect(RemoteEndpoint.normalize('speech.example.com'),
          'https://speech.example.com');
    });

    test('an explicit scheme is left alone and trailing slashes go', () {
      expect(RemoteEndpoint.normalize('http://speech.example.com/'),
          'http://speech.example.com');
    });
  });

  group('resolve', () {
    test('appends the path', () {
      expect(
          RemoteEndpoint.resolve('http://172.16.23.20:8001', '/v1/models')
              .toString(),
          'http://172.16.23.20:8001/v1/models');
    });

    test('does not double up when the base already ends in /v1', () {
      expect(
          RemoteEndpoint.resolve('https://api.openai.com/v1', '/v1/models')
              .toString(),
          'https://api.openai.com/v1/models');
    });
  });

  group('headers', () {
    final endpoint = RemoteEndpoint(
      primary: 'http://172.16.23.20:8001',
      backup: 'https://speech.example.com',
      cfAccessClientId: 'abc.access',
      cfAccessClientSecret: 'shh',
    );

    test('the Access token rides on https only', () {
      expect(endpoint.headersFor('https://speech.example.com'),
          containsPair('CF-Access-Client-Id', 'abc.access'));
      expect(endpoint.headersFor('http://172.16.23.20:8001'),
          isNot(contains('CF-Access-Client-Id')));
    });

    test('a bearer token rides on both', () {
      expect(
          endpoint.headersFor('http://172.16.23.20:8001', bearerToken: 'k'),
          containsPair('Authorization', 'Bearer k'));
    });

    test('an incomplete token is not sent', () {
      final partial = RemoteEndpoint(
          backup: 'https://speech.example.com', cfAccessClientId: 'abc.access');
      expect(partial.headersFor('https://speech.example.com'),
          isNot(contains('CF-Access-Client-Id')));
    });
  });

  group('failover', () {
    test('falls through to the backup when the primary is unreachable', () async {
      final endpoint = RemoteEndpoint(
        primary: 'http://172.16.23.20:8001',
        backup: 'https://speech.example.com',
      );
      final tried = <String>[];
      final result = await endpoint.withFailover((base) async {
        tried.add(base);
        if (base.startsWith('http://')) {
          throw const SocketException('no route to host');
        }
        return 'ok';
      });
      expect(result, 'ok');
      expect(tried,
          ['http://172.16.23.20:8001', 'https://speech.example.com']);
    });

    test('sticks to whichever answered, so being away costs one timeout',
        () async {
      // Off the LAN the primary costs a full connect timeout. Paying that
      // before every utterance is the difference between usable and not.
      final endpoint = RemoteEndpoint(
        primary: 'http://172.16.23.20:8001',
        backup: 'https://speech.example.com',
      );
      Future<String> call(List<String> tried) => endpoint.withFailover((base) async {
            tried.add(base);
            if (base.startsWith('http://')) {
              throw TimeoutException('connect');
            }
            return 'ok';
          });

      await call([]);
      final second = <String>[];
      await call(second);
      expect(second, ['https://speech.example.com']);
    });

    test('editing an address drops the sticky choice', () async {
      final endpoint = RemoteEndpoint(
          primary: 'http://a.test', backup: 'https://b.test');
      await endpoint.withFailover((base) async {
        if (base == 'http://a.test') throw const SocketException('down');
        return base;
      });
      expect(endpoint.isOnBackup, isTrue);
      endpoint.reset();
      expect(endpoint.candidates().first, 'http://a.test');
    });

    test('a reachable server that errors does not trigger failover', () async {
      // Retrying a real error against the other address produces the same
      // error twice and doubles the wait.
      final endpoint = RemoteEndpoint(
          primary: 'http://a.test', backup: 'https://b.test');
      final tried = <String>[];
      final result = await endpoint.withFailover((base) async {
        tried.add(base);
        return 'HTTP 500';
      });
      expect(result, 'HTTP 500');
      expect(tried, ['http://a.test']);
    });

    test('nothing configured is a StateError, not a hang', () async {
      expect(RemoteEndpoint().withFailover((_) async => 1),
          throwsA(isA<StateError>()));
    });
  });

  group('Access login page detection', () {
    test('names the missing token when there is none', () {
      final endpoint = RemoteEndpoint(backup: 'https://speech.example.com');
      final message = endpoint.describeAccessBlock(
          '<!DOCTYPE html><html><head><script src="/cdn-cgi/access/login">',
          'https://speech.example.com');
      expect(message, contains('no service token'));
    });

    test('names a rejected token when one is configured', () {
      final endpoint = RemoteEndpoint(
        backup: 'https://speech.example.com',
        cfAccessClientId: 'abc.access',
        cfAccessClientSecret: 'shh',
      );
      final message = endpoint.describeAccessBlock(
          '<html>team.cloudflareaccess.com</html>',
          'https://speech.example.com');
      expect(message, contains('rejected the service token'));
    });

    test('JSON is not mistaken for a login page', () {
      expect(
          RemoteEndpoint().describeAccessBlock('{"data":[]}', 'http://a.test'),
          isNull);
    });
  });
}
