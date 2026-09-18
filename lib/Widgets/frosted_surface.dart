import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Constants/horizon_theme.dart';
import 'package:horizon/Services/appearance_controller.dart';

/// Blurs whatever is painted behind it, for the frosted surface style.
///
/// A [BackdropFilter] only blurs what's already been painted underneath, so
/// this has to sit in a layer that overlaps the content — an app bar's
/// `flexibleSpace`, or a sheet's own background. Wrapping it in a
/// [ClipRect] is not optional: an unclipped backdrop filter samples the whole
/// layer tree and the blur bleeds outside the widget's bounds.
///
/// Returns [child] untouched when the user is on the solid style, so there's
/// no filter in the tree — a BackdropFilter is the single most expensive thing
/// in a scrolling frame and it shouldn't exist unless it's asked for.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({super.key, this.child, this.borderRadius, this.opacity});

  final Widget? child;
  final BorderRadius? borderRadius;

  /// Overrides the tint opacity — sheets sit over content and want a little
  /// more cover than an app bar does.
  final double? opacity;

  @override
  Widget build(BuildContext context) {
    final frosted = context.watch<AppearanceController>().appearance.isFrosted;
    if (!frosted) return child ?? const SizedBox.shrink();

    final tint = Theme.of(context).colorScheme.surface.withValues(alpha: opacity ?? HorizonTheme.frostedOpacity);

    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: HorizonTheme.frostedBlur, sigmaY: HorizonTheme.frostedBlur),
        child: Container(color: tint, child: child),
      ),
    );
  }
}
