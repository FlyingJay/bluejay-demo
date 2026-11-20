'use strict';

// Path filters that keep workflows from starting on pushes that can't affect
// them. Each one mirrors what a script actually reads, so these tests fail if
// the script's inputs and the workflow's trigger drift apart.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const {
  DEPLOY_TARGETS, DEPLOY_WORKFLOW_NAME, FOLDED_JOB, FOLDED_STEP_PREFIX, deployTarget,
} = require('../../functions/_deploy_targets');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

/** The `- '<glob>'` entries under `<key>:` in the first block that has one. */
function listUnder(text, key) {
  const block = text.match(new RegExp(`${key}:\\s*\\n((?:\\s+#.*\\n)*(?:\\s+- .+\\n)+)`));
  assert.ok(block, `${key}: list not found`);
  return block[1].split('\n')
    .filter((l) => /^\s+- /.test(l))
    .map((l) => l.replace(/^\s+- /, '').replace(/['"]/g, '').trim());
}

test('the docs_pending train target skips documentation/-only changes except the processed file; no feature watches documentation/', () => {
  // Patterns apply in order: everything, minus documentation/, plus the
  // nightly docs PR's processed-state file, which agentic-docs-on-main.yml
  // must reconcile (reconcilePendingState) when that PR merges.
  assert.deepEqual([...deployTarget('docs_pending').paths],
    ['**', '!documentation/**', 'documentation/.docs_batch_processed.json']);
  assert.match(read('scripts/docs/nightly_docs_batch.js'), /\.docs_batch_processed\.json/);
  const mapping = JSON.parse(read('documentation/feature_doc_mapping.json'));
  for (const feature of mapping.features) {
    for (const rule of feature.watch || []) {
      assert.ok(!String(rule.path).replace(/^\.?\//, '').startsWith('documentation'),
        `${feature.name} watches ${rule.path}; the docs_pending target's paths would hide changes to it`);
    }
  }
});

test('the docs_corpus train target covers exactly what sync_docs_corpus.js uploads', () => {
  const script = read('functions/scripts/sync_docs_corpus.js');
  const names = JSON.parse(script.match(/const DOC_FILENAMES = (\[[^\]]*\]);/)[1].replace(/'/g, '"'));
  assert.match(script, /path\.join\(DOCS_ROOT, 'feature_doc_mapping\.json'\)/);
  const paths = [...deployTarget('docs_corpus').paths];
  assert.deepEqual(paths.sort(), [
    ...names.map((n) => `documentation/*/${n}`),
    'documentation/feature_doc_mapping.json',
  ].sort());
});

test('the tier audit runs for the functions files audit.js reads (top-level .js, tests included), on PRs and from the train', () => {
  // --diff extracts the base ref's security/, functions/, packages/ and
  // documentation/ whole; functions tests count (exerciseAuditedWrites).
  const audit = read('scripts/security_tier_audit/audit.js');
  assert.match(audit, /const REF_INPUT_DIRS = \['security', 'functions', 'packages', 'documentation'\];/);
  // One list decides all three: pr-checks.yml (the tier_audit suite), the
  // train's security_audit target, and local_check.sh (the same suite).
  const { SUITES, suiteAffected } = require('./suite_inputs');
  const paths = SUITES.tier_audit.inputs;
  assert.ok(paths.includes('functions/*.js'), 'functions/*.js missing');
  assert.ok(!paths.includes('functions/**'));
  assert.deepEqual(SUITES.tier_audit.except || [], [], 'functions tests are audit inputs');
  for (const p of ['security/storage_paths.json', 'security/generate_storage.js']) assert.ok(paths.includes(p), `${p} missing`);
  assert.deepEqual([...deployTarget('security_audit').paths], paths);
  assert.ok(suiteAffected('tier_audit', ['functions/mail.test.js']));
  assert.ok(!suiteAffected('tier_audit', ['functions/scripts/x.js', 'documentation/lists/user.md']));
  const checks = read('.github/workflows/pr-checks.yml');
  assert.match(checks, /suite_inputs\.js changed --base "origin\/\$\{\{ github\.base_ref \}\}" --suites tier_audit >> "\$GITHUB_OUTPUT"/);
  // Every audit step waits on that answer.
  const steps = checks.slice(checks.indexOf('- name: Install tier audit dependencies'));
  for (const step of steps.split(/\n {6}- name: /).slice(0, 4)) {
    assert.ok(step.includes("steps.plan.outputs.tier_audit == 'true'"), `"${step.split('\n')[0]}" must run only when the audit is planned`);
  }
});

test('pr-checks.yml is one job that runs all three checks, and only for events that can change a verdict', () => {
  const jobs = workflowJobs().filter((j) => j.file === 'pr-checks.yml');
  assert.deepEqual(jobs.map((j) => j.job), ['checks'], 'one job: each extra job bills at least a minute per push');
  const [job] = jobs;
  for (const step of ['Copy rules', 'Release note', 'Security tiers']) assert.match(job.text, new RegExp(`^ {6}- name: ${step}$`, 'm'));
  assert.match(job.text, /copy_lint\.js --base/);
  const cond = jobIf(job.text);
  assert.ok(cond.includes("github.event.action != 'edited' || github.event.changes.body"), 'title-only edits start no runner');
  assert.ok(cond.includes("github.event.label.name == 'security-tier-decrease-approved'"), 'only the approval label re-runs it');
  // Job-level concurrency: a run the `if:` skips must not cancel one with work to do.
  const text = read('.github/workflows/pr-checks.yml');
  assert.ok(!/^concurrency:/m.test(text), 'concurrency belongs on the job');
  assert.match(job.text, /^ {4}concurrency:\n {6}group: pr-checks-\$\{\{ github\.event\.pull_request\.number \}\}\n {6}cancel-in-progress: true/m);
  // The service account key is created after the steps that don't need it.
  assert.ok(job.text.indexOf('- name: Release note') < job.text.indexOf('- name: Create Service Account Key File'));
  // The docs auto-merge waits on it by name.
  assert.match(text, /^name: PR Checks$/m);
  assert.match(read('.github/workflows/auto-merge-docs-pr.yml'), /workflows: \['Build and Deploy', 'Tests', 'PR Checks'\]/);
  for (const gone of ['release-note-check.yml', 'copy-rules.yml', 'security-tier-audit.yml']) {
    assert.ok(!fs.existsSync(path.join(ROOT, '.github', 'workflows', gone)), `${gone} is a step of pr-checks.yml now`);
  }
});

test('auto-merge-docs-pr.yml sweeps on docs pushes but not on-main bookkeeping-only commits', () => {
  const text = read('.github/workflows/auto-merge-docs-pr.yml');
  const push = text.slice(text.indexOf('\n  push:'));
  assert.deepEqual(listUnder(push, 'paths'), [
    'documentation/**',
    '!documentation/.pending_doc_changes.json',
    '!documentation/.docs_batch_processed.json',
    'pubspec.yaml',
    'web/about/**',
    'web/index.html',
  ]);
});

test('auto-merge-docs-pr.yml starts for PRs that can be docs, advisor prose or public pages, and for docs, advisor and pages branches', () => {
  const text = read('.github/workflows/auto-merge-docs-pr.yml');
  const target = `${text.slice(text.indexOf('\n  pull_request_target:'), text.indexOf('\n  workflow_run:'))}\n`;
  // classifyFiles accepts documentation/ files and docs-asset pubspec.yaml
  // lines; the advisor prose lane is markdown. A copy-lane PR may touch only
  // code, so it starts from workflow_run on an advisor branch instead.
  assert.match(read('scripts/ci/pr_lanes.js'), /const DOCS_PREFIX = 'documentation\/';/);
  assert.match(read('scripts/ci/pr_lanes.js'), /const PROSE_FILES = \['\*\*\/\*\.md'\];/);
  assert.match(read('scripts/ci/pr_lanes.js'), /const ADVISOR_BRANCH = \/\^claude\\\/advisor-\/;/);
  assert.deepEqual(listUnder(target, 'paths'), ['documentation/**', 'pubspec.yaml', '**/*.md', 'web/about/**', 'web/index.html']);
  // Every public page file under web/ is inside one of those triggers.
  const { PAGE_FILES } = require('./pr_lanes');
  for (const glob of PAGE_FILES.filter((g) => g.startsWith('web/'))) {
    assert.ok(glob === 'web/index.html' || glob.startsWith('web/about/'), glob);
  }
  for (const prefix of ['claude/docs-', 'docs/', 'claude/advisor-', 'claude/pages-']) {
    assert.ok(text.includes(`startsWith(github.event.workflow_run.head_branch, '${prefix}')`), prefix);
  }
});

test('rules-tests.yml has no push trigger and its PR paths are the rules suite inputs', () => {
  const { SUITES } = require('./suite_inputs');
  const text = read('.github/workflows/rules-tests.yml');
  const on = text.slice(text.indexOf('\non:'), text.indexOf('\npermissions:'));
  assert.ok(!/^ {2}push:/m.test(on), 'deploy-rules.yml runs the suite on push; a push trigger runs it twice');
  assert.deepEqual(listUnder(on, 'paths'), SUITES.rules.inputs);
  // deploy-rules.yml calls it, so it must grant what the called jobs ask for.
  const deploy = read('.github/workflows/deploy-rules.yml');
  const caller = deploy.slice(deploy.indexOf('\n  rules-tests:'), deploy.indexOf('\n  deploy:'));
  assert.match(caller, /uses: \.\/\.github\/workflows\/rules-tests\.yml/);
  assert.match(caller, /permissions:\s*\n\s+contents: read\s*\n\s+actions: read/);
});

test('rules-tests.yml runs one job per matrix shard and the rules-tests job waits for all of them', () => {
  const jobs = workflowJobs().filter((j) => j.file === 'rules-tests.yml');
  const suite = jobs.find((j) => j.job === 'suite');
  const shards = Number(suite.text.match(/^ {6}RULES_MATRIX_SHARDS: (\d+)$/m)[1]);
  const list = suite.text.match(/^ {8}shard: \[([^\]]*)\]/m)[1].split(',').map((s) => Number(s.trim()));
  assert.deepEqual(list, Array.from({ length: shards }, (_, i) => i + 1), 'the shard list must be 1..RULES_MATRIX_SHARDS');
  // Every part of the suite: the matrix, the headroom test and the rest.
  for (const part of ['cost', 'other']) assert.match(suite.text, new RegExp(`^ {10}- part: ${part}\\b`, 'm'));
  const gate = jobs.find((j) => j.job === 'rules-tests');
  assert.deepEqual(jobNeeds(gate.text), ['changes', 'suite']);
  assert.match(gate.text, /RESULT: \$\{\{ needs\.suite\.result \}\}/);
});

test('the deploy train runs every target in _deploy_targets.js, as a job or a finish step, and nothing deploys on push', () => {
  const train = read('.github/workflows/deploy-production.yml');
  assert.match(train, /^name: Deploy Production$/m);
  assert.equal(DEPLOY_WORKFLOW_NAME, 'Deploy Production');
  const jobs = workflowJobs().filter((j) => j.file === 'deploy-production.yml');
  const plan = jobs.find((j) => j.job === 'plan');
  const finish = jobs.find((j) => j.job === FOLDED_JOB);
  const loop = finish.text.match(/for id in ([a-z_ ]+); do/)[1].split(' ');
  assert.deepEqual(loop, DEPLOY_TARGETS.map((t) => t.id), "finish moves every target's tag");
  const jobTargets = DEPLOY_TARGETS.filter((t) => !t.step);
  assert.deepEqual(jobNeeds(finish.text).filter((n) => n !== 'plan').sort(), jobTargets.map((t) => t.id).sort(),
    'finish waits for every target that is a job');
  // One job per called workflow plus plan and finish: every other job bills at least a minute a train.
  assert.deepEqual(jobs.map((j) => j.job).sort(), ['plan', FOLDED_JOB, ...jobTargets.map((t) => t.id)].sort());
  for (const target of DEPLOY_TARGETS) {
    assert.ok(Boolean(target.step) !== Boolean(target.workflow), `${target.id} is a finish step or a called workflow, not both`);
    assert.match(plan.text, new RegExp(`^ {6}${target.id}: \\$\\{\\{ steps\\.plan\\.outputs\\.${target.id} \\}\\}$`, 'm'));
    if (target.step) {
      // A step of finish, named so targetsRunByJobs can tell it ran, with an
      // id the tag loop reads its outcome from, and only when planned.
      const step = finish.text.split(/\n {6}- name: /).find((part) => part.startsWith(`'${FOLDED_STEP_PREFIX}${target.id}'`));
      assert.ok(step, `finish has no '${FOLDED_STEP_PREFIX}${target.id}' step`);
      assert.match(step, new RegExp(`^ {8}id: ${target.id}$`, 'm'));
      assert.match(finish.text, new RegExp(`^ {6}${target.id.toUpperCase()}: \\$\\{\\{ needs\\.plan\\.outputs\\.${target.id} \\}\\}$`, 'm'));
      assert.ok(step.includes(`env.${target.id.toUpperCase()} == 'true'`), `${target.id} runs only when planned`);
      assert.ok(step.includes('!cancelled()'), `${target.id} runs whatever the steps before it did`);
      continue;
    }
    const job = jobs.find((j) => j.job === target.id);
    assert.ok(job, `deploy-production.yml has no ${target.id} job`);
    assert.match(job.text, new RegExp(`^ {4}uses: \\./\\.github/workflows/${target.workflow.replace('.', '\\.')}$`, 'm'));
    assert.ok(jobIf(job.text).includes(`needs.plan.outputs.${target.id} == 'true'`), `${target.id} runs only when planned`);
    const text = read(`.github/workflows/${target.workflow}`);
    const on = text.slice(text.search(/^on:/m), text.search(/^(?:jobs|permissions|concurrency|env):/m));
    assert.match(on, /^ {2}workflow_call:/m, `${target.workflow} must be callable`);
    assert.ok(!/^ {2}push:/m.test(on), `${target.workflow} deploys through the train only; drop its push trigger`);
  }
  assert.deepEqual(DEPLOY_TARGETS.filter((t) => t.step).map((t) => t.id), ['security_audit', 'docs_pending']);
  // The tag loop reads a step target's outcome, and runs whatever failed before it.
  assert.match(finish.text, /STEPS: \$\{\{ toJSON\(steps\) \}\}/);
  assert.match(finish.text, /\(\.\[\$id\]\.result\) \/\/ \(\$steps\[\$id\]\.outcome\) \/\/ "skipped"/);
  assert.match(finish.text, /- name: Move the deployed tags\n {8}if: \$\{\{ always\(\) \}\}/);
  // Apps are registered after a successful web deploy, with the writes on.
  const register = finish.text.split(/\n {6}- name: /).find((part) => part.startsWith('Register apps'));
  assert.match(register, /uses: \.\/\.github\/actions\/register-apps\n {8}with:\n {10}confirm: 'true'/);
  assert.match(finish.text, /^ {6}REGISTER_APPS: \$\{\{ needs\.hosting\.result == 'success' \}\}$/m);
  // The shared steps exist, and the manual workflows use the same ones.
  for (const [action, workflow] of [['register-apps', 'register-apps.yml'], ['record-pending-docs', 'agentic-docs-on-main.yml']]) {
    assert.match(read(`.github/actions/${action}/action.yml`), /^ {2}using: composite$/m);
    assert.ok(finish.text.includes(`uses: ./.github/actions/${action}`));
    const manual = read(`.github/workflows/${workflow}`);
    assert.ok(manual.includes(`uses: ./.github/actions/${action}`));
    assert.ok(!/^ {2}(push|workflow_call):/m.test(manual), `${workflow} is for manual runs; the train runs the action itself`);
  }
  // The fallback leaves a commit to the dispatcher for as long as the dispatcher may hold it.
  const { DEFAULT_TRAIN_INTERVAL_MINUTES } = require('../../functions/_deploy_train');
  const fallbackAfter = Number(plan.text.match(/vars\.DEPLOY_FALLBACK_AFTER_MINUTES \|\| '(\d+)'/)[1]);
  assert.ok(fallbackAfter >= DEFAULT_TRAIN_INTERVAL_MINUTES + 30,
    'the fallback must wait out the batching interval plus a dispatcher tick and a train, or it deploys every merge early');
  // Nothing else ships to production on its own either.
  for (const file of ['register-apps.yml', 'app-screenshots.yml']) {
    const text = read(`.github/workflows/${file}`);
    assert.ok(!/^ {2}(push|workflow_run):/m.test(text), `${file} follows the train, not pushes or deploy runs`);
  }
  // The functions target excludes what affected_functions.js treats as non-runtime.
  const { NON_RUNTIME_GLOBS } = require('../../functions/scripts/affected_functions');
  assert.deepEqual([...deployTarget('functions').paths], ['functions/**', ...NON_RUNTIME_GLOBS.map((g) => `!functions/${g}`)]);
  assert.ok(!read('.github/workflows/deploy-firebase-backend.yml').includes('firestore:indexes'),
    'indexes deploy from deploy-firestore-indexes.yml only');
  // Hosting deploys for the same files a PR builds a preview for.
  const deploy = read('.github/workflows/deploy.yml');
  const pr = deploy.slice(deploy.indexOf('\n  pull_request:'), deploy.indexOf('\n  workflow_dispatch:'));
  assert.deepEqual([...deployTarget('hosting').paths], listUnder(pr, 'paths'));
});

test("dev-change-lifecycle.yml starts no job for the train's hourly fallback run; the reconcile records those", () => {
  const job = workflowJobs().find((j) => j.file === 'dev-change-lifecycle.yml' && j.job === 'sync');
  assert.ok(jobIf(job.text).includes("github.event.workflow_run.event != 'schedule'"));
  const script = read('functions/scripts/sync_dev_change.js');
  assert.match(script, /await recordFallbackDeployments\(\);\n {2}await evaluateAllMerged\(\);/);
  assert.match(script, /runs\?branch=\$\{DEFAULT_BRANCH\}&event=schedule&status=completed/);
});

/** { file, job, text } for every job in every workflow. */
function workflowJobs() {
  const dir = path.join(ROOT, '.github', 'workflows');
  const out = [];
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.yml'))) {
    const text = read(`.github/workflows/${file}`);
    const jobs = text.slice(text.search(/^jobs:/m));
    const parts = jobs.split(/^ {2}(?=[A-Za-z0-9_-]+:\s*$)/m).slice(1);
    for (const part of parts) out.push({ file, job: part.slice(0, part.indexOf(':')), text: part });
  }
  return out;
}

test('jobs on the HEAVY_RUNNER runner hold no secrets', () => {
  // HEAVY_RUNNER may name a self-hosted runner, which runs any PR's code;
  // nothing there may see a secret.
  const heavy = workflowJobs().filter((j) => j.text.includes('vars.HEAVY_RUNNER'));
  assert.deepEqual(heavy.map((j) => `${j.file}:${j.job}`).sort(), [
    'rules-tests.yml:suite',
    'tests.yml:flutter',
    'tests.yml:flutter_root',
    'tests.yml:node',
  ]);
  for (const j of heavy) {
    assert.ok(!/secrets\./.test(j.text), `${j.file}:${j.job} runs on HEAVY_RUNNER but uses a secret`);
    assert.match(j.text, /runs-on: \$\{\{ vars\.HEAVY_RUNNER \|\| 'ubuntu-latest' \}\}/);
  }
});

test('secret-holding jobs run on DEPLOY_RUNNER only when it names a managed Ubicloud runner', () => {
  // Deploy jobs hold the production service account and deploy tokens.
  // GitHub hands a job's secrets to the runner when the job starts, so the
  // guard has to be in runs-on itself: DEPLOY_RUNNER is used only when it
  // names an ubicloud-* label (a fresh VM per job, thrown away after), and
  // anything else, a self-hosted label included, falls back to GitHub's
  // runners. HEAVY_RUNNER stays secret-free (above), so it may still name a
  // self-hosted machine.
  const expr = "runs-on: ${{ startsWith(vars.DEPLOY_RUNNER, 'ubicloud-') && vars.DEPLOY_RUNNER || 'ubuntu-latest' }}";
  const deploy = workflowJobs().filter((j) => j.text.includes('vars.DEPLOY_RUNNER'));
  assert.deepEqual(deploy.map((j) => `${j.file}:${j.job}`).sort(), [
    'deploy-firebase-backend.yml:deploy_functions',
    'deploy-preview-sandbox.yml:deploy_sandbox',
    'deploy.yml:build_and_preview',
  ]);
  for (const j of deploy) {
    const lines = j.text.split('\n').filter((l) => l.includes('vars.DEPLOY_RUNNER'));
    assert.deepEqual(lines.map((l) => l.trim()), [expr], `${j.file}:${j.job}`);
  }
});

test('every job has a timeout', () => {
  for (const j of workflowJobs()) {
    if (/^ {4}uses:/m.test(j.text)) continue; // a reusable-workflow call; its jobs carry their own
    assert.match(j.text, /^ {4}timeout-minutes: \d+/m, `${j.file}:${j.job} has no timeout-minutes (the default is 6 hours)`);
  }
});

/** The `pull_request` / `pull_request_target` triggers of a workflow: [{ event, types }]. */
function prTriggers(text) {
  const on = text.slice(text.search(/^on:/m), text.search(/^(?:jobs|permissions|concurrency|env):/m));
  const out = [];
  for (const m of on.matchAll(/^ {2}(pull_request(?:_target)?):[^\n]*\n((?: {4,}.*\n|\s*#.*\n|\s*\n)*)/gm)) {
    const body = m[2];
    let types;
    const inline = body.match(/^ {4}types:\s*\[([^\]]*)\]/m);
    if (inline) types = inline[1].split(',').map((t) => t.trim()).filter(Boolean);
    else if (/^ {4}types:\s*$/m.test(body)) types = listUnder(body, 'types');
    else types = ['opened', 'synchronize', 'reopened']; // GitHub's default
    out.push({ event: m[1], types });
  }
  return out;
}

const DRAFT_GATE = 'github.event.pull_request.draft != true';

/** The job's `if:` (single line or folded block), or ''. */
function jobIf(jobText) {
  const m = jobText.match(/^ {4}if:\s*(>-?|\|)?\s*(.*)\n((?: {6,}.*\n)*)/m);
  return m ? `${m[2]} ${m[3]}` : '';
}

/** Job names from `needs:` (single name or inline list). */
function jobNeeds(jobText) {
  const m = jobText.match(/^ {4}needs:\s*(.+)$/m);
  if (!m) return [];
  return m[1].replace(/[[\]]/g, '').split(',').map((s) => s.trim()).filter(Boolean);
}

test('every PR-triggered workflow skips draft PRs and runs on ready_for_review', () => {
  // Draft PRs run no CI (see CLAUDE.md): each job either carries the draft
  // gate in its `if:` or only needs gated jobs (and so is skipped with them;
  // always()/!cancelled() would run it anyway), or runs only for another
  // event. Workflows that only listen
  // for `closed` (cleanup) are exempt.
  const jobs = workflowJobs();
  const dir = path.join(ROOT, '.github', 'workflows');
  const checked = [];
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.yml'))) {
    const text = read(`.github/workflows/${file}`);
    const triggers = prTriggers(text).filter((t) => !t.types.every((type) => type === 'closed'));
    if (triggers.length === 0) continue;
    checked.push(file);
    for (const t of triggers) {
      assert.ok(t.types.includes('ready_for_review'),
        `${file}: ${t.event} types must include ready_for_review, or a draft marked ready never runs it`);
    }
    const own = new Map(jobs.filter((j) => j.file === file).map((j) => [j.job, j]));
    const gated = new Map();
    const isGated = (name, seen = new Set()) => {
      if (gated.has(name)) return gated.get(name);
      const j = own.get(name);
      assert.ok(j, `${file}: needs unknown job ${name}`);
      const cond = jobIf(j.text);
      // A job only for some other event (e.g. `github.event_name == 'schedule'`).
      let ok = cond.includes(DRAFT_GATE)
        || (/^\s*github\.event_name == '(?!pull_request)[a-z_]+'\s*$/.test(cond));
      if (!ok && !/always\(\)|cancelled\(\)|failure\(\)/.test(cond)) {
        const needs = jobNeeds(j.text);
        ok = needs.length > 0 && !seen.has(name) && needs.every((n) => isGated(n, new Set([...seen, name])));
      }
      gated.set(name, ok);
      return ok;
    };
    for (const name of own.keys()) {
      assert.ok(isGated(name), `${file}:${name} starts a runner for a draft PR; add \`if: ${DRAFT_GATE}\``);
    }
  }
  // The scan found the workflows it's meant to cover.
  for (const f of ['tests.yml', 'deploy.yml', 'rules-tests.yml', 'pr-checks.yml',
    'auto-merge-docs-pr.yml', 'dev-change-lifecycle.yml']) {
    assert.ok(checked.includes(f), `${f} not recognised as a PR workflow`);
  }
  assert.ok(!checked.includes('preview-channel-cleanup.yml'), 'closed-only cleanup is exempt');
});

test('the draft check catches a PR workflow that forgets the gate', () => {
  const text = 'on:\n  pull_request:\n    paths:\n      - x\njobs:\n  a:\n    runs-on: ubuntu-latest\n';
  assert.deepEqual(prTriggers(text), [{ event: 'pull_request', types: ['opened', 'synchronize', 'reopened'] }]);
  assert.equal(jobIf('  a:\n    runs-on: x\n'), '');
  assert.ok(jobIf("  a:\n    if: >-\n      (x\n        && github.event.pull_request.draft != true)\n    runs-on: x\n").includes(DRAFT_GATE));
  assert.deepEqual(jobNeeds('  t:\n    needs: [a, b]\n'), ['a', 'b']);
});

test('app-screenshots.yml plans the apps in a cheap job, every app about every two weeks', () => {
  const jobs = workflowJobs().filter((j) => j.file === 'app-screenshots.yml');
  assert.deepEqual(jobs.map((j) => j.job), ['plan', 'screenshots']);
  const [plan, capture] = jobs;
  // The plan job installs nothing heavy and holds no secret.
  assert.ok(!/playwright|npm ci|secrets\./.test(plan.text), 'the plan job must stay cheap and secret-free');
  assert.match(plan.text, /^ {6}apps: \$\{\{ steps\.apps\.outputs\.apps \}\}/m);
  // Every event still gets its apps from the plan: dispatch and schedule as before.
  for (const event of ['workflow_dispatch)', 'schedule)']) assert.ok(plan.text.includes(event), event);
  // Apps captured only by hand (mail) stay out of every automatic event.
  assert.match(plan.text, /automaticScenedAppIds\(\)/);
  // Every automatic app from what's live, on the 1st and 15th (about every two weeks).
  const workflow = read('.github/workflows/app-screenshots.yml');
  assert.match(workflow, /^ {4}- cron: '41 9 1,15 \* \*'/m);
  assert.match(plan.text, /deployed\/hosting/);
  assert.match(plan.text, /schedule\) apps="\$auto" ;;/);
  assert.ok(!/apps="\$all"/.test(plan.text.split('schedule)')[1]), 'only workflow_dispatch may take every app');
  const { MANUAL_CAPTURE_APPS } = require('../demo/lib/config');
  assert.ok(MANUAL_CAPTURE_APPS.includes('mail'));
  // One app's failed seed leaves only that app out of its chunk's capture, and fails the job.
  assert.match(capture.text, /if node seed\.js --app "\$app" --reset \$FLAG; then seeded\+=\("\$app"\)/);
  assert.match(capture.text, /for app in \$SEEDED; do args\+=\(--app "\$app"\); done/);
  assert.match(capture.text, /if: steps\.seed\.outputs\.failed != ''\n {8}env:[\s\S]*exit 1/);
  assert.deepEqual(jobNeeds(capture.text), ['plan']);
  assert.match(jobIf(capture.text), /needs\.plan\.outputs\.apps != ''/);
  // Chunks of apps, one matrix job each and one at a time, so a run over every
  // app never meets the job time limit or the parallel sign-in quota.
  assert.match(plan.text, /^ {6}chunks: \$\{\{ steps\.apps\.outputs\.chunks \}\}/m);
  assert.match(plan.text, /changed_apps\.js --chunks/);
  assert.match(capture.text, /apps: \$\{\{ fromJSON\(needs\.plan\.outputs\.chunks\) \}\}/);
  assert.match(capture.text, /max-parallel: 1/);
  assert.match(capture.text, /APPS: \$\{\{ matrix\.apps \}\}/);
  assert.match(capture.text, /name: app-screenshots-\$\{\{ strategy\.job-index \}\}/);
  assert.match(capture.text, /playwright install/);
  const { chunkApps } = require('../app_screenshots/changed_apps');
  assert.deepEqual(chunkApps(['a', 'b', 'c', 'd', 'e'], 2), ['a b', 'c d', 'e']);
  assert.deepEqual(chunkApps([], 10), []);
  assert.throws(() => chunkApps(['a'], 0), /positive/);
});
