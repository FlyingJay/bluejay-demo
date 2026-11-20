import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/profile_photo_avatar.dart';

const _url = 'https://example.com/me.jpg';

Key? _imageKey(WidgetTester tester) =>
    tester.widget<Image>(find.byType(Image)).key;

void main() {
  testWidgets('shows the fallback when there is no photo', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ProfilePhotoAvatar(
          url: null, radius: 16, fallback: Icon(Icons.person)),
    ));
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('keeps the fallback under the photo while it loads or fails',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ProfilePhotoAvatar(
          url: _url, radius: 16, fallback: Icon(Icons.person)),
    ));
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('reloads the photo when its screen is back in front',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(
        body: ProfilePhotoAvatar(
            url: _url, radius: 16, fallback: Icon(Icons.person)),
      ),
    ));
    final before = _imageKey(tester);

    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('An app'))));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(_imageKey(tester), isNot(before));
    // Let any retry timer from the failed test-environment load expire.
    await tester.pump(const Duration(minutes: 1));
  });
}
