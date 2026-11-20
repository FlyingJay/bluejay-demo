/// A black fullscreen pager for a set of images: swipe (or mouse-drag) between
/// them, pinch or scroll to zoom, tap a page dot to jump. Used by ticket
/// attachments and the Add Apps screenshot strip.
library;


import 'package:flutter/material.dart';

/// One image in a [FullscreenImageViewer].
class FullscreenImage {
  final String url;

  /// Screen-reader label; empty for a generic "Image N".
  final String label;

  const FullscreenImage({required this.url, this.label = ''});
}

/// Opens [FullscreenImageViewer] on [images], starting at [initialIndex].
Future<void> showFullscreenImages(
  BuildContext context, {
  required List<FullscreenImage> images,
  int initialIndex = 0,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => FullscreenImageViewer(images: images, initialIndex: initialIndex),
    ),
  );
}

/// Black fullscreen pager with pinch/scroll zoom.
class FullscreenImageViewer extends StatefulWidget {
  final List<FullscreenImage> images;
  final int initialIndex;

  const FullscreenImageViewer({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });

  @override
  State<FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<FullscreenImageViewer> {
  late final PageController _pageController = PageController(initialPage: widget.initialIndex);
  late int _currentPage = widget.initialIndex;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          PageView.builder(
     key: const ValueKey('fullscreen-image-pager'),
     controller: _pageController,
     itemCount: widget.images.length,
     onPageChanged: (index) => setState(() => _currentPage = index),
     itemBuilder: (_, index) => InteractiveViewer(
       minScale: 1,
       maxScale: 4,
       child: Center(
         child: Image.network(
           widget.images[index].url,
           fit: BoxFit.contain,
           semanticLabel: widget.images[index].label.isEmpty
               ? 'Image ${index + 1}'
               : widget.images[index].label,
           errorBuilder: (_, __, ___) =>
               Icon(Icons.broken_image_outlined, color: Colors.white.withValues(alpha: 0.7), size: 36),
         ),
       ),
     ),
   ),
          if (widget.images.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: SafeArea(
                top: false,
                child: ImagePageDots(
                  count: widget.images.length,
                  current: _currentPage,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white.withValues(alpha: 0.54),
                  size: 9,
                  onTap: (index) => _pageController.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row of tappable dots showing which page of an image pager is current.
class ImagePageDots extends StatelessWidget {
  final int count;
  final int current;
  final Color activeColor;
  final Color inactiveColor;
  final double size;
  final ValueChanged<int> onTap;

  const ImagePageDots({
    super.key,
    required this.count,
    required this.current,
    required this.activeColor,
    required this.inactiveColor,
    required this.onTap,
    this.size = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final active = index == current;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onTap(index),
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: active ? size : size - 2,
                height: active ? size : size - 2,
                decoration: BoxDecoration(
                  color: active ? activeColor : inactiveColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
