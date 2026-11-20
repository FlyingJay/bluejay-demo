import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A folder → file drill-down held in state, the shape BjBackStep is for.
class _Browser extends StatefulWidget {
  const _Browser();

  @override
  State<_Browser> createState() => _BrowserState();
}

class _BrowserState extends State<_Browser> {
  String? folder;
  String? file;

  void open(String folder, String file) => setState(() {
        this.folder = folder;
        this.file = file;
      });

  @override
  Widget build(BuildContext context) {
    return BjBackStep(
      active: folder != null,
      onBack: () => setState(() => folder = null),
      child: BjBackStep(
        active: file != null,
        onBack: () => setState(() => file = null),
        child: Text(file ?? folder ?? 'root'),
      ),
    );
  }
}

void main() {
  testWidgets('browser back closes one sub-view per press, then the screen',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: _Browser()),
          )),
          child: const Text('launcher'),
        ),
      ),
    ));
    await t.tap(find.text('launcher'));
    await t.pumpAndSettle();

    t.state<_BrowserState>(find.byType(_Browser)).open('docs', 'notes.txt');
    await t.pump();
    expect(find.text('notes.txt'), findsOneWidget);

    // What the web engine sends for the browser's back button.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('docs'), findsOneWidget);

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('root'), findsOneWidget);

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('launcher'), findsOneWidget);
  });
}
