import 'package:flutter/material.dart';

class LogoBadge extends StatelessWidget {
  final double size;
  final bool withTitle;
  final double spacing;

  const LogoBadge({
    super.key,
    this.size = 36,
    this.withTitle = false,
    this.spacing = 10,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;

    final icon = SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        'assets/btbuddy_logo.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            decoration: BoxDecoration(
              color: primary,
              borderRadius: BorderRadius.circular(size * 0.22),
            ),
            child: Icon(
              Icons.bluetooth_connected,
              size: size * 0.6,
              color: scheme.onPrimary,
            ),
          );
        },
      ),
    );

    if (!withTitle) return icon;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        icon,
        SizedBox(width: spacing),
        Flexible(
          child: Text(
            'ControlBuddy',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
