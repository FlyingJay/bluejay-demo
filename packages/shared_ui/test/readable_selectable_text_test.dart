import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/clickable_url.dart';
import 'package:shared_ui/readable_selectable_text.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('its text is in the semantics tree, and it is selectable',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, const ReadableSelectableText('See you at the fair'));

    expect(find.bySemanticsLabel('See you at the fair'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('rich text is read whole', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(
      tester,
      const ReadableSelectableText.rich(
        TextSpan(children: [TextSpan(text: 'Bring '), TextSpan(text: 'chairs')]),
      ),
    );

    expect(find.bySemanticsLabel('Bring chairs'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('clickable text is readable', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(
      tester,
      Builder(builder: (context) => buildClickableText(context, 'Roster at example.com today')),
    );

    // A link splits the text into one node per span; the link is tappable.
    final labels = <String>[];
    void collect(SemanticsNode node) {
      labels.add(node.label);
      node.visitChildren((child) {
        collect(child);
        return true;
      });
    }

    collect(tester.getSemantics(find.byType(Text)));
    expect(labels, containsAllInOrder(['Roster at ', 'example.com', ' today']));
    semantics.dispose();
  });
}
