// Native frame for EmailHtmlView: a WebView on iOS, Android and macOS.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// WebViews ignore `target="_blank"`; link taps are routed out instead.
const bool emailHtmlFrameOpensLinksInNewTab = false;

/// Flutter already receives drags over a platform view.
const bool emailHtmlFrameForwardsScrolling = false;

/// Windows and Linux have no WebView implementation.
bool emailHtmlFrameSupported() => WebViewPlatform.instance != null;

class EmailHtmlFrame extends StatefulWidget {
  const EmailHtmlFrame({
    super.key,
    required this.document,
    required this.onMessage,
  });

  final String document;
  final ValueChanged<String> onMessage;

  @override
  State<EmailHtmlFrame> createState() => _EmailHtmlFrameState();
}

class _EmailHtmlFrameState extends State<EmailHtmlFrame> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // Needed for the sizing script; the document's CSP blocks the email's.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('BjEmailHtml',
          onMessageReceived: (message) => widget.onMessage(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (uri == null || uri.scheme == 'about' || uri.scheme == 'data') {
            return NavigationDecision.navigate;
          }
          launchUrl(uri, mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
      ))
      ..loadHtmlString(widget.document);
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
