import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/csv_export.dart';
import 'package:shared_services/generated/collection_policies.g.dart';
import 'package:shared_services/record_import.dart';

const _ctx = ImportContext();

final _items = ImportSpec(
  id: 'test.item',
  appId: 'inventory',
  collection: 'inventory_items',
  label: 'Items',
  singular: 'item',
  remove: const ImportRemove.archive('archived'),
  fields: [
    const ImportField.text('name', 'Name', required: true, aliases: ['item', 'product'], example: 'Widget'),
    const ImportField.text('sku', 'SKU', aliases: ['code', 'part number'], example: 'W-1'),
    ImportField.choice('unit', 'Unit',
        choices: (ctx) => const [ImportChoice('each', 'Each', aliases: ['ea']), ImportChoice('kg', 'Kilograms')]),
    const ImportField.money('unitCostCents', 'Unit cost', aliases: ['cost'], example: '12.50'),
    ImportField.integer('reorderPoint', 'Reorder point', validate: (v) => (v as int) < 0 ? 'can\'t be negative' : null),
    const ImportField.date('receivedOn', 'Received'),
    const ImportField.list('tags', 'Tags'),
  ],
  duplicateKeys: const [ImportKey(['sku'], label: 'SKU'), ImportKey(['name'])],
  build: (row, ctx) => {
    'name': row.text('name'),
    'sku': row.text('sku'),
    if (row.has('unit')) 'unit': row['unit'],
    if (row.has('unitCostCents')) 'unitCostCents': row['unitCostCents'],
    if (row.has('reorderPoint')) 'reorderPoint': row['reorderPoint'],
    'tags': row.list('tags'),
    'archived': false,
  },
);

ImportPlan _plan(String csv,
    {List<ImportExisting> existing = const [], ImportSettings settings = const ImportSettings(), int? maxRows}) {
  final table = parseCsvTable(csv);
  return planImport(_items, table, guessCsvColumns(table.headers, _items.csvFields),
      ctx: ImportContext(existing: existing), settings: settings, maxRows: maxRows ?? kMaxImportRows);
}

