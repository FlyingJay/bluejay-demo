import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../accent.dart';
import '../theme.dart';
import '../tokens.dart';

/// Picks an accent pair: a primary from the curated swatches or a custom
/// color, and an optional secondary (Auto derives one from the primary).
/// Custom colors are checked live; [onChanged] only ever reports colors
/// that pass [isAccessibleAccent].
class BjAccentPicker extends StatefulWidget {
  const BjAccentPicker({
    super.key,
    this.primary,
    this.secondary,
    required this.onChanged,
  });

  final Color? primary;

  /// Null means Auto.
  final Color? secondary;

  /// Called with a valid primary and a valid secondary, or null for Auto.
  final void Function(Color primary, Color? secondary) onChanged;

  @override
  State<BjAccentPicker> createState() => _BjAccentPickerState();
}

class _BjAccentPickerState extends State<BjAccentPicker> {
  late Color _primary = widget.primary ?? BjSwatches.indigo.color;
  late Color? _secondary = widget.secondary;

  void _emit() => widget.onChanged(_primary, _secondary);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = BjAccent(primary: _primary, secondary: _secondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Primary color', style: text.titleSmall),
        const SizedBox(height: BjSpace.sm),
        BjColorChooser(
          value: _primary,
          onChanged: (c) {
            setState(() => _primary = c ?? _primary);
            _emit();
          },
        ),
        const SizedBox(height: BjSpace.xl),
        Text('Secondary color', style: text.titleSmall),
        Text('Used in gradients and highlights.', style: text.bodySmall),
        const SizedBox(height: BjSpace.sm),
        BjColorChooser(
          value: _secondary,
          allowAuto: true,
          autoColor: deriveSecondary(_primary),
          onChanged: (c) {
            setState(() => _secondary = c);
            _emit();
          },
        ),
        const SizedBox(height: BjSpace.xl),
        _AccentPreview(accent: accent),
      ],
    );
  }
}

/// Swatch grid plus a custom option with live contrast checking. With
/// [allowAuto], an "Auto" tile reports null.
class BjColorChooser extends StatefulWidget {
  const BjColorChooser({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowAuto = false,
    this.autoColor,
  });

  final Color? value;
  final ValueChanged<Color?> onChanged;
  final bool allowAuto;
  final Color? autoColor;

  @override
  State<BjColorChooser> createState() => _BjColorChooserState();
}

