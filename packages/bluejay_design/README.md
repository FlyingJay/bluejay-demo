# bluejay_design

Bluejay's design system. The launcher's root `MaterialApp` is themed with
`BluejayTheme.build()`, so every app already gets the fonts, colors, shapes
and page transitions below. Apps build screens from the components here and
read tokens from it rather than keeping their own `*_theme.dart`.

```dart
import 'package:bluejay_design/bluejay_design.dart';
```

## Brand guide

This package implements the visual side of Bluejay's brand and style guide
(`brand/BRAND_GUIDE.md` in the private `bluejayorg/bluejay-business`
repository), which carries the same colors, type, shapes and motion for the
website, documents and marketing, plus the voice for all text. The package
is the source of those values: `design_tokens.json` publishes them, and
`test/design_tokens_test.dart` fails when a token changes without
regenerating it:

```sh
BJ_UPDATE_TOKENS=1 flutter test test/design_tokens_test.dart
```

A PR that changes a token says so, and the guide is updated to match the
same day (`brand/tools/check_design_sync.py` in the business repository
lists the differences).

## Visual direction

Clean, bright and friendly, while staying functional. Rounded corners, soft
accent gradients and short eased transitions. Screens can be dense as long
as they're organized: group related controls, give each screen one obvious
primary action, and make the result of every action predictable from how
it looks (destructive actions are red, live in overflow menus and confirm
what will be lost).

## Tokens

| Token | Use |
|---|---|
| `BjSpace.xs/sm/md/lg/xl/xxl` (4/8/12/16/24/32) | All padding and gaps |
| `BjRadius.sm/md/lg/xl/pill` (8/12/16/24/999) | Inputs `md`, cards `lg`, dialogs and hero cards `xl`, buttons and chips `pill` |
| `BjMotion.fast/medium/slow` + `BjMotion.curve` | Animated containers, switchers, sizes |
| `BjBreakpoint.medium/expanded`, `formWidth`, `pageWidth` | Responsive layout and content max widths |
| `BjNeutral.ink/inkMuted/inkSubtle/border/canvas/surface` | Text and surfaces; never `Colors.grey[600]` |
| `BjBrand.navy/navyDeep` | The logo's navy, for brand surfaces such as a splash or sign-in header. Screens use the accent |
| `context.bj` | Accent tints (`accentSoft`, `accentWash`), gradients (`heroGradient`, `softGradient`), shadows, and `tone(BjTone.x)` status colors |
| `Theme.of(context).textTheme` | Text styles. Bricolage Grotesque in semi-condensed cuts: `BjFont.heading` (display) for headings, `BjFont.body` (text) for body and labels. The narrow width is deliberate: phones fit more per line |

Use `BjTone` (`neutral`, `accent`, `info`, `success`, `warning`, `danger`)
for any status color instead of picking a `Colors.*` value.

For colors that tell things apart without meaning good or bad (file types,
categories, chart series), use `BjCategorical`: eight hues (`violet`,
`teal`, `amber`, `blue`, `rose`, `green`, `fuchsia`, `orange`), plus
`BjCategorical.at(i)` and `BjCategorical.forKey(name)` for a stable pick.
Each reads at 4.5:1 on its own tint (`test/color_test.dart` checks).

For user-picked colors, `bjTint(color)` is the soft background and
`readableOn(color, background)` darkens the color until it's readable on
it; `bjToneOf(color)` returns both as `BjToneColors`.

## Components

