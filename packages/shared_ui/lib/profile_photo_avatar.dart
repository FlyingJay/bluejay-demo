import 'dart:async';

import 'package:flutter/material.dart';

/// A round profile photo that stays shown: over [fallback] while it loads
/// or if it can't be loaded, retried after a failure, and reloaded each
/// time its screen comes back to the front.
///
/// The launcher's profile button used to go blank after returning from an
/// app. The cause was cached_network_image before 4.0.5, which decoded a
/// cached image again when a screen came back; on web the new frame shared
/// the old frame's <img> element and disposing the old frame cleared it.
/// That is fixed by the package upgrade. Reloading when the route is
/// current again stays as a cheap recovery for photos that failed to load
/// while the screen was covered.
class ProfilePhotoAvatar extends StatefulWidget {
  const ProfilePhotoAvatar({
    super.key,
    required this.url,
    required this.radius,
    required this.fallback,
    this.backgroundColor,
  });

  /// The photo, or null to show [fallback].
  final String? url;
  final double radius;

  /// Shown when there is no photo, while it loads and when it fails.
  final Widget fallback;
  final Color? backgroundColor;

  /// How many times a failed load is retried before settling on
  /// [fallback] until the next time the screen comes back.
  static const int maxRetries = 3;

  @override
  State<ProfilePhotoAvatar> createState() => _ProfilePhotoAvatarState();
}

class _ProfilePhotoAvatarState extends State<ProfilePhotoAvatar> {
  /// Bumped to rebuild the image with a fresh provider.
  int _generation = 0;
  int _retries = 0;
  bool _wasCurrent = true;
  Timer? _retryTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Depends on the route's isCurrent, so this runs again when a pushed
    // route is popped and this screen is back in front.
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (isCurrent && !_wasCurrent) _reload(resetRetries: true);
    _wasCurrent = isCurrent;
  }

  @override
  void didUpdateWidget(ProfilePhotoAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _retryTimer?.cancel();
      _retries = 0;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _reload({bool resetRetries = false}) {
    final url = widget.url;
    if (url == null) return;
    _retryTimer?.cancel();
    if (resetRetries) _retries = 0;
    // Drop the cached decode so the image is decoded again, not reused.
    NetworkImage(url).evict();
    if (mounted) setState(() => _generation++);
  }

  void _scheduleRetry() {
    if (_retries >= ProfilePhotoAvatar.maxRetries) return;
    if (_retryTimer?.isActive ?? false) return;
    _retries++;
    _retryTimer = Timer(Duration(seconds: 2 << _retries), _reload);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.radius * 2;
    final url = widget.url;
    final background = widget.backgroundColor ??
        Theme.of(context).colorScheme.primaryContainer;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: ColoredBox(
          color: background,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(child: widget.fallback),
              if (url != null)
                Image.network(
                  url,
                  key: ValueKey('$url#$_generation'),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  frameBuilder: (context, child, frame, sync) =>
                      frame == null && !sync ? const SizedBox.shrink() : child,
                  errorBuilder: (context, error, stack) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _scheduleRetry());
                    return const SizedBox.shrink();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
