import 'dart:convert';
import 'dart:typed_data';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/file_pick.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_ui/record_import_flow.dart';

/// The shared import screen, step by step: choose a file, match columns,
/// preview with a duplicate choice, write, and undo from the result.
void main() {
  late FakeFirebaseFirestore fake;
  late RecordImportStore store;

  final spec = ImportSpec(
    id: 'test.item',
    appId: 'inventory',
    collection: 'inventory_items',
    label: 'Items',
    singular: 'item',
    remove: const ImportRemove.archive('archived'),
    fields: const [
      ImportField.text('name', 'Name', required: true, example: 'Widget'),
      ImportField.text('sku', 'SKU', example: 'W-1'),
      ImportField.money('unitCostCents', 'Unit cost', aliases: ['cost'], example: '2.50'),
    ],
    duplicateKeys: const [ImportKey(['sku'], label: 'SKU')],
    build: (row, ctx) => {
      'name': row.text('name'),
      'sku': row.text('sku'),
      if (row.has('unitCostCents')) 'unitCostCents': row['unitCostCents'],
      'archived': false,
    },
  );

  PickedFileData csv(String text) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    return PickedFileData(name: 'stock.csv', size: bytes.length, bytes: bytes);
  }

  Future<void> open(WidgetTester t, PickedFileData file) async {
    t.view.physicalSize = const Size(1280, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: BluejayTheme.build(),
      home: RecordImportScreen(
        specs: [spec],
        initial: spec,
        store: store,
        uid: 'u1',
        members: const [],
        pickFile: (_) async => file,
      ),
    ));
    await t.tap(find.text('Choose file'));
    await t.pumpAndSettle();
  }

  setUp(() async {
    fake = FakeFirebaseFirestore();
    store = RecordImportStore(
      scoped: (c, a) => ScopedCollection(collection: c, appId: a, firestore: fake, currentUid: () => 'u1'),
      currentUid: () => 'u1',
    );
    ActiveGroupService.instance.activeGroupId = 'g1';
    await fake.doc('inventory_items/existing').set(
        {'name': 'Bolt', 'sku': 'B-1', 'archived': false, 'groupId': 'g1', 'appId': 'inventory'});
  });

  tearDown(() => ActiveGroupService.instance.activeGroupId = null);

  testWidgets('choose, match, preview, import and undo', (t) async {
    await open(t, csv('Item name,SKU,Cost,Colour\nWidget,W-1,2.50,Red\nBolt again,b-1,1,Grey\n,X-1,1,\nNut,N-1,lots,\n'));

    // Match: "Item name" isn't an alias, so the required Name blocks Next.
    expect(find.text('Match your columns'), findsOneWidget);
    expect(find.textContaining('Not imported: Item name, Colour'), findsOneWidget);
    expect(find.textContaining('Match a column to Name to continue'), findsOneWidget);
    await t.tap(find.byType(DropdownButtonFormField<int?>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Item name').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Next'));
    await t.pumpAndSettle();

    // Preview: two new, one matching by SKU, one problem; the bad cost is flagged.
    expect(find.text('Import 2 items'), findsOneWidget);
    expect(find.textContaining('Already in your items as Bolt'), findsOneWidget);
    expect(find.text('No name'), findsOneWidget);
    expect(find.text('Rows not imported'), findsOneWidget);
    await t.tap(find.widgetWithText(ChoiceChip, 'With problems'));
    await t.pumpAndSettle();
    expect(find.text('Widget'), findsNothing);
    await t.tap(find.widgetWithText(ChoiceChip, 'All'));
    await t.pumpAndSettle();

    // Update the matching row instead of skipping it.
    await t.tap(find.text('Update'));
    await t.pumpAndSettle();
    expect(find.text('Import 2 items, update 1'), findsOneWidget);
    expect(find.text('Replace existing values'), findsOneWidget);

    await t.tap(find.text('Import 2 items, update 1'));
    await t.pumpAndSettle();
    expect(find.text('Import finished'), findsOneWidget);
    expect(find.textContaining('2 items added. 1 updated'), findsOneWidget);
    final items = (await fake.collection('inventory_items').get()).docs;
    expect(items, hasLength(3));
    expect((await fake.doc('inventory_items/existing').get()).data()!['unitCostCents'], 100);

    // Undo from the result.
    await t.tap(find.text('Undo import'));
    await t.pumpAndSettle();
    expect(find.text('Undo this import?'), findsOneWidget);
    expect(find.textContaining('2 added items will be archived'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Undo import'));
    await t.pumpAndSettle();
    final archived = (await fake.collection('inventory_items').get()).docs.where((d) => d.data()['archived'] == true);
    expect(archived, hasLength(2));
    expect((await fake.doc('inventory_items/existing').get()).data()!.containsKey('unitCostCents'), isFalse);
  });

  testWidgets('a file with no rows is refused on the first step', (t) async {
    await open(t, csv('Name,SKU\n'));
    expect(find.text('The file has column names but no rows.'), findsOneWidget);
    expect(find.text('Match your columns'), findsNothing);
  });

  testWidgets('the import entry hides when the viewer can\'t create', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Column(children: [
          RecordImportButton(spec: spec, canImport: false),
          Text('${recordImportActions(context, spec: spec, canImport: true, label: 'Import items').single.label}'),
        ]),
      ),
    ));
    expect(find.text('Import'), findsNothing);
    expect(find.text('Import items'), findsOneWidget);
  });

  test('the button label states the work', () {
    expect(importButtonLabel(spec, const ImportPlan()), 'Nothing to import');
    expect(
      importButtonLabel(spec, const ImportPlan(creates: [PlannedCreate(2, {})])),
      'Import 1 item',
    );
    expect(
      importButtonLabel(
          spec, const ImportPlan(updates: [PlannedUpdate(2, ImportExisting('a', {}), {'x': 1})])),
      'Update 1',
    );
  });
}
