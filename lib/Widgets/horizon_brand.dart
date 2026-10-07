import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The pieces of Horizon's look that don't come from the Material scheme.
///
/// The scheme (from the accent in Appearance) still drives ordinary controls.
/// These are the brand: one orange, a hairline horizon, and a voice orb that
/// breathes — used sparingly, because the design is meant to be mostly light
/// and space, with warmth in a few deliberate places.
class HorizonBrand {
  const HorizonBrand._();

  static const Color orange = Color(0xFFFF8A3D);
  static const Color orangeDeep = Color(0xFFF06A1F);

  /// Orange that reads on warm paper; the bright one washes out there.
  static const Color orangeInk = Color(0xFFE8691F);

  /// The send button's orange — a touch deeper than the glow, so white on it
  /// has contrast.
  static const Color sendDark = Color(0xFFF2792B);

  /// Light mode's background: warm paper rather than clinical white.
  static const Color paper = Color(0xFFFAF8F5);

  static Color accent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? orange : orangeInk;

  static const LinearGradient orbGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFA24F), orangeDeep],
  );

  static const LinearGradient nameGradient = LinearGradient(
    colors: [orange, orangeDeep],
  );

  /// The faint warmth on the user's own messages.
  static Gradient userTint(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: dark
          ? const [Color(0x24FF8A3D), Color(0x1AF06A1F)]
          : const [Color(0x29FF8A3D), Color(0x1AF06A1F)],
    );
  }
}

/// The hairline horizon: a thin orange line that fades out at both ends,
/// with an optional soft glow rising from it.
class HorizonLine extends StatelessWidget {
  final bool glow;
  final double horizontalPadding;

  const HorizonLine({super.key, this.glow = false, this.horizontalPadding = 0});

  @override
  Widget build(BuildContext context) {
    final line = Container(
      height: 2,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [
          Colors.transparent,
          HorizonBrand.orange,
          HorizonBrand.orangeDeep,
          Colors.transparent,
        ], stops: [0, .25, .7, 1]),
        boxShadow: [
          BoxShadow(color: HorizonBrand.orange.withValues(alpha: .5), blurRadius: 12),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: glow
          ? Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
              Positioned(
                left: -30,
                right: -30,
                bottom: 0,
                height: 70,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.bottomCenter,
                        radius: 1.0,
                        colors: [
                          HorizonBrand.orange.withValues(alpha: .26),
                          HorizonBrand.orangeDeep.withValues(alpha: .10),
                          Colors.transparent,
                        ],
                        stops: const [0, .55, .8],
                      ),
                    ),
                  ),
                ),
              ),
              line,
            ])
          : line,
    );
  }
}

/// The orange orb. Breathes slowly at rest — an invitation to tap it — and
/// pulses faster while [active] (listening or speaking).
class VoiceOrb extends StatefulWidget {
  final double size;
  final bool active;
  final VoidCallback? onTap;
  final String? tooltip;

  /// Microphone level, 0..1. While given, the orb swells with your voice —
  /// the one sign that it's actually hearing you, which a pulse on a timer
  /// can't give.
  final Stream<double>? levels;

  const VoiceOrb({super.key, this.size = 34, this.active = false, this.onTap, this.tooltip, this.levels});

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: _period)..repeat();

  Duration get _period => widget.active ? const Duration(milliseconds: 1400) : const Duration(milliseconds: 2600);

  StreamSubscription<double>? _levelSub;
  double _level = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    _levelSub?.cancel();
    _levelSub = widget.levels?.listen((v) {
      if (!mounted) return;
      // Rise fast, fall slowly, so a syllable reads as a swell, not a flicker.
      final next = v.clamp(0.0, 1.0);
      setState(() => _level = next > _level ? next : _level * .8 + next * .2);
    });
    if (widget.levels == null) _level = 0;
  }

  @override
  void didUpdateWidget(covariant VoiceOrb old) {
    super.didUpdateWidget(old);
    if (old.levels != widget.levels) _subscribe();
    if (old.active != widget.active) {
      _pulse
        ..duration = _period
        ..repeat();
    }
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final orb = AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = _pulse.value;
        // A ring that spreads and fades, plus a glow that swells and eases.
        // With a level, the halo follows the voice; without one, it breathes.
        final hearing = widget.levels != null;
        final ring = hearing
            ? s * .08 + s * .55 * _level
            : (widget.active ? s * .55 * t : s * .28 * t);
        final glow = (widget.active ? .55 : .45) * (1 - (t - .5).abs() * 2).clamp(.3, 1.0);
        return SizedBox(
          width: s + s * .6,
          height: s + s * .6,
          child: Center(
            child: Container(
              width: s,
              height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: HorizonBrand.orbGradient,
                boxShadow: [
                  BoxShadow(
                    color: HorizonBrand.orange.withValues(alpha: hearing ? .22 + .2 * _level : (1 - t) * .5),
                    spreadRadius: ring,
                  ),
                  BoxShadow(
                    color: HorizonBrand.orangeDeep.withValues(alpha: glow),
                    blurRadius: s * .5,
                  ),
                ],
              ),
              child: Center(
                child: Container(
                  width: s * .22,
                  height: s * .22,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                ),
              ),
            ),
          ),
        );
      },
    );
    final tappable = GestureDetector(onTap: widget.onTap, behavior: HitTestBehavior.opaque, child: orb);
    return widget.tooltip == null ? tappable : Tooltip(message: widget.tooltip!, child: tappable);
  }
}

