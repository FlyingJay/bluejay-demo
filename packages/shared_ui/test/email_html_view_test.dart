import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/email_html_view.dart';

void main() {
  group('buildEmailHtmlDocument', () {
    String build(String html, {bool sizeToContent = true, bool forward = false}) =>
        buildEmailHtmlDocument(html,
            frameId: 'frame1', nonce: 'n0nce', sizeToContent: sizeToContent, forwardScrolling: forward);

    test('puts the CSP first and only allows the nonced script', () {
      final doc = build('<p>Hi</p>');
      final head = doc.substring(doc.indexOf('<head>'), doc.indexOf('</head>'));
      expect(head.indexOf('Content-Security-Policy'), lessThan(head.indexOf('<script')));
      expect(doc, contains("script-src 'nonce-n0nce'"));
      expect(doc, contains("default-src 'none'"));
      expect(doc, contains("form-action 'none'"));
      expect(doc, contains('<script nonce="n0nce">'));
    });

    test('keeps the email after the head so it cannot swallow the script', () {
      final doc = build('<!-- unclosed <img src="https://x/y.png">');
      expect(doc.indexOf('</head>'), lessThan(doc.indexOf('<!-- unclosed')));
      expect(doc, contains('<img src="https://x/y.png">'));
    });

    test('allows remote and inline images', () {
      expect(build('').contains('img-src https: http: data: cid:'), isTrue);
    });

    test('only clips vertical overflow when sized to content', () {
      expect(build(''), contains('overflow-y: hidden'));
      expect(build('', sizeToContent: false), isNot(contains('overflow-y: hidden')));
    });

    test('tags messages with the frame id', () {
      expect(build(''), contains('var id = "frame1";'));
      expect(build('', forward: true), contains('if (!true) return;'));
    });

    test('links open in a new tab only when asked', () {
      expect(buildEmailHtmlDocument('', frameId: 'a', nonce: 'b'), contains('<base target="_blank">'));
      expect(buildEmailHtmlDocument('', frameId: 'a', nonce: 'b', linksInNewTab: false),
          isNot(contains('<base')));
    });
  });
}
