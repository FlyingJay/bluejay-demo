import 'package:flutter/material.dart';

class GroupLogo extends StatelessWidget {
  final String? logoUrl;
  final String? cacheIdentity;
  final Widget fallback;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final BoxShape shape;

  const GroupLogo({
    super.key,
    required this.logoUrl,
    this.cacheIdentity,
    required this.fallback,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
  });

  @override
  Widget build(BuildContext context) {
    final normalizedLogoUrl = logoUrl?.trim();
    final fallbackWidget = _fallback();
    if (normalizedLogoUrl == null || normalizedLogoUrl.isEmpty) {
      return SizedBox(
        width: width,
        height: height,
        child: fallbackWidget,
      );
    }

    return SizedBox(
      width: width,
      height: height,
      child: _clip(
        Image.network(
          normalizedLogoUrl,
          key: ValueKey(
            _imageIdentityKey(
              normalizedLogoUrl,
              cacheIdentity?.trim(),
            ),
          ),
          width: width,
          height: height,
          fit: fit,
          gaplessPlayback: false,
          errorBuilder: (_, __, ___) => fallbackWidget,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) {
              return child;
            }
            return fallbackWidget;
          },
        ),
      ),
    );
  }

  String _imageIdentityKey(
    String normalizedLogoUrl,
    String? normalizedCacheIdentity,
  ) {
    if (normalizedCacheIdentity == null || normalizedCacheIdentity.isEmpty) {
      return normalizedLogoUrl;
    }
    return '$normalizedCacheIdentity::$normalizedLogoUrl';
  }

  Widget _fallback() => Center(child: fallback);

  Widget _clip(Widget child) {
    if (shape == BoxShape.circle) {
      return ClipOval(child: child);
    }
    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }
}
