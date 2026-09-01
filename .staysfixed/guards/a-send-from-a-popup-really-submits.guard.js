/**
 * He pressed Send, walked over to the session, and found the message sitting
 * typed and unsent in the prompt box. Twice inside the same minute, on tape.
 */
export default {
  name: 'sending from a browser popup submits the line, rather than leaving it typed in the prompt',

  fixed: '2026-08-21',

  because:
    'His words: *"when we send from here, in the session, it should not be waiting us to come and send. If possible, it '
    + 'should also click the send. If we just send from there, it should just send instead of just sitting here and '
    + 'waiting for us to come here and then send."* The sender wrote the composed line into the session with no carriage '
    + 'return at all, while every other sender in the app writes text and then a return, so the message sat in the '
    + 'prompt box and the agent never saw a word of it. It failed twice within the same minute of the recording and made '
    + 'him believe cross-machine delivery was broken outright — his line at the top of that window is *"Coming to the '
    + 'remote session at all. See."* The fix has a trap of its own, and it is the reason this guard exists rather than a '
    + 'test: the agent CLI classifies every stdin chunk before it looks at the keys in it, and a chunk of 64 bytes or '
    + 'more is PASTED TEXT, where a carriage return is a newline and not submit. Every line these popups compose carries '
    + 'a screenshot path, so every one of them is over that. `text + "\\r"` in one write is therefore not "usually fine" '
    + 'here — it is a send button that never submits anything, 100% of the time, and it typechecks.',

  link: 'review-2026-08-21 T62; asks-audit-2026-08-28 CRO-073 and BRO-069',

  async run({ expect, page, project, cannotRunHere }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /* ─────────────────────────────────────────────────────────────────────
       Nothing here presses Send.

       A guard may not put a line into somebody's session — that is the product
       changing under the thing watching it, and on this bug the change would be
       a message to an agent that then acts on it. So the delivery is proved in
       two pieces that can both be read without sending: the doors are asked
       whether they answer, and the sequence that goes through them is read where
       it is written.
       ───────────────────────────────────────────────────────────────────── */

    await expect('all three doors a send can go through are on the bridge', async () => {
      // The most repeated defect in this product's history is a control wired to
      // a name that does not exist, and this button has three of them: this
      // computer, a paired machine, a terminal on a server. Each is
      // feature-detected in the sender rather than assumed, so a missing one is
      // a refusal sentence and not a throw — which means it is silent, and the
      // button simply never works for that row.
      const said = String(await page.evaluate(
        '(()=>{const api=window.deck||{};return JSON.stringify('
        + '["writeToSession","sendToMachineSession","writeToServerShell"]'
        + '.filter(name=>typeof api[name]!=="function"))})()',
      ));
      return said === '[]';
    });

    /**
     * A file with its comments taken out and its whitespace flattened.
     *
     * Both halves matter. Every rule below is written down in prose directly
     * above the line that implements it — his own words, and the measurement, in
     * the source — so a plain search for the rule finds the paragraph explaining
     * it and passes on a build that stopped obeying it. Three tests on this
     * project have already failed from the other direction, on their own
     * comments. Flattening the whitespace afterwards is what keeps a reformat
     * from reading as a regression.
     *
     * @param {string} rel
     */
    const code = async (rel) => {
      const raw = await fsp.readFile(path.join(project.paths.root, rel), 'utf8');
      return raw
        .replace(/\/\*[\s\S]*?\*\//g, ' ')
        .replace(/^[ \t]*\/\/.*$/gm, ' ')
        .replace(/\s+/g, ' ');
    };

    await expect('the return is its own write, arriving after a gap on the clock', async () => {
      // The whole of the trap, in one function. The chunk is the unit being
      // classified, so anything producing a single write — a longer string,
      // `\r\n`, the two concatenated — is one chunk and is read as a paste. The
      // Return only lands as a KEY when it is alone in its own read.
      const sender = await code('src/renderer/browser/agent-target.ts');
      return /const \[typed, submit\] = terminalWrites\(line\)/.test(sender)
        && /const first = await write\(typed\)/.test(sender)
        && /await wait\(SUBMIT_GAP_MS\)/.test(sender)
        && /return write\(submit\)/.test(sender);
    });

    await expect('and the second of those two writes is a bare carriage return', async () => {
      // `\r`, not `\n`: it is what the CLI's key parser reads as return. And
      // alone, because a payload with the return appended to it is the single
      // chunk the whole measurement was about.
      const mentions = await code('src/renderer/chat/attach/mentions.ts');
      return /export function terminalWrites\(message: string\): \[string, string\] \{ return \[terminalPayload\(message\), '\\r'\] \}/.test(mentions);
    });

    await expect('the gap between them is a real number of milliseconds, not zero', async () => {
      // Measured on a real pty: written back to back they are read as one chunk
      // and nothing is sent; 30ms apart submits. A gap that drifts to 0 restores
      // the defect exactly, and nothing else about the code would look different.
      const mentions = await code('src/renderer/chat/attach/mentions.ts');
      const said = /export const SUBMIT_GAP_MS = (\d+)/.exec(mentions);
      return said !== null && Number(said[1]) >= 30;
    });

    await expect('the popups\' own send goes through that sequence and not straight at a session', async () => {
      // This is the line that shipped broken: `writeToSession(now.id, line)`,
      // with no return at all. The hook that owns the button must hand its line
      // to the two-write sequence, and the single write it does keep is the one
      // INSIDE that sequence — one chunk of characters, whatever they are.
      const hook = await code('src/renderer/browser/useAgentTarget.ts');
      return /const outcome = await submitLine\(line, \(data\) => writeOne\(now, data\)\)/.test(hook)
        && /api\.writeToSession\(target\.id, data\)/.test(hook)
        && /api\.writeToSession\([a-zA-Z.]*\.id, line\)/.test(hook) === false;
    });

    await expect('and not one of the three popups types into a session behind its back', async () => {
      // Screenshot, inspect and the recorded flow all share one Send. The bug
      // came back the day one of them grew its own write, so the rule is that
      // none of them may name a session-writing channel at all — they compose,
      // and the hook delivers.
      const popups = ['ScreenshotPopup.tsx', 'CapturePopup.tsx', 'RecorderPanel.tsx', 'SendToAgent.tsx'];
      for (const file of popups) {
        const text = await code(`src/renderer/browser/${file}`);
        if (/writeToSession|sendToMachineSession|writeToServerShell/.test(text)) return false;
      }
      return true;
    });

    // Last on purpose. Every question above is about the product and has already been
    // asked, and has already been allowed to fail, before this line is reached.
    //
    // What he filmed was a send to a session on ANOTHER computer — *"Coming to the remote
    // session at all. See."* — and the two remote routes are different channels with
    // different refusal sentences from the local one. With nothing paired and no server
    // added, neither of those channels exists on this computer at all, so this end can only
    // read the sequence and the far halves go unwatched.
    //
    // That is this MACHINE being short of a part, not the product misbehaving, and a guard
    // may not pair a machine or add a server to conjure one — that is the product changing
    // under the thing watching it. Written as an assertion it printed "a bug that was
    // already fixed is back" about a bug nobody had looked for, which is the fastest way
    // there is for a guard to stop being believed. So it is said out loud instead: NOT
    // PROVED, with the missing part named.
    const said = String(await page.evaluate(
      '(async()=>{try{const m=await window.deck.listMachines();'
      + 'const s=await window.deck.listServers();'
      + 'return JSON.stringify({machines:((m&&m.machines)||[]).length,'
      + 'servers:(Array.isArray(s)?s:((s&&s.servers)||[])).length})}'
      + 'catch(e){return JSON.stringify({machines:0,servers:0})}})()',
    ));
    const reach = JSON.parse(said);
    if (reach.machines === 0 && reach.servers === 0) {
      cannotRunHere(
        'this install has no machine paired and no server added, so neither of the two remote routes a send '
        + 'can take exists here — and the send he actually filmed going nowhere was the cross-machine one. '
        + 'The local leg and the whole two-write sequence were read and hold; the far halves were not watched. '
        + 'Pair a machine or add a server on the machine that runs this check, and it will run.',
      );
    }
  },
};