void main() {
  group('field types', () {
    ImportParsed parse(ImportField f, String raw, {bool dayFirst = false}) => f.parse(raw, _ctx, dayFirst: dayFirst);

    test('numbers, money and whole numbers', () {
      expect(parseImportNumber('1,234.5'), 1234.5);
      expect(parseImportNumber('(3)'), -3);
      expect(parseImportNumber('12%'), 12);
      expect(parseImportNumber('abc'), isNull);
      expect(parseImportMoneyCents(r'$1,234.56'), 123456);
      expect(parseImportMoneyCents('CAD 12'), 1200);
      expect(parseImportMoneyCents('(4.005)'), -401);
      expect(parse(const ImportField.integer('n', 'N'), '7').value, 7);
      expect(parse(const ImportField.integer('n', 'N'), '7.5').error, contains('whole number'));
    });

    test('dates in the common spreadsheet spellings', () {
      expect(parseImportDate('2026-03-31'), DateTime(2026, 3, 31));
      expect(parseImportDate('2026-03-31T10:00:00Z'), DateTime(2026, 3, 31));
      expect(parseImportDate('3/4/2026'), DateTime(2026, 3, 4));
      expect(parseImportDate('3/4/2026', dayFirst: true), DateTime(2026, 4, 3));
      expect(parseImportDate('31/3/2026'), DateTime(2026, 3, 31));
      expect(parseImportDate('31 Mar 2026'), DateTime(2026, 3, 31));
      expect(parseImportDate('March 31, 2026'), DateTime(2026, 3, 31));
      expect(parseImportDate('2026-02-30'), isNull);
      expect(parseImportDate('soon'), isNull);
    });

    test('yes/no, choices, lists, emails and the export quote', () {
      expect(parseImportYesNo('Yes'), isTrue);
      expect(parseImportYesNo('0'), isFalse);
      expect(parseImportYesNo('maybe'), isNull);
      final unit = _items.field('unit')!;
      expect(parse(unit, 'EA').value, 'each');
      expect(parse(unit, 'kilograms').value, 'kg');
      expect(parse(unit, 'litres').error, contains('Each, Kilograms'));
      expect(splitImportList('a; b, A | c\nb'), ['a', 'b', 'c']);
      expect(parse(const ImportField.email('e', 'Email'), 'Jo@X.example').value, 'jo@x.example');
      expect(parse(const ImportField.email('e', 'Email'), 'jo at x').error, isNotNull);
      expect(stripExportQuote("'=SUM(A1)"), '=SUM(A1)');
      expect(stripExportQuote("'tis"), "'tis");
      expect(parse(const ImportField.text('t', 'T'), "'-3 dB").value, '-3 dB');
    });

    test('members and lookups resolve to ids', () {
      const ctx = ImportContext(memberEmails: {'priya@x.example': 'u-priya'});
      expect(const ImportField.member('o', 'Owner').parse('PRIYA@x.example', ctx).value, 'u-priya');
      expect(const ImportField.member('o', 'Owner').parse('who@x.example', ctx).error, contains('not a member'));
      final client = ImportField.lookup('clientId', 'Client', lookup: (_) => {'acme ltd': 'c1'});
      expect(client.parse('  ACME   Ltd ', ctx).value, 'c1');
      expect(client.parse('Globex', ctx).error, contains('No client named "Globex"'));
    });
  });

  group('planner', () {
    test('creates, required problems and flagged optional values', () {
      final p = _plan('Item,Code,Cost,Reorder point,Unit\n'
          'Widget,W-1,\$2.50,5,ea\n'
          ',W-2,1,1,\n'
          'Gadget,G-1,lots,-2,litres\n');
      expect(p.creates.map((c) => c.data['name']), ['Widget', 'Gadget']);
      expect(p.creates.first.data['unitCostCents'], 250);
      expect(p.creates.first.data['unit'], 'each');
      expect(p.problems.single.line, 3);
      expect(p.problems.single.reason, 'No name');
      final gadget = p.creates.last.data;
      expect(gadget.containsKey('unitCostCents'), isFalse);
      expect(gadget.containsKey('reorderPoint'), isFalse);
      expect(p.flags.where((f) => f.line == 4).map((f) => f.field), containsAll(['unitCostCents', 'reorderPoint', 'unit']));
    });

    test('a required field with no column leaves every row out', () {
      final p = _plan('Code\nW-1\n');
      expect(p.problems.single.reason, 'No name column');
    });

    test('duplicates in the file and in the list, on the first key with a value', () {
      final existing = [
        const ImportExisting('i1', {'name': 'Widget', 'sku': 'W-1', 'archived': false}),
        const ImportExisting('i2', {'name': 'Old', 'sku': 'O-1', 'archived': true}),
      ];
      final p = _plan(
        'Name,SKU\n'
        'Widget again,w-1\n' // matches i1 by SKU
        'Sprocket,S-1\n'
        'Sprocket two,s-1\n' // same SKU as line 3
        'Old,O-1\n' // archived records don't count
        'widget,\n', // no SKU: matches i1 by name
        existing: existing,
      );
      expect(p.creates.map((c) => c.data['name']), ['Sprocket', 'Old']);
      expect(p.duplicates.map((d) => d.line), [2, 4, 6]);
      expect(p.duplicates[0].reason, 'Already in your items as Widget');
      expect(p.duplicates[1].reason, 'Same SKU as line 3');
    });

    test('update fills blanks, replace overwrites, add anyway creates', () {
      final existing = [
        const ImportExisting('i1', {'name': 'Widget', 'sku': 'W-1', 'tags': ['a'], 'archived': false}),
      ];
      const csv = 'Name,SKU,Cost,Tags\nWidget 2,W-1,3,a; b\nWidget 3,W-1,4,\n';
      final update = _plan(csv, existing: existing, settings: const ImportSettings(duplicates: ImportDuplicates.update));
      expect(update.updates.single.changes, {'unitCostCents': 300, 'tags': ['a', 'b']});
      expect(update.duplicates.single.line, 3, reason: 'one update per record');

      final replace = _plan(csv,
          existing: existing,
          settings: const ImportSettings(duplicates: ImportDuplicates.update, replaceExisting: true));
      expect(replace.updates.single.changes['name'], 'Widget 2');

      final add = _plan(csv, existing: existing, settings: const ImportSettings(duplicates: ImportDuplicates.addAnyway));
      expect(add.creates, hasLength(2));
    });

    test('nothing new counts as unchanged', () {
      final p = _plan('Name,SKU\nWidget,W-1\n',
          existing: [const ImportExisting('i1', {'name': 'Widget', 'sku': 'W-1', 'tags': [], 'archived': false})],
          settings: const ImportSettings(duplicates: ImportDuplicates.update));
      expect(p.updates, isEmpty);
      expect(p.unchanged, 1);
    });

    test('ownerField: only the importer\'s own records count as duplicates', () {
      final spec = ImportSpec(
        id: 'test.product',
        appId: 'shop',
        collection: 'shop_products',
        label: 'Products',
        singular: 'product',
        ownerField: 'ownerId',
        fields: const [ImportField.text('name', 'Name', required: true)],
        duplicateKeys: const [ImportKey(['name'])],
        build: (row, ctx) => {'name': row.text('name'), 'ownerId': ctx.uid},
      );
      final table = parseCsvTable('Name\nTable\nBench\n');
      final p = planImport(spec, table, guessCsvColumns(table.headers, spec.csvFields),
          ctx: const ImportContext(uid: 'me', existing: [
            ImportExisting('a', {'name': 'Table', 'ownerId': 'me'}),
            ImportExisting('b', {'name': 'Bench', 'ownerId': 'someone-else'}),
          ]));
      expect(p.duplicates.single.line, 2);
      expect(p.creates.single.data['name'], 'Bench');
    });

    test('a date column with a day-first date reads every date day first', () {
      final table = parseCsvTable('Name,Received\nA,3/4/2026\nB,31/3/2026\n');
      final p = planImport(_items, table, guessCsvColumns(table.headers, _items.csvFields));
      expect(p.rows.first['receivedOn'], DateTime(2026, 4, 3));
    });

    test('reads at most the row cap', () {
      final p = _plan('Name\nA\nB\nC\n', maxRows: 2);
      expect(p.creates, hasLength(2));
      expect(p.rowsOverLimit, 1);
    });

    test('expansion: an extra record created once and referenced', () {
      final spec = ImportSpec(
        id: 'test.person',
        appId: 'contacts',
        collection: 'contacts',
        label: 'People',
        singular: 'person',
        fields: const [ImportField.text('name', 'Name', required: true), ImportField.text('org', 'Organization')],
        build: (row, ctx) => {'name': row.text('name')},
        expand: (row, data, ctx, x) => row.has('org')
            ? ImportBuildCreate({...data, 'orgId': x.ensure(row.text('org').toLowerCase(), row.line, () => {'name': row.text('org')})})
            : null,
      );
      final table = parseCsvTable('Name,Organization\nA,Acme\nB,ACME\nC,\n');
      final p = planImport(spec, table, guessCsvColumns(table.headers, spec.csvFields));
      expect(p.extras.single.data, {'name': 'Acme'});
      expect(p.creates.map((c) => c.data['orgId']), [const ImportRef('acme'), const ImportRef('acme'), null]);
      expect(p.createCount, 4);
    });

    test('rows not imported download with a Reason column', () {
      final table = parseCsvTable('Name,SKU\n,W-1\nB,B-1\n');
      final p = planImport(_items, table, guessCsvColumns(table.headers, _items.csvFields));
      expect(notImportedCsvRows(table, p), [
        ['Name', 'SKU', 'Reason'],
        ['', 'W-1', 'No name'],
      ]);
    });

    test('the template maps itself and plans one clean create', () {
      final table = parseCsvTable(encodeCsv(_items.templateRows()));
      final mapping = guessCsvColumns(table.headers, _items.csvFields);
      expect(mapping.values, everyElement(isNotNull));
      final p = planImport(_items, table, mapping);
      expect(p.creates, hasLength(1));
      expect(p.problems, isEmpty);
    });
  });

  group('fill blanks and fingerprints', () {
    test('fillBlanks never overwrites unless replacing', () {
      expect(fillBlanks({'a': 'x', 'b': ''}, {'a': 'y', 'b': 'z', 'c': null}), {'b': 'z'});
      expect(fillBlanks({'a': 'x'}, {'a': 'y'}, replace: true), {'a': 'y'});
      expect(fillBlanks({'a': 'x'}, {'a': 'x'}, replace: true), isEmpty);
    });

    test('a fingerprint survives a read back and changes with an edit', () {
      final written = {'n': 5, 'd': DateTime.utc(2026, 1, 2), 'l': ['a'], 'm': {'b': 1, 'a': 2}};
      final readBack = {'n': 5.0, 'd': DateTime.utc(2026, 1, 2), 'l': ['a'], 'm': {'a': 2, 'b': 1}, 'other': 1};
      final keys = ['n', 'd', 'l', 'm'];
      expect(importFingerprint(readBack, keys), importFingerprint(written, keys));
      expect(importFingerprint({...readBack, 'n': 6}, keys), isNot(importFingerprint(written, keys)));
      expect(importFingerprint(written, keys), hasLength(16));
    });
  });

  group('registry and the policy check', () {
    test('ids are unique', () {
      registerImportSpec(_items);
      registerImportSpec(_items);
      expect(importSpecById('test.item'), same(_items));
      expect(
        () => registerImportSpec(ImportSpec(
            id: 'test.item', appId: 'x', collection: 'x', label: 'X', singular: 'x', fields: const [], build: (_, __) => {})),
        throwsStateError,
      );
    });

    test('a spec must fit the collection policy table', () {
      expect(checkImportSpec(_items), isEmpty);
      final bad = ImportSpec(
        id: 'Bad Id',
        appId: 'crm',
        collection: 'inventory_items',
        label: 'Items',
        singular: 'item',
        fields: const [ImportField.integer('onHand', 'On hand')],
        build: (_, __) => {},
      );
      final problems = checkImportSpec(bad);
      expect(problems, contains(contains('lower case')));
      expect(problems, contains(contains('crm is not one of')));
      expect(problems, contains('onHand is a server field of inventory_items'));
      expect(problems, contains(contains('blocks deletes')));
      expect(checkImportSpec(bad.copyForTest(collection: 'audit_events')), contains(contains('written only by Cloud Functions')));
      expect(checkImportSpec(bad.copyForTest(collection: 'nope_not_declared')), contains(contains('not in security')));
    });

    test('import_batches is declared for every adopting app', () {
      final p = collectionPolicies['import_batches']!;
      expect(p.ownerScoped, isTrue);
      expect(p.blockDelete, isTrue);
      expect(p.apps, containsAll(['contacts', 'crm', 'inventory', 'hr', 'time-tracking', 'shop', 'lists']));
    });
  });
}

extension on ImportSpec {
  ImportSpec copyForTest({required String collection}) => ImportSpec(
        id: id,
        appId: appId,
        collection: collection,
        label: label,
        singular: singular,
        fields: fields,
        build: build,
      );
}
