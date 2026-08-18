#!/usr/bin/env node
/**
 * The half of a release that happens after the bytes have gone up.
 *
 *   node scripts/ios/testflight.mjs 2608132126
 *   node scripts/ios/testflight.mjs            # newest build, whatever it is
 *
 * `release.sh` stops at "uploaded", which is not the same as "testable". Four
 * things still have to happen, none of which altool does and all of which used
 * to be clicks:
 *
 *   1. wait for Apple to finish processing, which can end in INVALID
 *   2. answer export compliance for this build
 *   3. tell the tester what changed
 *   4. attach the build to a tester group
 *
 * ## Step 3 is not paperwork
 *
 * Builds 1, 2 and 3 all went up with no "What to Test" text at all — the
 * `betaBuildLocalizations` list for each of them is empty, which is the API's
 * way of saying the notes field in TestFlight was blank. The consequence was
 * measured rather than imagined: the tester installed build 3, saw a screen he
 * could not tell apart from build 2, and reasonably concluded that nothing had
 * shipped. A build with no notes is a build nobody can verify, so this step
 * fails the run rather than skipping quietly when the notes are missing.
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
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const APP_ID = process.env.TD_ASC_APP_ID || '6801251458';

// What the tester is told this build contains. A file in the repository rather
// than a flag, because the notes are written while the change is fresh and are
// then part of the same commit as the change — a paragraph typed at upload time
// is written by whoever is holding the terminal, from memory, at the end of a
// long day, which is how "bug fixes and improvements" gets written.
//
// 4000 characters is App Store Connect's own ceiling on the field.
const NOTES_PATH = process.env.TD_TESTFLIGHT_NOTES
  || resolve(dirname(fileURLToPath(import.meta.url)), '../../ios/WhatToTest.md');
const NOTES_LIMIT = 4000;

// The locale of the app's primary language, which is `en-GB` and not the
// `en-US` everything defaults to — read off the app record rather than assumed:
//
//   GET /v1/apps/6801251458?fields[apps]=primaryLocale  →  "en-GB"
//
// Notes are per-locale, and a localization in a locale the app does not have is
// accepted by the API, stored, and shown to nobody.
const NOTES_LOCALE = process.env.TD_TESTFLIGHT_LOCALE || 'en-GB';

// The internal group whose only member is the developer. Internal groups need
// no Beta App Review, which is why a build reaches a phone minutes after upload
// rather than a day after it.
const GROUP_ID = process.env.TD_TESTFLIGHT_GROUP || '3af9828a-ff5b-46b7-bcb6-07a437c8817d';

const KEY_ID = process.env.ASC_KEY_ID || '999LNRXQS2';
const KEY_PATH = process.env.ASC_KEY_PATH || `${homedir()}/private_keys/AuthKey_${KEY_ID}.p8`;
/*
 * The issuer id, from the environment or from the file beside the key.
 *
 * The file fallback is not a convenience, it is the fix for a real stall. The
 * shell half of this flow — `asc_issuer_id()` in common.sh — has always read
 * `issuer_id.txt` from the key's own directory when the variable is unset, so
 * `release.sh` archived, validated and uploaded a build without being told
 * anything. Then this script, which is the step that makes an uploaded build
 * actually reach a phone, refused on the very next command because it looked
 * only at the environment. Two halves of one flow disagreeing about where a
 * value lives, and the half that stops is the half after the bytes have gone up.
 *
 * So it reads the same file, in the same place, by the same rule.
 */
function issuerFromDisk() {
  const file = process.env.ASC_ISSUER_ID_FILE || `${dirname(KEY_PATH)}/issuer_id.txt`;
  try {
    return readFileSync(file, 'utf8').trim();
  } catch {
    return '';
  }
}

const ISSUER = (process.env.ASC_ISSUER_ID || issuerFromDisk()).trim();

