import 'dart:async';
import 'dart:io';

import 'package:horizon/Utils/horizon_http.dart';

/// A service Horizon knows how to look for on the local network.
class DiscoverableService {
  final String label;

  /// Ports to try, in order of likelihood.
  final List<int> ports;

  /// Path that identifies the service. Must be cheap and unauthenticated.
  final String probePath;

  /// Returns true if the body looks like this service rather than something
  /// else that happens to answer on the port — which matters, because 8000
  /// and 8001 are popular and a 200 from an unrelated app would otherwise be
  /// reported as a found server.
  final bool Function(String body) matches;

  const DiscoverableService({
    required this.label,
    required this.ports,
    required this.probePath,
    required this.matches,
  });

  static final ollama = DiscoverableService(
    label: 'Ollama',
    ports: const [11434],
    probePath: '/api/tags',
    matches: (body) => body.contains('"models"'),
  );

  /// Speaches, or anything else exposing the OpenAI audio endpoints.
  static final speaches = DiscoverableService(
    label: 'Speech server',
    ports: const [8001, 8000, 8080],
    probePath: '/v1/models',
    // Distinguishes a speech server from any other OpenAI-compatible API on
    // the same port: only these advertise audio tasks.
    matches: (body) =>
        body.contains('automatic-speech-recognition') ||
        body.contains('text-to-speech'),
  );
}

/// One service found on the network.
class DiscoveredEndpoint {
  final String label;
  final Uri uri;

  const DiscoveredEndpoint({required this.label, required this.uri});

  /// Base URL in the form the settings fields expect.
  String get baseUrl => '${uri.scheme}://${uri.host}:${uri.port}';

  @override
  String toString() => baseUrl;
}

/// Scans the local network for Horizon's backends.
///
/// Replaces having to know and type an IP. Generalised from the Ollama-only
/// scan that lived in ServerSettings: same idea, but it takes a list of
/// services and probes each candidate host for all of them at once, so one
/// sweep finds the Ollama rig and the speech server together.
class NetworkDiscoveryService {
  /// Per-probe timeout. Short on purpose: a live host on the LAN answers in
  /// milliseconds, and anything slower is almost certainly a dead address
  /// that would otherwise hold the whole sweep open.
  static const Duration probeTimeout = Duration(milliseconds: 900);

  /// How many probes run at once. Unbounded parallelism across a /24 for
  /// several ports opens ~750 sockets, which some platforms refuse and mobile
  /// Wi-Fi handles badly.
  static const int concurrency = 64;

  /// Candidate hosts: every address on each non-loopback IPv4 interface's /24,
  /// plus loopback so a desktop running Ollama locally is found too.
  static Future<List<String>> candidateHosts() async {
    final hosts = <String>{'127.0.0.1'};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final segments = address.address.split('.');
          if (segments.length != 4) continue;
          final prefix = '${segments[0]}.${segments[1]}.${segments[2]}';
          for (var i = 1; i < 255; i++) {
            hosts.add('$prefix.$i');
          }
        }
      }
    } on OSError {
      // Some platforms refuse to enumerate interfaces; loopback still works.
    }
    return hosts.toList();
  }

  /// Sweeps the network for [services].
  ///
  /// [onProgress] reports completed probes out of the total so a long sweep
  /// can show something other than a spinner.
  static Future<List<DiscoveredEndpoint>> discover({
    required List<DiscoverableService> services,
    void Function(int done, int total)? onProgress,
  }) async {
    final hosts = await candidateHosts();
    final targets = <(DiscoverableService, String, int)>[];
    for (final service in services) {
      for (final host in hosts) {
        for (final port in service.ports) {
          targets.add((service, host, port));
        }
      }
    }

    final found = <DiscoveredEndpoint>[];
    final seen = <String>{};
    var done = 0;

    for (var start = 0; start < targets.length; start += concurrency) {
      final batch = targets.skip(start).take(concurrency);
      final results = await Future.wait(batch.map((target) async {
        final (service, host, port) = target;
        final endpoint = await _probe(service, host, port);
        done++;
        onProgress?.call(done, targets.length);
        return endpoint;
      }));

      for (final endpoint in results) {
        if (endpoint == null) continue;
        // One entry per service per host: finding Speaches on 8001 shouldn't
        // also report it on 8000 if both happen to answer.
        final key = '${endpoint.label}@${endpoint.uri.host}';
        if (seen.add(key)) found.add(endpoint);
      }
    }

    return found;
  }

  static Future<DiscoveredEndpoint?> _probe(
    DiscoverableService service,
    String host,
    int port,
  ) async {
    final uri = Uri.parse('http://$host:$port${service.probePath}');
    try {
      final response =
          await HorizonHttp.client.get(uri).timeout(probeTimeout);
      if (response.statusCode != 200) return null;
      if (!service.matches(response.body)) return null;
      return DiscoveredEndpoint(
        label: service.label,
        uri: Uri.parse('http://$host:$port'),
      );
    } catch (_) {
      // Unreachable, refused, or timed out — all just "not here".
      return null;
    }
  }
}
