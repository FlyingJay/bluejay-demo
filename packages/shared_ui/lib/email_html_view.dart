import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'readable_selectable_text.dart';
import 'email_html_frame_io.dart'
    if (dart.library.html) 'email_html_frame_web.dart';

/// Shows an email's HTML body (images, buttons, tables, styles) the way
/// the sender laid it out.
///
/// Email HTML is untrusted, so it runs in an isolated frame: a sandboxed
/// iframe with an opaque origin on the web, a WebView on iOS, Android and
/// macOS. A content security policy blocks every script except the frame's
/// own sizing script, plus forms and nested frames. Links open outside the
/// app. Where neither frame is available it shows [fallbackText].
///
/// By default the view is as tall as the email and scrolls with the page
/// around it. With [expand] it fills its parent and scrolls on its own.
class EmailHtmlView extends StatefulWidget {
  const EmailHtmlView({
    super.key,
    required this.html,
    this.fallbackText,
    this.fallbackStyle,
    this.expand = false,
  });

  final String html;

  /// Shown instead on platforms that can't render HTML (Windows, Linux).
  final String? fallbackText;

  /// Style for [fallbackText].
  final TextStyle? fallbackStyle;

  final bool expand;

  @override
  State<EmailHtmlView> createState() => _EmailHtmlViewState();
}

class _EmailHtmlViewState extends State<EmailHtmlView> {
  static const double _initialHeight = 120;

  /// Keeps a hostile email from asking for an unbounded platform view.
  static const double _maxHeight = 40000;

  final String _frameId = _randomToken();
  late String _document;
  double _height = _initialHeight;

  @override
  void initState() {
    super.initState();
    _document = _build();
  }

  @override
  void didUpdateWidget(EmailHtmlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html || oldWidget.expand != widget.expand) {
      _document = _build();
      _height = _initialHeight;
    }
  }

  String _build() => buildEmailHtmlDocument(
        widget.html,
        frameId: _frameId,
        nonce: _randomToken(),
        linksInNewTab: emailHtmlFrameOpensLinksInNewTab,
        sizeToContent: !widget.expand,
        forwardScrolling: !widget.expand && emailHtmlFrameForwardsScrolling,
      );

  void _onMessage(String raw) {
    final Object? data;
    try {
      data = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (data is! Map || data['bjEmailHtml'] != _frameId) return;
    final height = data['height'];
    if (height is num && !widget.expand) {
      final next = height.toDouble().clamp(1.0, _maxHeight);
      if ((next - _height).abs() >= 1) setState(() => _height = next);
    }
    final scroll = data['scrollBy'];
    if (scroll is num && !widget.expand) _scrollPage(scroll.toDouble());
  }

  /// The frame swallows wheel and touch scrolling, so it forwards the
  /// deltas here and the page around it scrolls instead.
  void _scrollPage(double delta) {
    final position = Scrollable.maybeOf(context)?.position;
    if (position == null) return;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) position.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    if (!emailHtmlFrameSupported()) {
      return ReadableSelectableText(widget.fallbackText ?? '(No body content)',
          style: widget.fallbackStyle);
    }
    final frame = EmailHtmlFrame(
      key: ValueKey(_document),
      document: _document,
      onMessage: _onMessage,
    );
    if (widget.expand) return frame;
    return SizedBox(height: _height, child: frame);
  }
}

String _randomToken() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Wraps an email's HTML in the document the frame loads: a content
/// security policy that only lets the script carrying [nonce] run, base
/// styles that keep wide content inside the frame, and a script that
/// posts messages tagged with [frameId]: the content height when
/// [sizeToContent], wheel and touch scrolling when [forwardScrolling].
///
/// The policy and script go in the head, ahead of the email, so nothing
/// the email contains (an unclosed comment, a stray `</body>`) can swallow
/// or override them. A meta policy can only be narrowed by a later one.
String buildEmailHtmlDocument(
  String html, {
  required String frameId,
  required String nonce,
  bool linksInNewTab = true,
  bool sizeToContent = true,
  bool forwardScrolling = false,
}) {
  const policy = "default-src 'none'; "
      "style-src 'unsafe-inline' https: http:; "
      'img-src https: http: data: cid: blob:; '
      'font-src https: http: data:; '
      'media-src https: http: data:; '
      "form-action 'none'; "
      "frame-src 'none'; "
      "object-src 'none'";
  return '''<!DOCTYPE html>
<html>
<head>
<meta http-equiv="Content-Security-Policy" content="$policy; script-src 'nonce-$nonce'">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${linksInNewTab ? '<base target="_blank">' : ''}
<style>
  html { background: #ffffff; color: #1a1a2e; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    font-size: 15px;
    line-height: 1.5;
    overflow-wrap: anywhere;
${sizeToContent ? '    overflow-y: hidden;\n' : ''}  }
  img { max-width: 100%; height: auto; }
  table { max-width: 100%; }
  pre { white-space: pre-wrap; }
</style>
<script nonce="$nonce">
(function () {
  var id = ${jsonEncode(frameId)};
  function post(payload) {
    payload.bjEmailHtml = id;
    var message = JSON.stringify(payload);
    if (window.BjEmailHtml && window.BjEmailHtml.postMessage) {
      window.BjEmailHtml.postMessage(message);
    } else if (window.parent !== window) {
      window.parent.postMessage(message, '*');
    }
  }
  if (!$sizeToContent) return;
  var last = -1;
  function sendHeight() {
    var body = document.body;
    var height = Math.ceil(Math.max(
      document.documentElement.scrollHeight,
      body ? body.scrollHeight : 0));
    if (height !== last) { last = height; post({ height: height }); }
  }
  document.addEventListener('DOMContentLoaded', sendHeight);
  window.addEventListener('load', sendHeight);
  document.addEventListener('load', sendHeight, true);
  if (window.ResizeObserver) {
    new ResizeObserver(sendHeight).observe(document.documentElement);
  }
  if (!$forwardScrolling) return;
  window.addEventListener('wheel', function (e) {
    if (e.deltaY) post({ scrollBy: e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY });
  }, { passive: true });
  var touchY = null;
  window.addEventListener('touchstart', function (e) {
    touchY = e.touches.length ? e.touches[0].clientY : null;
  }, { passive: true });
  window.addEventListener('touchmove', function (e) {
    if (touchY === null || !e.touches.length) return;
    var y = e.touches[0].clientY;
    post({ scrollBy: touchY - y });
    touchY = y;
  }, { passive: true });
})();
</script>
</head>
<body>
$html
</body>
</html>''';
}
