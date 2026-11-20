---
name: polish-app-ui
description: Migrate one or more bluejay apps onto the shared bluejay_design system (packages/bluejay_design) — audit the app's hard-coded styling and missing states, extract presentational widgets, rebuild the screens with Bj* components and tokens, delete the app's *_theme.dart, add widget tests and an opt-in screenshot test, render at phone and desktop widths and iterate — with Firestore reads/writes, permissions and features unchanged. Batches several apps into one PR by default. Use when the user says things like "polish the UI of X", "migrate X to the design system", "make X look professional", "redesign X", "move these apps onto bluejay_design", or "clean up the styling in X, Y and Z". For changes to bluejay_design itself, edit that package directly in a run that is explicitly about the system; this skill only consumes it.
---

# Polish an App's UI onto bluejay_design

Moves apps from hand-rolled styling (a per-app `*_theme.dart`, raw `Colors.*`, `TextStyle(fontSize: ...)` literals, bare spinners) onto `packages/bluejay_design`. Three pilots set the pattern; read their migration commits before the first app of a run:

| App | Package | What to copy from it |
|---|---|---|
| Storage | `packages/storage` | Splitting a 1,300-line screen into `src/models.dart`, `src/format.dart` and `src/widgets/*`; a `FileRowActions` callback bundle so rows test without Firebase; delete confirm that names what recipients lose |
| Lists | `packages/task_list` | `BjSnapshotView` on every stream, per-filter empty states, `showBjSheet` editors, a stored user colour kept as an int and chosen with `BjColorChooser` |
| Projects | `packages/projects` | One status → `BjTone` map (`project_styles.dart`), all presentational widgets in one file (`project_widgets.dart`), stateful `DashboardHarness`/`DetailHarness` fixtures driving the screenshot test |

`git log --oneline -- packages/storage packages/task_list packages/projects` finds the commits; their bodies are good PR-body templates.

The user's visual direction: clean, bright and cute while staying functional. Rounded corners, soft gradients, smooth transitions. Dense screens are welcome when they're well organised, so the result of each action is clear from the design and what users expect.

## Inputs

- **Apps** (required): one or more app names or package directories. Resolve fuzzy names through `documentation/feature_doc_mapping.json` (`watch` paths give the package). Several apps is the normal case.
- **Scope note** (optional): screens to leave alone, or UX changes the user already asked for.

## Steps

### 1. Read the design system

Read `packages/bluejay_design/README.md` (tokens, the component-for-pattern table, accent rules) and skim `packages/bluejay_design/test/showcase/gallery.dart`, a full screen built only from components. Every replacement below comes from that table.

Rewrite the text the screens show (buttons, empty states, errors, destructive confirms, snack bars) to the brand guide's voice and its "Writing in the product" section (CLAUDE.md, "Brand and design").

### 2. Plan the batch

Group the apps into **as few PRs as possible**: CI costs about 100 billable minutes per ready PR (CLAUDE.md, "Draft PRs, local checks and PR size"). Default to one PR for the whole request; split only when the batch would exceed roughly eight apps or 6,000 changed lines, or when one app is regulated (`securityTier` `regulated` in its `bluejay_app.json` or `SECURITY_TIERS.md`) and deserves its own review.

For two or more apps, fan out: one agent per app, each in its own worktree on its own branch off the same base (`git worktree add /private/tmp/wt-polish-<app> -b claude/polish-<app> origin/main`), each running steps 3 to 10 for its app only and committing without pushing. Run them in the background and in parallel. Tell each agent which other packages are in flight so it stays inside its own `packages/<app>/`. When they finish, create the batch branch (`claude/polish-ui-<short-name>`), merge each app branch into it locally, resolve conflicts (usually only the root `pubspec.lock`), run step 11 once on the merged result, and push once. Remove the per-app worktrees afterwards. Never use `git stash` in these worktrees: the stash is shared across them.

### 3. Audit the app

Before editing, list what the app has, by file and line, so the PR can say what changed:

```bash
P=packages/<app>/lib
grep -rn "Colors\.\|Color(0x" $P | grep -vE "Colors\.(white|black|transparent)\b"
grep -rn "TextStyle(" $P | grep fontSize
find $P -name "*_theme.dart"
grep -rn "CircularProgressIndicator\|LinearProgressIndicator" $P   # bare spinners
grep -rn "hasError\|snapshot.error" $P                              # error states (often missing)
grep -rn "AlertDialog\|showDialog" $P                               # confirms to rebuild
grep -rn "showSnackBar" $P
grep -rn "LayoutBuilder\|MediaQuery" $P                             # any wide layout at all
```

