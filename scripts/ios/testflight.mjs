#!/usr/bin/env node
/**
 * The half of a release that happens after the bytes have gone up.
 *
 *   node scripts/ios/testflight.mjs 2608132126
 *   node scripts/ios/testflight.mjs            # newest build, whatever it is
 *
 * `release.sh` stops at "uploaded", which is not the same as "testable". Three
 * things still have to happen, none of which altool does and all of which used
 * to be clicks:
 *
 *   1. wait for Apple to finish processing, which can end in INVALID
 *   2. answer export compliance for this build
 *   3. attach the build to a tester group
 *
 * ## Why waiting is a step and not a courtesy
 *
 * `UPLOAD SUCCEEDED` means Apple accepted the file. It says nothing about
 * whether the build works as a build — processing re-checks entitlements, icon
 * sizes, bitcode, the plist, and it can come back INVALID minutes later with an
 * email as the only notification. A release that reports success at upload is
 * reporting that a file transfer completed. So this polls until the state is
 * terminal and exits non-zero on INVALID.
 *
 * ## Export compliance, and the trap
 *
 * `ITSAppUsesNonExemptEncryption` is deliberately absent from Info.plist —
 * putting it there is what makes altool demand a compliance code that does not
 * exist (error 90592). See `preflight.sh` and README. The consequence is that
 * every build arrives with the question unanswered, and an unanswered build
 * cannot be distributed to testers. Setting `usesNonExemptEncryption: false`
 * here is the same answer the App Store Connect questionnaire already carries
 * for this app: standard primitives only, which are exempt.
 *
 * ## Credentials
 *
 * The same three as everything else, from the environment, never written down:
 * ASC_ISSUER_ID (required), ASC_KEY_ID, ASC_KEY_PATH.
 */

import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const APP_ID = process.env.TD_ASC_APP_ID || '6801251458';

// The internal group whose only member is the developer. Internal groups need
// no Beta App Review, which is why a build reaches a phone minutes after upload
// rather than a day after it.
const GROUP_ID = process.env.TD_TESTFLIGHT_GROUP || '3af9828a-ff5b-46b7-bcb6-07a437c8817d';

const KEY_ID = process.env.ASC_KEY_ID || '999LNRXQS2';
const KEY_PATH = process.env.ASC_KEY_PATH || `${homedir()}/private_keys/AuthKey_${KEY_ID}.p8`;
const ISSUER = process.env.ASC_ISSUER_ID || '';

if (!ISSUER) {
  console.error('error: ASC_ISSUER_ID is not set. See scripts/ios/common.sh for where to read it off the page.');
  process.exit(1);
}

const b64url = (b) => Buffer.from(b).toString('base64')
  .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');

/**
 * ES256, signed by hand. Apple's JWT is ten lines of crypto and the alternative
 * is a dependency in a repo that has none for this.
 *
 * The fiddly part is the signature encoding: node emits ASN.1 DER, JOSE wants
 * the raw r‖s pair, 32 bytes each, and DER both strips leading zeros and adds
 * a padding byte when the high bit is set — so neither half can be copied at a
 * fixed offset or assumed to be 32 bytes long.
 */
function token() {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const body = b64url(JSON.stringify({
    iss: ISSUER, iat: now, exp: now + 900, aud: 'appstoreconnect-v1',
  }));
  const signer = createSign('SHA256');
  signer.update(`${head}.${body}`);
  const der = signer.sign(readFileSync(KEY_PATH));

  let i = der[1] & 0x80 ? 2 + (der[1] & 0x7f) : 2;
  const rLen = der[i + 1];
  const r = der.subarray(i + 2, i + 2 + rLen);
  const sLen = der[i + 2 + rLen + 1];
  const s = der.subarray(i + 2 + rLen + 2, i + 2 + rLen + 2 + sLen);
  const to32 = (x) => {
    const t = x.length > 32 ? x.subarray(x.length - 32) : x;
    return Buffer.concat([Buffer.alloc(32 - t.length), t]);
  };
  return `${head}.${body}.${b64url(Buffer.concat([to32(r), to32(s)]))}`;
}

async function asc(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const detail = json?.errors?.map((e) => `${e.title}: ${e.detail}`).join('\n  ') || text;
    throw new Error(`${method} ${path} → HTTP ${res.status}\n  ${detail}`);
  }
  return json;
}

const wanted = process.argv[2];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------------ 1. wait

// Apple's own guidance is 5–15 minutes; the ceiling here is 30 because the
// failure mode of giving up too early is a human going to look at a dashboard,
// which is the thing this script exists to avoid.
const DEADLINE = Date.now() + 30 * 60 * 1000;
let build = null;

process.stdout.write(wanted ? `Waiting for build ${wanted}` : 'Waiting for the newest build');

while (Date.now() < DEADLINE) {
  const list = await asc('GET', `/v1/apps/${APP_ID}/builds?limit=20&fields[builds]=version,processingState,uploadedDate,usesNonExemptEncryption`);
  const found = wanted
    ? list.data.find((b) => b.attributes.version === wanted)
    : list.data[0];

  if (found) {
    build = found;
    const state = found.attributes.processingState;
    if (state !== 'PROCESSING') break;
  }
  process.stdout.write('.');
  await sleep(20000);
}
process.stdout.write('\n');

if (!build) {
  console.error(`error: no build ${wanted ?? ''} appeared within 30 minutes.`);
  console.error('An upload can take a few minutes just to become visible; if altool said');
  console.error('UPLOAD SUCCEEDED, re-run this script rather than re-uploading.');
  process.exit(1);
}

const state = build.attributes.processingState;
console.log(`build ${build.attributes.version} — ${state}`);
console.log(`  id       ${build.id}`);
console.log(`  uploaded ${build.attributes.uploadedDate}`);

if (state !== 'VALID') {
  console.error(`\nerror: processing ended in ${state}, not VALID. Nothing was attached.`);
  console.error('The reason arrives by email and appears in App Store Connect > TestFlight.');
  process.exit(1);
}

// -------------------------------------------------- 2. export compliance

if (build.attributes.usesNonExemptEncryption === null) {
  await asc('PATCH', `/v1/builds/${build.id}`, {
    data: { type: 'builds', id: build.id, attributes: { usesNonExemptEncryption: false } },
  });
  console.log('  ✓ export compliance answered (usesNonExemptEncryption = false)');
} else {
  console.log(`  ✓ export compliance already answered (${build.attributes.usesNonExemptEncryption})`);
}

// ------------------------------------------------------ 3. attach to group

// POST to the relationship rather than PATCH: adding a build to a group is
// appending to a set, and PATCH here would replace every build the group
// already has.
await asc('POST', `/v1/betaGroups/${GROUP_ID}/relationships/builds`, {
  data: [{ type: 'builds', id: build.id }],
});

const group = await asc('GET', `/v1/betaGroups/${GROUP_ID}?fields[betaGroups]=name,isInternalGroup`);
console.log(`  ✓ attached to "${group.data.attributes.name}"`);
console.log(`\nTerminal Deck ${build.attributes.version} is testable now.`);
