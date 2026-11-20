// Web frame for EmailHtmlView: a sandboxed iframe with an opaque origin.
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';

/// `<base target="_blank">` works here; the sandbox lets those tabs escape.
const bool emailHtmlFrameOpensLinksInNewTab = true;

/// Wheel and touch input over an iframe never reaches Flutter.
const bool emailHtmlFrameForwardsScrolling = true;

bool emailHtmlFrameSupported() => true;

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
  StreamSubscription<html.MessageEvent>? _messages;

  @override
  void initState() {
    super.initState();
    _messages = html.window.onMessage.listen((event) {
      final data = event.data;
      if (data is String) widget.onMessage(data);
    });
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView.fromTagName(
      tagName: 'iframe',
      onElementCreated: (element) {
        (element as html.IFrameElement)
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.border = 'none'
          ..style.background = '#ffffff'
          // No allow-same-origin: the email gets an opaque origin and can't
          // reach the app's DOM, cookies or storage. Scripts are allowed
          // only so the frame's own sizing script runs; the document's CSP
          // blocks every other script. Popups let links open in a new tab.
          ..setAttribute(
              'sandbox', 'allow-scripts allow-popups allow-popups-to-escape-sandbox')
          ..setAttribute('referrerpolicy', 'no-referrer')
          ..srcdoc = widget.document;
      },
    );
  }
}