| Component | Replaces |
|---|---|
| `BjPage` | `Scaffold` + `AppBar`. Soft accent canvas, header aligned with the content column |
| `BjScrollBody`, `BjContent` | Hand-padded `ListView`s that stretch edge to edge on desktop |
| `BjAdaptiveSplit` | Ad-hoc `isWide` master/detail layouts |
| `BjScrollBehavior` | Per-list `ScrollConfiguration(dragDevices: {..mouse..})` and wheel-to-sideways `Listener`s. Set once on the app's `MaterialApp`, it lets the mouse drag and wheel every horizontal scrollable (`scripts/check_design_tokens.js`) |
| `BjBackStep` | `setState` back arrows that the browser's back button skips; back closes the view held in state (`scripts/check_back_steps.js`) |
| `BjResponsiveGrid`, `BjResponsiveGrid.rows` | `IntrinsicHeight` + `Row` card grids and `isWide ? 2 : 1` column math; `.rows` keeps a `BjScrollBody` lazy |
| `BjSegmentedTabs`, `BjPinnedTabs` | Hand-styled `TabBar`s and pinned tab-header slivers |
| `BjSectionHeader` | Bold `Text` section titles |
| `BjCard` | `Card(shape: RoundedRectangleBorder(...))` recipes; hover lift and press feedback built in |
| `BjHeroCard`, `BjProgressBar` | Header gradients and summary banners; `compact: true` for long titles on phones |
| `BjListRow`, `BjOverflowMenu`, `BjMenuAction` | `ListTile` + rows of trailing `IconButton`s; `enabled: false` greys an action out instead of hiding it |
| `BjIconWell`, `BjStatusPill` | Hand-rolled icon circles and status/tag containers |
| `BjTagChip` | Selectable chips in a user-picked color |
| `BjDuePill` | Due-date pills with hand-rolled overdue checks |
| `BjDetailTable`, `BjKeyValue` | Hand-aligned label/value `Row`s in detail dialogs |
| `BjInlineNote` | Muted "nothing here yet" lines and inline hints in forms and cards |
| `BjStatTile` | KPI cards |
| `BjRankBadge` | Hand-built leaderboard rank badges (trophies for the top three) |
| `BjFilterBar`, `BjFilterGroup` | Search fields + chip rows; `groups:` for several labelled chip rows |
| `BjFormSection` | Unstructured column of form fields |
| `BjFieldLabel` | Bold `Text` headings over chip groups and pickers in forms |
| `BjDateField` | Hand-built "Pick date / Clear" rows around `showDatePicker` |
| `BjOptionCards`, `BjOptionCard` | Radio buttons whose options need explaining |
| `BjBusyButton` | Submit buttons with a hand-swapped spinner |
| `BjSheetActions` | The Cancel + primary `Row` at the foot of each form sheet |
| `BjProgressFab` | Extended FABs with a hand-built progress ring |
| `BjStateView.empty/.error/.locked` | `Center(Text('No … yet'))`, `Text('Error: $e')` |
| `BjSkeleton`, `BjSkeletonList` | Bare `CircularProgressIndicator` on first load |
| `BjSnapshotView` | `if (!snapshot.hasData) spinner` (which spins forever on errors) |
| `showBjConfirm(destructive: true, consequences: [...])` | `AlertDialog` with a red `TextButton` |
| `BjSnack.success/error/info` | `ScaffoldMessenger…showSnackBar(SnackBar(content: Text(...)))` |
| `showBjSheet` | Hand-built bottom sheets |
| `BjAccentPicker`, `BjColorChooser` | Color pickers; only ever report accessible colors |

`test/showcase/gallery.dart` is a full sample screen built from these.

## Games

A game's lobby, menus, leaderboards and settings are ordinary screens:
build them with `BjPage` and the components above. The play screen keeps
the game's own look (a dark chess room, a felt table, a neon arcade). Wrap
it in `BjGameTheme(palette: BjGamePalette(background: ...))`, which
re-derives every theme color from the game's background, so default text,
icons, app bars, dialogs, sheets, inputs, chips and buttons read on it,
dark or light. Fixed game colors (board squares, card suits) take
`// design-ok: fixed game colour`.

## Accent colors

`BjAccent(primary:, secondary:)` drives the theme. `secondary` defaults to
a hue shift of the primary. Any color passed in is forced accessible with
`nearestAccessibleShade`, so a stored value can never make text unreadable.

An accent is accessible when it reaches 4.5:1 contrast (WCAG AA) against
white and the canvas, which also means white text on it is readable.
`BjSwatches.all` is the curated set; `test/accent_test.dart` fails if any
swatch drops below the bar.

## Screenshots

```sh
BJ_DESIGN_SCREENSHOTS=1 flutter test test/showcase_test.dart --update-goldens
```

writes the gallery at phone and desktop sizes, in three accents, to
`test/showcase/out/` using the real bundled fonts. Drop shadows render
without blur in tests; they're soft on devices.

Screenshot tests load the real fonts with `loadBjFonts(fontsDir)` from
`package:bluejay_design/testing.dart`, which reads the file list from
`BjFont.files`.

## Keeping apps on the system

`scripts/check_design_tokens.js` runs in CI over every app and the
launcher's `lib/`. It flags raw `Colors.*`, `Color(0x...)` literals,
`TextStyle(fontSize: ...)` and `*_theme.dart` files. Code that predates
the design system is recorded in `scripts/check_design_tokens_baseline.json`,
and no file may go above its recorded count. A justified use (a colour the
user picked, a fixed game colour) takes `// design-ok: <reason>`. To migrate
an app, use the `polish-app-ui` skill.
