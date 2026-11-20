// The camera view apps scan QR codes and barcodes with: a live camera feed
// with a framed cutout and a hint, calling [QrScannerView.onCode] once per
// code it reads. QR Codes scans any code with it; Inventory scans its item
// and location labels and product barcodes.

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// A rounded camera view that reads QR codes and barcodes. While [paused]
/// it ignores what the camera sees, so a screen can show a result without
/// the same code firing again.
class QrScannerView extends StatefulWidget {
  const QrScannerView({
    super.key,
    required this.onCode,
    this.paused = false,
    this.hint = 'Align the QR code within the frame',
  });

  /// Called with each code's raw value (non-empty).
  final ValueChanged<String> onCode;
  final bool paused;
  final String hint;

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (widget.paused) return;
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue;
      if (code != null && code.isNotEmpty) {
        widget.onCode(code);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BjRadius.all(BjRadius.xl),
      child: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          CustomPaint(painter: ScannerOverlayPainter(), child: Container()),
          Positioned(
            bottom: BjSpace.xxl,
            left: BjSpace.lg,
            right: BjSpace.lg,
            child: Center(child: ScanHint(text: widget.hint)),
          ),
        ],
      ),
    );
  }
}

/// The pill of text over the camera feed saying what to do.
class ScanHint extends StatelessWidget {
  const ScanHint({super.key, this.text = 'Align the QR code within the frame'});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: BjSpace.xl, vertical: BjSpace.md),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BjRadius.all(BjRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.center_focus_strong_rounded,
            color: Colors.white, size: 20),
        const SizedBox(width: BjSpace.sm),
        Flexible(
          child: Text(text,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: Colors.white),
              textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}

/// A scrim over the camera feed with a rounded square cutout and corner
/// brackets.
class ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final cutoutSize = size.shortestSide * 0.7;
    final cutoutRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: cutoutSize,
      height: cutoutSize,
    );

    final paint = Paint()
      // A scrim over the camera feed, whatever the theme.
      ..color = Colors.black.withValues(alpha: 0.54)
      ..style = PaintingStyle.fill;

    final path = Path()
      ..addRect(rect)
      ..addRRect(RRect.fromRectAndRadius(
          cutoutRect, const Radius.circular(BjRadius.lg)))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paint);

    final bracketPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    const l = 30.0;
    final corners = [
      (cutoutRect.topLeft, const Offset(l, 0), const Offset(0, l)),
      (cutoutRect.topRight, const Offset(-l, 0), const Offset(0, l)),
      (cutoutRect.bottomLeft, const Offset(l, 0), const Offset(0, -l)),
      (cutoutRect.bottomRight, const Offset(-l, 0), const Offset(0, -l)),
    ];
    for (final (corner, across, down) in corners) {
      canvas.drawLine(corner, corner + across, bracketPaint);
      canvas.drawLine(corner, corner + down, bracketPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