/// The send button: an orange rounded square with a white arrow — or, when
/// [provider] is given, that provider's logo in its own colours, so the button
/// says where the message is about to go.
class HorizonSendButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String tooltip;

  /// Provider id ('ollama', 'openrouter', 'anthropic', 'openai', 'google').
  /// Null, or one without a logo, keeps the orange arrow.
  final String? provider;

  const HorizonSendButton({
    super.key,
    required this.onPressed,
    this.icon = Icons.arrow_upward_rounded,
    this.tooltip = 'Send',
    this.provider,
  });

  static const Set<String> _logos = {
    'ollama',
    'openrouter',
    'anthropic',
    'openai',
    'google',
  };

  /// Asset path of [provider]'s logo, or null if there isn't one.
  static String? logoFor(String? provider) =>
      _logos.contains(provider) ? 'assets/images/providers/$provider.svg' : null;

  /// Google's four colours, swept around the Gemini sparkle the way the
  /// Gemini icon itself does.
  static const Gradient _googleSweep = SweepGradient(
    colors: [
      Color(0xFF4285F4), // blue
      Color(0xFFEA4335), // red
      Color(0xFFFBBC04), // yellow
      Color(0xFF34A853), // green
      Color(0xFF4285F4),
    ],
  );

  /// Each provider's brand colours, from Simple Icons' brand data: Claude's
  /// terracotta, OpenRouter's slate, black for Ollama and OpenAI. The
  /// monochrome ones invert in dark mode, because a black button on the
  /// composer's near-black card would vanish.
  static _SendStyle? _styleFor(String? provider, {required bool dark}) {
    switch (provider) {
      case 'anthropic':
        return const _SendStyle(background: Color(0xFFD97757), logo: Colors.white);
      case 'google':
        return _SendStyle(
          background: dark ? const Color(0xFF1F1F1F) : Colors.white,
          gradient: _googleSweep,
          border: dark ? const Color(0xFF3C4043) : const Color(0xFFDADCE0),
        );
      case 'openrouter':
        return const _SendStyle(background: Color(0xFF94A3B8), logo: Colors.white);
      case 'ollama':
      case 'openai':
        return dark
            ? const _SendStyle(background: Colors.white, logo: Colors.black)
            : const _SendStyle(background: Colors.black, logo: Colors.white);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final logo = logoFor(provider);
    final style = logo == null ? null : _styleFor(provider, dark: dark);

    Widget glyph;
    if (logo == null || style == null) {
      glyph = Icon(icon, color: Colors.white, size: 20);
    } else {
      glyph = SvgPicture.asset(
        logo,
        width: 18,
        height: 18,
        colorFilter: ColorFilter.mode(style.logo ?? Colors.white, BlendMode.srcIn),
      );
      final gradient = style.gradient;
      if (gradient != null) {
        glyph = ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: gradient.createShader,
          child: glyph,
        );
      }
    }

    final radius = BorderRadius.circular(10);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: style?.background ?? (dark ? HorizonBrand.sendDark : HorizonBrand.orangeInk),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: style?.border == null ? BorderSide.none : BorderSide(color: style!.border!),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          child: SizedBox(width: 34, height: 34, child: Center(child: glyph)),
        ),
      ),
    );
  }
}

/// How the send button looks for one provider: a background, and the logo in
/// either one colour or a gradient.
class _SendStyle {
  final Color background;
  final Color? logo;
  final Gradient? gradient;
  final Color? border;

  const _SendStyle({required this.background, this.logo, this.gradient, this.border});
}