Also read each screen and note: streams that spin forever on error; empty lists with no message or a bare `Text('No items')`; rows with three or more trailing `IconButton`s; destructive actions that delete without saying what is lost; screens that stretch edge to edge at 1280 px; screens with two or more competing filled buttons.

`node scripts/check_design_tokens.js --list <app>` lists every hard-coded colour, font size and theme file in the app, ignoring the baseline. That list is the migration's to-do: a migrated app ends at zero findings.

### 4. Extract presentational widgets

Move UI out of the `State` classes that own Firestore streams and services into plain widgets that take data and callbacks: models in, `onX` callbacks out, no `FirebaseFirestore`, `ScopedCollection` or `FirebaseAuth` inside. A small callback bundle (Storage's `FileRowActions`) keeps constructors readable. The screen keeps the streams and wires them to these widgets. This split is what makes step 8 possible; skip it and the screen can't be tested or rendered with fake data.

Put them in `lib/src/widgets/` or one `lib/<app>_widgets.dart`, whichever matches the app's size.

### 5. Rebuild with the components

Add the dependency to `packages/<app>/pubspec.yaml`:

```yaml
  bluejay_design:
    path: ../bluejay_design
```

Then replace pattern by pattern, using the README's table:

- `Scaffold` + `AppBar` → `BjPage`; hand-padded `ListView` → `BjScrollBody`/`BjContent` (content capped at `BjBreakpoint.pageWidth`, forms at `formWidth`).
- Ad hoc `isWide` checks → `BjAdaptiveSplit`, or a two-column grid above `BjBreakpoint.expanded`. Every screen needs a deliberate layout at 1280 px.
- `Card(shape: ...)` → `BjCard`; gradient headers and summaries → `BjHeroCard` + `BjProgressBar`; KPI boxes → `BjStatTile`.
- `ListTile` + trailing icon buttons → `BjListRow` with one `BjOverflowMenu`. Order menu actions by frequency, destructive last and red (`BjMenuAction(destructive: true)`).
- Coloured status containers → `BjStatusPill`; icon circles → `BjIconWell`.
- Search field + chips → `BjFilterBar`; loose form columns → `BjFormSection`; hand-built bottom sheets → `showBjSheet`.
- `if (!snapshot.hasData) spinner` → `BjSnapshotView` (skeleton on first load, error with retry, then data). First loads show `BjSkeleton`/`BjSkeletonList`.
- Empty and error text → `BjStateView.empty/.error/.locked` with a title that says what's missing and a message that says what to do next.
- `AlertDialog` confirms → `showBjConfirm(destructive: true, consequences: [...])`, listing concrete losses ("Shared recipients lose access", "The public link stops working").
- `showSnackBar(SnackBar(...))` → `BjSnack.success/error/info`.
- Spacing literals → `BjSpace`; radii → `BjRadius`; animation durations → `BjMotion`.
- Text → `Theme.of(context).textTheme.<style>`, with `.copyWith()` for weight or colour. Colours → `BjNeutral.*` for ink, borders and surfaces, `context.bj` for accent tints and gradients.
- Colour pickers → `BjAccentPicker`/`BjColorChooser`.

### 6. Centralise status → tone

Every enum or string status the app colours gets one map onto `BjTone` (plus label and icon) in one file, as `packages/projects/lib/project_styles.dart` does, and every screen reads it. Never pick a `Colors.*` per call site for a status.

### 7. Replace the app's theme file

Once nothing imports `lib/<app>_theme.dart`, delete it. `node scripts/check_design_tokens.js --list <app>` reports any `*_theme.dart` left behind, so a migration isn't done while one remains.

Colours that are data stay as they are: a colour the user picked and the app stores (a tag, a calendar), or a fixed brand or game colour (a chess board, a card suit). Mark each one with `// design-ok: <reason>` on the line or the line above, and keep the stored format unchanged.

### 8. Keep behaviour identical

The migration changes how the app looks. Firestore and Storage reads and writes, query shapes, collection and field names, callables, permission checks, navigation, routes, and every feature stay exactly as they were. Diff each service file and every `ScopedCollection` call before and after; there should be no change beyond moved code.

Small UX changes that fall out of the components are fine (actions moved into an overflow menu, a confirm that now lists consequences, a retry on error). List every one under "Deliberate UX changes" in the PR body so the reviewer can veto it.

### 9. Add tests

- **Widget tests** (`test/widgets_test.dart` or `test/<app>_widgets_test.dart`) pump the presentational widgets inside `MaterialApp(theme: BluejayTheme.build())` with fake data from `test/support/fixtures.dart`. Cover: each status renders its label and tone; the empty, error and loading states; overflow menu actions call the right callback; destructive actions go through the confirm.
- **Screenshot test** (`test/screenshots_test.dart`): copy `packages/projects/test/screenshots_test.dart`. It loads the bundled fonts, renders each screen at phone (390 px) and desktop (1280 px) width with fixtures, and is skipped unless `BJ_DESIGN_SCREENSHOTS=1`, since pixels depend on the host's font rendering. Add `test/screenshots/out/` to `packages/<app>/.gitignore`. Cover the main screens plus their empty, loading and locked states and any sheet or dialog that carries a form.

### 10. Render, look, iterate

```bash
cd packages/<app>
BJ_DESIGN_SCREENSHOTS=1 /Users/jasonrivers/flutter/bin/flutter test test/screenshots_test.dart --update-goldens
```

Open every PNG in `test/screenshots/out/` with the Read tool and review it against the checklist below. Fix what fails and render again. Expect two or three rounds. Drop shadows render without blur in tests; that's expected.

### 11. Verify

```bash
node scripts/check_design_tokens.js --list <app>...   # must print 0 findings per migrated app
node scripts/check_gateways.js                        # test fixtures too: no hard-coded cloudfunctions.net URLs
node scripts/check_design_tokens.js --update-baseline # lock the removed findings into the baseline
bash scripts/ci/local_check.sh
```

The design-token check is a ratchet over the whole repo: `scripts/check_design_tokens_baseline.json` records the findings each file had when the check was introduced. A file may never gain findings, and once a migration removes some, the check fails until `--update-baseline` records the lower counts. The update only lowers counts, so commit the shrunken baseline with the migration.

`local_check.sh` analyzes and tests every changed package and runs the Node suite (which includes the design-token check). Everything must pass before the PR leaves draft.

### 12. Open the PR

One branch for the batch (`claude/polish-ui-<short-name>`) off `origin/main`. Open it as a draft (`gh pr create --draft`), run step 11 on the final tree, then `gh pr ready <n>`. Push as few times as you can after that. The body covers, per app:

- What was rebuilt, with the components used.
- **Deliberate UX changes**, one bullet each, or "none".
- That Firestore reads/writes, permissions and features are unchanged, and how you checked (step 8).
- Tests added, and which screenshots you reviewed. Attach two or three PNGs per app where the PR tool allows it.
- Missing shared components (below).
- The release note, per CLAUDE.md and `CHANGE_REQUEST_SCOPE.md`. A visual redesign is something users notice:
  `**Release note:** Storage, Lists and Projects have a cleaner, brighter look, with clearer empty states and safer deletes.`
  `**Release apps:** storage, lists, projects`

## Design checklist

Review each screenshot against every item:

- **Hierarchy**: the screen's purpose reads in one glance; one title, section headers via `BjSectionHeader`, secondary text in `bodySmall`/`inkMuted`.
- **One primary action per screen**: a single filled button or FAB; everything else is tonal, text or in a menu.
- **Density**: dense is fine when grouped. Related controls sit together in a card or section; spacing comes from `BjSpace`, with larger gaps between groups than within them.
- **Alignment**: the header lines up with the content column; content is capped at `pageWidth`/`formWidth` on desktop; no ragged left edges.
- **Contrast**: body text is `BjNeutral.ink`/`inkMuted` on surface or canvas; text on accent fills is white; user-picked colours go through the accessible-colour helpers.
- **Touch targets**: at least 44 px for anything tappable on the 390 px render.
- **States**: loading shows a skeleton shaped like the content; errors say what failed and offer retry; empty states say what goes here and how to add the first one.
- **Microcopy**: sentence case, plain verbs on buttons ("Upload file", "Delete list"), no "Error: $e" dumps.
- **Destructive actions**: red, last in their menu, behind `showBjConfirm` that lists consequences in concrete terms.
- **Status**: every status colour comes from the app's `BjTone` map.
- **Motion**: state changes animate with `BjMotion` durations; nothing snaps or bounces.
- **Wide layout**: at 1280 px the screen uses the space (split, grid or side column) without stretching rows edge to edge.

## Missing shared components

If an app needs something bluejay_design lacks (a categorical palette, a timeline, a calendar cell), build it locally in the app's widgets file from existing tokens, and list it under "Missing shared components" in the PR body with the pilot or app that would also use it. Edit `packages/bluejay_design` only when the run is explicitly about the design system, so component changes get their own review and every adopted app is re-rendered against them.

## Constraints

- Behaviour stays identical: no change to data access, permissions, routes or features. Any UX change is listed in the PR.
- Stay inside the listed apps' packages, plus the root `pubspec.lock` if pub get changes it.
- Never add `// design-ok` to silence a finding that has a token; it's for stored user colours and fixed brand or game colours, with a reason a reviewer can check.
- Several apps per PR by default; `local_check.sh` passes before `gh pr ready`.
- Never merge the PR yourself unless the user has said so for this run.