class _BjColorChooserState extends State<BjColorChooser> {
  late bool _custom = widget.value != null &&
      !BjSwatches.all.any((s) => s.color == widget.value);

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: BjSpace.sm,
          runSpacing: BjSpace.sm,
          children: [
            if (widget.allowAuto)
              _SwatchDot(
                label: 'Auto',
                color: widget.autoColor ?? BjNeutral.inkMuted,
                selected: value == null && !_custom,
                auto: true,
                onTap: () {
                  setState(() => _custom = false);
                  widget.onChanged(null);
                },
              ),
            for (final s in BjSwatches.all)
              _SwatchDot(
                label: s.name,
                color: s.color,
                selected: !_custom && value == s.color,
                onTap: () {
                  setState(() => _custom = false);
                  widget.onChanged(s.color);
                },
              ),
            _SwatchDot(
              label: 'Custom',
              color: _custom && value != null ? value : null,
              selected: _custom,
              onTap: () => setState(() => _custom = true),
            ),
          ],
        ),
        AnimatedSize(
          duration: BjMotion.medium,
          curve: BjMotion.curve,
          alignment: Alignment.topCenter,
          child: _custom
              ? Padding(
                  padding: const EdgeInsets.only(top: BjSpace.md),
                  child: _CustomColorField(
                    initial: value ?? widget.autoColor ?? BjSwatches.indigo.color,
                    onValid: widget.onChanged,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _SwatchDot extends StatelessWidget {
  const _SwatchDot({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.auto = false,
  });

  final String label;

  /// Null draws the rainbow "custom" tile.
  final Color? color;
  final bool selected;
  final bool auto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ring = selected ? BjNeutral.ink : Colors.transparent;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label color',
        child: InkResponse(
          onTap: onTap,
          radius: 26,
          child: AnimatedContainer(
            duration: BjMotion.fast,
            curve: BjMotion.curve,
            width: 40,
            height: 40,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ring, width: 2),
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: auto ? null : color,
                gradient: auto && color != null
                    ? LinearGradient(colors: [
                        Color.lerp(color, Colors.white, 0.55)!,
                        color!,
                      ])
                    : color == null
                        ? const SweepGradient(colors: [
                            Color(0xFFE11D48),
                            Color(0xFFF59E0B),
                            Color(0xFF10B981),
                            Color(0xFF0EA5E9),
                            Color(0xFF7C3AED),
                            Color(0xFFE11D48),
                          ])
                        : null,
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
                  : auto
                      ? const Icon(Icons.auto_awesome_rounded,
                          color: Colors.white, size: 16)
                      : color == null
                          ? const Icon(Icons.add_rounded,
                              color: Colors.white, size: 18)
                          : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomColorField extends StatefulWidget {
  const _CustomColorField({required this.initial, required this.onValid});

  final Color initial;
  final ValueChanged<Color> onValid;

  @override
  State<_CustomColorField> createState() => _CustomColorFieldState();
}

class _CustomColorFieldState extends State<_CustomColorField> {
  late HSLColor _hsl = HSLColor.fromColor(widget.initial);
  late final TextEditingController _hex =
      TextEditingController(text: BjAccent.toHex(widget.initial));
  bool _hexInvalid = false;

  Color get _color => _hsl.toColor();

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSLColor hsl, {bool fromHex = false}) {
    setState(() {
      _hsl = hsl;
      _hexInvalid = false;
      if (!fromHex) _hex.text = BjAccent.toHex(hsl.toColor());
    });
    if (isAccessibleAccent(hsl.toColor())) widget.onValid(hsl.toColor());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bj = context.bj;
    final ratio = accentContrast(_color);
    final ok = ratio >= kMinAccentContrast;
    final tone = bj.tone(ok ? BjTone.success : BjTone.warning);
    return Container(
      padding: const EdgeInsets.all(BjSpace.md),
      decoration: BoxDecoration(
        color: BjNeutral.surfaceMuted,
        borderRadius: BjRadius.all(BjRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            AnimatedContainer(
              duration: BjMotion.fast,
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BjRadius.all(BjRadius.md),
              ),
              alignment: Alignment.center,
              child: Text('Aa',
                  style: text.titleMedium?.copyWith(color: Colors.white)),
            ),
            const SizedBox(width: BjSpace.md),
            SizedBox(
              width: 130,
              child: TextField(
                controller: _hex,
                decoration: InputDecoration(
                  labelText: 'Hex',
                  isDense: true,
                  errorText: _hexInvalid ? 'Use #RRGGBB' : null,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')),
                  LengthLimitingTextInputFormatter(7),
                ],
                onChanged: (v) {
                  final c = v.replaceFirst('#', '').length == 6
                      ? BjAccent.parseHex(v)
                      : null;
                  if (c == null) {
                    setState(() => _hexInvalid = v.length >= 6);
                  } else {
                    _set(HSLColor.fromColor(c), fromHex: true);
                  }
                },
              ),
            ),
            const SizedBox(width: BjSpace.md),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: BjSpace.sm, vertical: BjSpace.xs + 2),
                  decoration: BoxDecoration(
                    color: tone.background,
                    border: Border.all(color: tone.border),
                    borderRadius: BjRadius.all(BjRadius.sm),
                  ),
                  child: Row(children: [
                    Icon(ok ? Icons.check_circle_rounded : Icons.warning_rounded,
                        size: 16, color: tone.foreground),
                    const SizedBox(width: BjSpace.xs + 2),
                    Expanded(
                      child: Text(
                        ok
                            ? 'Readable · ${ratio.toStringAsFixed(1)}:1'
                            : 'Too light · ${ratio.toStringAsFixed(1)}:1 (needs 4.5)',
                        style: text.labelMedium
                            ?.copyWith(color: tone.foreground),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
          const SizedBox(height: BjSpace.md),
          _GradientSlider(
            label: 'Hue',
            value: _hsl.hue / 360,
            colors: [
              for (var h = 0; h <= 360; h += 60)
                HSLColor.fromAHSL(1, h.toDouble() % 360, _hsl.saturation, 0.5)
                    .toColor(),
            ],
            onChanged: (v) => _set(_hsl.withHue((v * 360).clamp(0, 359.9))),
          ),
          _GradientSlider(
            label: 'Lightness',
            value: _hsl.lightness,
            colors: [
              Colors.black,
              _hsl.withLightness(0.5).toColor(),
              Colors.white,
            ],
            onChanged: (v) => _set(_hsl.withLightness(v)),
          ),
          if (!ok)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    _set(HSLColor.fromColor(nearestAccessibleShade(_color))),
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: const Text('Use nearest readable shade'),
              ),
            ),
        ],
      ),
    );
  }
}

class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
        width: 72,
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      ),
      Expanded(
        child: Stack(alignment: Alignment.center, children: [
          Container(
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: colors),
              borderRadius: BjRadius.all(BjRadius.pill),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 10,
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              thumbColor: Colors.white,
              overlayColor: BjNeutral.ink.withValues(alpha: 0.08),
              thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 9, elevation: 2),
            ),
            child: Slider(
              value: value.clamp(0.0, 1.0),
              onChanged: onChanged,
              semanticFormatterCallback: (v) =>
                  '$label ${(v * 100).round()} percent',
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _AccentPreview extends StatelessWidget {
  const _AccentPreview({required this.accent});

  final BjAccent accent;

  @override
  Widget build(BuildContext context) {
    final bj = BjTheme.fromAccent(accent);
    final text = Theme.of(context).textTheme;
    return AnimatedContainer(
      duration: BjMotion.slow,
      curve: BjMotion.curve,
      padding: const EdgeInsets.all(BjSpace.lg),
      decoration: BoxDecoration(
        gradient: bj.heroGradient,
        borderRadius: BjRadius.all(BjRadius.lg),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Preview',
                  style: text.titleMedium?.copyWith(color: Colors.white)),
              Text('How headers and buttons will look',
                  style: text.bodySmall
                      ?.copyWith(color: Colors.white.withValues(alpha: 0.9))),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: BjSpace.lg, vertical: BjSpace.sm),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BjRadius.all(BjRadius.pill),
          ),
          child: Text('Button',
              style: text.labelLarge?.copyWith(color: accent.primary)),
        ),
      ]),
    );
  }
}