if (!ISSUER) {
  console.error('error: ASC_ISSUER_ID is not set, and there is no issuer_id.txt beside the key.');
  console.error('See scripts/ios/common.sh for where to read it off the page, then either:');
  console.error('  export ASC_ISSUER_ID=<the-uuid>');
  console.error(`  echo '<the-uuid>' > ${dirname(KEY_PATH)}/issuer_id.txt && chmod 600 $_`);
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

// `sort=-uploadedDate`, and the sort is load-bearing rather than tidy.
//
// This read `/v1/apps/{id}/builds` with no sort and took `data[0]` as "the
// newest", which is an assumption the API does not honour. Measured on this app
// the moment there were four builds: unsorted, the first row was a build from
// two days earlier and the one uploaded ten minutes ago was second. So the
// no-argument form was answering about the wrong build — waiting on a build
// that had finished processing days ago, reporting it VALID, and attaching it
// to the tester group in place of the one just uploaded.
//
// Sorting needs the top-level `/v1/builds` with `filter[app]`; the relationship
// path does not take it.
const BUILDS = `/v1/builds?filter[app]=${APP_ID}&sort=-uploadedDate&limit=20`
  + '&fields[builds]=version,processingState,uploadedDate,usesNonExemptEncryption';

while (Date.now() < DEADLINE) {
  const list = await asc('GET', BUILDS);
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

// ------------------------------------------------------ 3. what to test

/**
 * The notes, read off disk and trimmed to what App Store Connect will store.
 *
 * Markdown headings and bullets are left exactly as written. TestFlight renders
 * the field as plain text, so `-` stays a dash and `##` stays two hashes — which
 * is why `ios/WhatToTest.md` is written to read correctly with no renderer at
 * all rather than being prose that only looks right once formatted.
 */
function readNotes() {
  let text;
  try {
    text = readFileSync(NOTES_PATH, 'utf8').trim();
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    console.error(`\nerror: no "What to Test" notes at ${NOTES_PATH}`);
    console.error('A build with an empty notes field is one nobody can verify — see the header');
    console.error('of this file. Write what changed, then re-run; nothing has to be re-uploaded.');
    process.exit(1);
  }
  if (!text) {
    console.error(`\nerror: ${NOTES_PATH} is empty.`);
    process.exit(1);
  }
  if (text.length > NOTES_LIMIT) {
    console.error(`\nerror: the notes are ${text.length} characters; App Store Connect stores ${NOTES_LIMIT}.`);
    console.error('Truncating them here would cut a sentence in half on somebody\'s phone, so it does not.');
    process.exit(1);
  }
  return text;
}

const whatsNew = readNotes();

// A localization is created once per build per locale and updated afterwards.
// POSTing a second time answers 409, so the existing one is looked for first —
// which also makes re-running this script after a failure safe.
const localizations = await asc('GET', `/v1/builds/${build.id}/betaBuildLocalizations?fields[betaBuildLocalizations]=locale`);
const mine = localizations.data.find((l) => l.attributes.locale === NOTES_LOCALE);

if (mine) {
  await asc('PATCH', `/v1/betaBuildLocalizations/${mine.id}`, {
    data: { type: 'betaBuildLocalizations', id: mine.id, attributes: { whatsNew } },
  });
} else {
  await asc('POST', '/v1/betaBuildLocalizations', {
    data: {
      type: 'betaBuildLocalizations',
      attributes: { locale: NOTES_LOCALE, whatsNew },
      relationships: { build: { data: { type: 'builds', id: build.id } } },
    },
  });
}
console.log(`  ✓ what to test — ${whatsNew.length} characters (${NOTES_LOCALE})`);

// ------------------------------------------------------ 4. attach to group

// POST to the relationship rather than PATCH: adding a build to a group is
// appending to a set, and PATCH here would replace every build the group
// already has.
await asc('POST', `/v1/betaGroups/${GROUP_ID}/relationships/builds`, {
  data: [{ type: 'builds', id: build.id }],
});

const group = await asc('GET', `/v1/betaGroups/${GROUP_ID}?fields[betaGroups]=name,isInternalGroup`);
console.log(`  ✓ attached to "${group.data.attributes.name}"`);
console.log(`\nTerminal Deck ${build.attributes.version} is testable now.`);
