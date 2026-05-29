/// Live reachability state for the Ollama backend. Surfaced in the chat
/// app bar so the user can tell a VPN/ZeroTier wobble apart from a real
/// app error.
enum OllamaHealth {
  /// Either Ollama isn't configured or we haven't probed yet.
  unknown,

  /// Primary URL responded on the last probe (or last real request).
  healthy,

  /// Primary is down but the backup URL is serving traffic.
  degraded,

  /// Neither primary nor backup responded.
  down,
}
