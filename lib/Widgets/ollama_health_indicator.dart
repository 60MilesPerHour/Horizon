import 'package:flutter/material.dart';
import 'package:horizon/Models/ollama_health.dart';
import 'package:horizon/Models/settings_route_arguments.dart';
import 'package:horizon/Services/ollama_health_monitor.dart';
import 'package:provider/provider.dart';

/// Small reachability dot for the chat app bar. Renders nothing when Ollama
/// is unconfigured so it doesn't add chrome for users who only chat with
/// cloud providers.
class OllamaHealthIndicator extends StatelessWidget {
  const OllamaHealthIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<OllamaHealthMonitor>();
    final status = monitor.status;

    if (status == OllamaHealth.unknown) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: _tooltipFor(monitor),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _handleTap(context, monitor),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _colorFor(status),
              boxShadow: status == OllamaHealth.degraded || status == OllamaHealth.down
                  ? [
                      BoxShadow(
                        color: _colorFor(status).withValues(alpha: 0.6),
                        blurRadius: 6,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  static Color _colorFor(OllamaHealth s) {
    switch (s) {
      case OllamaHealth.healthy:
        return Colors.green;
      case OllamaHealth.degraded:
        return Colors.orange;
      case OllamaHealth.down:
        return Colors.red;
      case OllamaHealth.unknown:
        return Colors.grey;
    }
  }

  static String _tooltipFor(OllamaHealthMonitor m) {
    switch (m.status) {
      case OllamaHealth.healthy:
        return 'Ollama: reachable\n${m.activeUrl ?? ''}';
      case OllamaHealth.degraded:
        return 'Ollama: on backup URL\n${m.activeUrl ?? ''}';
      case OllamaHealth.down:
        return 'Ollama: unreachable\nTap to refresh or open server settings';
      case OllamaHealth.unknown:
        return 'Ollama: not configured';
    }
  }

  Future<void> _handleTap(BuildContext context, OllamaHealthMonitor m) async {
    final navigator = Navigator.of(context);
    if (m.status == OllamaHealth.down || m.status == OllamaHealth.degraded) {
      // Re-probe first so a fleeting VPN drop self-heals without sending the
      // user to settings.
      await m.refresh();
      if (m.status == OllamaHealth.healthy) return;
    }
    navigator.pushNamed('/settings', arguments: SettingsRouteArguments(autoFocusServerAddress: true));
  }
}
