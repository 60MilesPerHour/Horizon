import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:horizon/Utils/horizon_http.dart';

/// Talks to a Home Assistant instance over its REST API.
///
/// Three capabilities, which together are what an assistant needs to be
/// useful in a house: list what exists, read one thing's state, and call a
/// service to change something. HA's REST API is stable and needs nothing
/// installed on the HA side beyond a long-lived access token.
///
/// Config is held in memory and mutated live by Settings, mirroring the chat
/// and speech services.
class HomeAssistantService {
  HomeAssistantService({String? baseUrl, String? token}) : baseUrl = baseUrl ?? '', token = token ?? '';

  String baseUrl;
  String token;

  /// The instance URL and a token are both required — HA rejects every
  /// endpoint without the bearer, so a URL alone can't do anything.
  bool get isConfigured => baseUrl.trim().isNotEmpty && token.trim().isNotEmpty;

  static const Duration _timeout = Duration(seconds: 15);

  Map<String, String> get _headers => {'Authorization': 'Bearer ${token.trim()}', 'Content-Type': 'application/json'};

  Uri _endpoint(String path) => endpointFor(baseUrl, path);

  /// Normalises whatever the user typed into a base URI: scheme optional,
  /// trailing slash optional, and a trailing `/api` tolerated — people paste
  /// that from the HA docs, and doubling it up gives a 404 that looks like a
  /// wrong address rather than a wrong setting.
  @visibleForTesting
  static Uri endpointFor(String baseUrl, String path) {
    var base = baseUrl.trim();
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'http://$base';
    }
    base = base.replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/api')) base = base.substring(0, base.length - 4);
    return Uri.parse('$base/api$path');
  }

  /// Confirms the URL and token actually work, returning HA's version string.
  /// Used by the "Test connection" button, so the failure is visible in
  /// Settings rather than as a tool error mid-conversation.
  Future<String> ping() async {
    final response = await HorizonHttp.client.get(_endpoint('/config'), headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw HomeAssistantException(_describe(response.statusCode));
    }
    final body = json.decode(response.body) as Map<String, dynamic>;
    final version = (body['version'] ?? '?').toString();
    final name = (body['location_name'] ?? 'Home Assistant').toString();
    return '$name · version $version';
  }

  /// Every entity and its current state.
  Future<List<HaEntity>> states() async {
    final response = await HorizonHttp.client.get(_endpoint('/states'), headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw HomeAssistantException(_describe(response.statusCode));
    }
    final decoded = json.decode(response.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map>().map((raw) => HaEntity.fromJson(raw.cast<String, dynamic>())).toList();
  }

  Future<HaEntity> state(String entityId) async {
    final response = await HorizonHttp.client.get(_endpoint('/states/$entityId'), headers: _headers).timeout(_timeout);
    if (response.statusCode == 404) {
      throw HomeAssistantException(
        'No entity called "$entityId" exists. List the entities first to get '
        'the exact id.',
      );
    }
    if (response.statusCode != 200) {
      throw HomeAssistantException(_describe(response.statusCode));
    }
    return HaEntity.fromJson(json.decode(response.body) as Map<String, dynamic>);
  }

  /// Calls `domain.service`, e.g. `light.turn_on`. HA returns the states it
  /// changed, which is the only honest way to report what actually happened —
  /// a 200 with an empty list means the service ran and changed nothing.
  Future<List<HaEntity>> callService({
    required String domain,
    required String service,
    Map<String, dynamic> data = const {},
  }) async {
    final response = await HorizonHttp.client
        .post(_endpoint('/services/$domain/$service'), headers: _headers, body: json.encode(data))
        .timeout(_timeout);

    if (response.statusCode == 400) {
      throw HomeAssistantException('Home Assistant rejected $domain.$service: ${response.body}');
    }
    if (response.statusCode == 404) {
      throw HomeAssistantException('There is no service called "$domain.$service".');
    }
    if (response.statusCode != 200) {
      throw HomeAssistantException(_describe(response.statusCode));
    }

    final decoded = json.decode(response.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map>().map((raw) => HaEntity.fromJson(raw.cast<String, dynamic>())).toList();
  }

  static String _describe(int status) {
    switch (status) {
      case 401:
      case 403:
        return 'Home Assistant rejected the access token (HTTP $status). '
            'Create a new long-lived token in your HA profile and paste it in '
            'Settings → Home Assistant.';
      case 404:
        return 'Home Assistant returned 404 — check the instance URL.';
      default:
        return 'Home Assistant returned HTTP $status.';
    }
  }
}

/// One HA entity: `light.kitchen`, its state, and its attributes.
class HaEntity {
  const HaEntity({required this.entityId, required this.state, required this.attributes});

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  factory HaEntity.fromJson(Map<String, dynamic> json) => HaEntity(
    entityId: (json['entity_id'] ?? '').toString(),
    state: (json['state'] ?? 'unknown').toString(),
    attributes: (json['attributes'] as Map?)?.cast<String, dynamic>() ?? const {},
  );

  /// The `light.kitchen` → "Kitchen" name, falling back to the id.
  String get friendlyName => (attributes['friendly_name'] ?? entityId).toString();

  /// `light`, `switch`, `sensor`, …
  String get domain {
    final dot = entityId.indexOf('.');
    return dot == -1 ? entityId : entityId.substring(0, dot);
  }

  /// One line for the model: name, id, state, and the unit if it has one.
  String get summary {
    final unit = attributes['unit_of_measurement'];
    final value = unit == null ? state : '$state $unit';
    return '$friendlyName ($entityId) = $value';
  }
}

class HomeAssistantException implements Exception {
  const HomeAssistantException(this.message);

  final String message;

  @override
  String toString() => message;
}
