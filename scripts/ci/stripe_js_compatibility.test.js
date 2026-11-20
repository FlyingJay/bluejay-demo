'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const PACKAGE = path.join(ROOT, 'third_party', 'stripe_js');

test('stripe_js compatibility package moves the Stripe JS name to the extension type', () => {
  const pubspec = fs.readFileSync(path.join(ROOT, 'pubspec.yaml'), 'utf8');
  const packagePubspec = fs.readFileSync(path.join(PACKAGE, 'pubspec.yaml'), 'utf8');
  const stripe = fs.readFileSync(path.join(PACKAGE, 'lib', 'src', 'js', 'stripe.dart'), 'utf8');

  assert.match(pubspec, /stripe_js:\s*\n\s+path:\s+third_party\/stripe_js/);
  assert.match(packagePubspec, /^version:\s*7\.5\.0$/m);
  assert.match(stripe, /^@JS\("Stripe"\)\nextension type Stripe\.__\(JSObject o\) \{/m);
  assert.match(stripe, /^\s+external Stripe\._\(/m);
  assert.doesNotMatch(stripe, /@JS\("Stripe"\)\s+external Stripe\._\(/);
});
