import 'package:flutter/material.dart';
import 'package:shared_ui/icon_helper.dart';
import 'package:shared_ui/icon_palette.dart';

/// An app's launcher icon: its uploaded image (thumbnail first) when it has
/// one, otherwise its Material glyph (`apps/{appId}.icon`, a key of
/// `icons.dart`) on its background colour, in the launcher's rounded square.
///
/// Takes the `apps/{appId}` icon fields as they are stored, so any screen
/// that lists apps draws them the way the launcher does.
class AppIconTile extends StatelessWidget {
  /// `apps/{appId}.icon`.
  final String icon;
  final String? iconUrl;
  final String? iconThumbnailUrl;

  /// `#RRGGBB` strings, as stored.
  final String? iconBgColor;
  final String? iconColor;

  /// Width and height of the square.
  final double size;

  /// Whether to draw the launcher's soft shadow.
  final bool shadow;

  const AppIconTile({
    super.key,
    required this.icon,
    this.iconUrl,
    this.iconThumbnailUrl,
    this.iconBgColor,
    this.iconColor,
    this.size = 64,
    this.shadow = true,
  });

  double get _radius => size * 14 / 64;

  String? get _imageUrl {
    final thumb = iconThumbnailUrl?.trim();
    if (thumb != null && thumb.isNotEmpty) return thumb;
    final full = iconUrl?.trim();
    return (full != null && full.isNotEmpty) ? full : null;
  }

  @override
  Widget build(BuildContext context) {
    final url = _imageUrl;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_radius),
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : const [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: url == null
            ? _glyph(context)
            : Image.network(
                url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (context, _, __) => _glyph(context),
              ),
      ),
    );
  }

  Widget _glyph(BuildContext context) {
    final background = colorFromHex(iconBgColor) ?? Colors.white;
    final glyph = colorFromHex(iconColor) ?? Theme.of(context).primaryColor;
    return ColoredBox(
      color: background,
      child: Center(
        child: Icon(getIconData(icon), size: size * 36 / 64, color: glyph),
      ),
    );
  }
}
