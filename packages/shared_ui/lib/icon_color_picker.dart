import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'icon_palette.dart';

/// A compact swatch-grid color picker using the predefined [iconBackgroundPalette]
/// or [iconGlyphPalette].
///
/// Tapping a swatch calls [onColorSelected] with the chosen [Color].
/// The currently selected color is highlighted with a checkmark.
class IconColorPicker extends StatelessWidget {
  final List<Color> palette;
  final Color? selectedColor;
  final ValueChanged<Color> onColorSelected;
  final double swatchSize;
  final double spacing;

  const IconColorPicker({
    Key? key,
    required this.palette,
    required this.onColorSelected,
    this.selectedColor,
    this.swatchSize = 32,
    this.spacing = 6,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: palette.map((color) {
        final bool isSelected = selectedColor != null &&
            color.value == selectedColor!.value;
        return GestureDetector(
          onTap: () => onColorSelected(color),
          child: AnimatedContainer(
            duration: BjMotion.fast,
            curve: BjMotion.curve,
            width: swatchSize,
            height: swatchSize,
            decoration: BoxDecoration(
              color: color, // design-ok: app icon colour the user is picking
              borderRadius: BjRadius.all(BjRadius.sm),
              border: Border.all(
                color: isSelected ? context.bj.accent : BjNeutral.border,
                width: isSelected ? 2.5 : 1,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.5),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: isSelected
                ? Icon(
                    Icons.check,
                    size: swatchSize * 0.6,
                    color: isDarkColor(color) ? Colors.white : BjNeutral.ink,
                  )
                : null,
          ),
        );
      }).toList(),
    );
  }
}
