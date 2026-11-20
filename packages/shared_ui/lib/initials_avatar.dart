import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

/// Up to two initials for [name] ("jane.doe" → "JD", "Sam" → "S").
String memberInitials(String name) {
  final parts = name
      .replaceAll('.', ' ')
      .replaceAll('_', ' ')
      .split(' ')
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  return parts.isNotEmpty ? parts[0][0].toUpperCase() : '?';
}

/// A round initials avatar for a person. The colour comes from
/// [BjCategorical.forKey] on [seed] (defaults to [name]) so the same person
/// gets the same hue everywhere, drawn as a soft tint with readable initials.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    required this.name,
    this.seed,
    this.size = 40,
  });

  final String name;
  final String? seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hue = BjCategorical.forKey(seed ?? name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bjTint(hue),
        shape: BoxShape.circle,
        border: Border.all(color: hue.withValues(alpha: 0.18)),
      ),
      child: Text(
        memberInitials(name),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: hue,
              fontWeight: FontWeight.w700,
              fontSize: size * 0.36,
            ),
      ),
    );
  }
}
