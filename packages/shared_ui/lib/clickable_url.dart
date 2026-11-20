import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui/readable_selectable_text.dart';
import 'package:shared_ui/webview_screen.dart';
import 'package:url_launcher/url_launcher.dart';

/// A helper function that takes a string and returns selectable text with
/// any URLs formatted as clickable links. The text is selectable for copying
/// and readable by screen readers (see [ReadableSelectableText]).
Widget buildClickableText(
  BuildContext context,
  String text, {
  TextStyle? defaultStyle,
  TextStyle? linkStyle,
}) {
  final List<TextSpan> textSpans = [];
  final RegExp urlRegExp = RegExp(
    r"(http(s)?://.)?(www\.)?[-a-zA-Z0-9@:%._\+~#=]{2,256}\.[a-z]{2,6}\b([-a-zA-Z0-9@:%_\+.~#?&//=]*)",
    caseSensitive: false,
  );

  final finalDefaultStyle =
      defaultStyle ?? Theme.of(context).textTheme.bodyMedium;
  final finalLinkStyle = linkStyle ??
      (finalDefaultStyle ?? const TextStyle()).copyWith(
        color: context.bj.accent,
        fontWeight: FontWeight.w500,
        decoration: TextDecoration.underline,
        decorationColor: context.bj.accent.withValues(alpha: 0.4),
      );

  text.splitMapJoin(
    urlRegExp,
    onMatch: (Match match) {
      String url = match.group(0)!;
      // Ensure URL starts with http:// or https:// for launching
      if (!url.startsWith('http')) {
        url = 'https://$url';
      }
      textSpans.add(
        TextSpan(
          text: match.group(0)!,
          style: finalLinkStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () {
              if (kIsWeb) {
                // On web, open the URL in a new tab
                launchUrl(Uri.parse(url));
              } else {
                // On mobile, use the in-app WebView
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => WebViewScreen(url: url),
                ));
              }
            },
        ),
      );
      return '';
    },
    onNonMatch: (String nonMatch) {
      textSpans.add(TextSpan(text: nonMatch, style: finalDefaultStyle));
      return '';
    },
  );

  return ReadableSelectableText.rich(
    TextSpan(children: textSpans),
  );
}
