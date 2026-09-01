/**
 * Twelve reports in five days — the most-repeated defect in the whole audit —
 * and the first fix turned a silent loss into a crash.
 */
export default {
  name: 'switching the account keeps the same session: same tab, same place on the bar, same conversation',

  fixed: '2026-08-22',

  because:
    'An account is a config directory handed to a CLI at spawn, so a running agent genuinely cannot change account — '
    + 'something has to restart. What was wrong was *which* thing restarted. The chip opened a second session in a '
    + 'second tab and left him to find it: *"it starts a new session with that account instead of changing it in the '
    + 'same session."* Then, once the tab was kept, the conversation was not: the one-conversation guard sees a live '
    + 'session of the same agent in the same folder — which is precisely what a replacement is, for the few hundred '
    + 'milliseconds of the start-then-stop order — and dropped `--continue` on every switch ever made. *"See, it is not '
    + 'going to keep it… It\'s not keeping the conversation history."* And the first repair made it worse: the rebuilt '
    + 'command line handed the agent `--session-id <the id being resumed>`, the CLI answered `Session ID … is already '
    + 'in use`, and the tab was left empty — a silent loss turned into a hard crash. Four separate mechanisms have to '
    + 'hold at once for this to work, none of them is visible on screen, and each one has failed on its own.',

  link: 'asks-audit-2026-08-28 DES-075 (twelve mentions, 2026-08-17 → 2026-08-22); review-2026-08-20 D1 "HIS BIGGEST NEED"',

  async run({ expect, page, read, project, cannotRunHere }) {
    /**
     * The rules that decide a switch, loaded and driven rather than read.
     *
     * Every function below is pure by construction — `session-switch.ts` says
     * of itself that the plan is a separate question asked before anything is
     * stopped, and `one-conversation.ts` is three functions over a list — so
     * they answer here exactly as they answer inside the app. Bundled in memory
     * and imported as a data URL: nothing is written to disk, no session is
     * created, no account is touched.
     *
     * The renderer's three are in the same bundle deliberately. "Same tab, same
     * place on the bar" is decided in the window and "same conversation" is
     * decided in the main process, and the whole complaint is that both have to
     * be true at the same moment — so both are asked in one breath.
     */
    const rules = await (async () => {
      try {
        const esbuild = await import('esbuild');
        const built = await esbuild.build({
          stdin: {
            contents:
              "export { planSwitch, conversationToCarry } from './src/main/session-switch'\n"
              + "export { argsForSpawn, conversationIsHeld } from './src/main/one-conversation'\n"
              + "export { PendingSwitches, replayWrites } from './src/main/switch-later'\n"
              + "export { replaceInStrip } from './src/renderer/browser/workspace-strip'\n"
              + "export { replaceTabInPanes } from './src/renderer/layout/panes'\n"
              + "export { withReplacedSession } from './src/renderer/state/store'\n",
            resolveDir: project.paths.root,
            loader: 'ts',
          },
          bundle: true,
          format: 'esm',
          platform: 'node',
          write: false,
          logLevel: 'silent',
        });
        const bytes = Buffer.from(built.outputFiles[0].text).toString('base64');
        return await import(`data:text/javascript;base64,${bytes}`);
      } catch {
        // Null rather than a throw, so the claim below fails as its own sentence
        // rather than as a stack trace nobody reads.
        return null;
      }
    })();

    await expect('the rules that decide a switch could really be loaded and asked', async () => {
      // Everything after this is an assertion about what these functions answer,
      // and an assertion made against a module that did not load is the one
      // failure this whole tool exists to prevent.
      return rules !== null
        && typeof rules.planSwitch === 'function'
        && typeof rules.conversationToCarry === 'function'
        && typeof rules.argsForSpawn === 'function'
        && typeof rules.withReplacedSession === 'function';
    });

    /* ─────────────────────────────────────────────────────────── the plan -- */

    /** One tab, mid-conversation, on the machine's own install. */
    const meta = {
      id: 'live-1',
      cwd: '/w',
      provider: 'claude',
      exitCode: null,
      profileId: 'system',
      profileName: 'Default',
      tabKey: 'tab-7',
      cols: 80,
      rows: 24,
    };
    /** Its ledger record — what makes it *his* tab rather than the copilot's. */
    const saved = { cwd: '/w', provider: 'claude', profileId: 'system', cols: 80, rows: 24, tabKey: 'tab-7', lastSeenAt: 1 };
    /** The other login, on the same agent. */
    const target = { id: 'p2', name: 'Work', provider: 'claude', configDir: '/c/p2', system: false, color: '--accent', createdAt: 0, lastUsedAt: null };
    /** `planRestore`'s answer for this session under that login. */
    const found = { session: saved, outcome: 'resume', reason: 'there is a conversation here', configDir: '/c/p2', conversation: 'found' };

    /** @param {Record<string, unknown>} over */
    const plan = (over = {}) => rules.planSwitch({
      sessionId: 'live-1', meta, saved, target, decision: found, occupied: false, sharedStore: true, ...over,
    });

    await expect('with one shared history, the conversation on screen is the one that carries over', async () => {
      // The headline, and the state his accounts are actually in: `shared-projects.ts`
      // links both logins' `projects/` into one place, so the transcript the
      // replacement continues is *this* conversation and not merely one that
      // happens to live in the same folder. `follows` is the only value the sheet
      // is allowed to make that promise on, and `resume` is what makes it true.
      const said = plan();
      return said.refusal === null && said.conversation === 'follows' && said.resume === true;
    });

    await expect('with two separate histories it still resumes, and says whose conversation it is', async () => {
      // Not a downgrade of the line above — a different fact. Two stores means
      // the replacement picks up the *other* account's conversation in the same
      // folder, which is a real thing to want and a lie to call `follows`. This
      // is the rung that keeps the sheet honest for anybody who has not turned
      // sharing on, which is where the second report of "not fixed" came from.
      const said = plan({ sharedStore: false });
      return said.conversation === 'theirs' && said.resume === true;
    });

    await expect('a conversation another tab is already on is left alone', async () => {
      // Two terminals on one transcript fork it — measured, and the reason
      // `planRestore` exists at all. So a switch into a conversation somebody
      // else's tab is holding starts clean and says so, rather than joining it.
      const said = plan({ occupied: true });
      return said.conversation === 'taken' && said.resume === false;
    });

    await expect('and where the other account has never worked here, nothing is claimed about a conversation', async () => {
      const fresh = { session: saved, outcome: 'fresh', reason: 'nothing to continue', configDir: '/c/p2', conversation: 'none' };
      const unknown = { session: saved, outcome: 'resume', reason: 'a store this app cannot read', configDir: '/c/p2', conversation: 'unknown' };
      // `unreadable` is Codex, and a session inside WSL whose history sits under
      // a Linux home this process was never told about. The CLI is asked to
      // continue and answers for itself; the sheet must not answer for it.
      return plan({ decision: fresh }).conversation === 'stays'
        && plan({ decision: unknown }).conversation === 'unreadable';
    });

    await expect('a session that is not somebody\'s tab is refused rather than quietly turned into something else', async () => {
      // The copilot is spawned with an instruction layer, `--mcp-config` and a
      // fence; a device's session is held inside a folder grant. Restarting
      // either from a `SavedSession` produces something that is not the session
      // that was written down — so the ledger's absence is the test, and the
      // answer is a sentence rather than a bare shell wearing the same tab.
      const said = plan({ saved: null });
      return typeof said.refusal === 'string' && said.refusal !== '' && said.resume === false;
    });

    await expect('a plain shell, a dead session and another agent\'s login are each refused in words', async () => {
      // Four refusals, four different sentences, and every one of them is a
      // state a person can reach from the menu. Handing a Codex config
      // directory to a Claude session is the one that used to be *quiet* —
      // `resolveProfileId` fell back to the machine's own install — which is
      // indistinguishable from the app ignoring the click.
      const shell = plan({ meta: { ...meta, provider: 'shell' } });
      const ended = plan({ meta: { ...meta, exitCode: 0 } });
      const other = plan({ target: { ...target, provider: 'codex' } });
      const already = plan({ target: { ...target, id: 'system' } });
      return [shell, ended, other, already].every((said) => typeof said.refusal === 'string' && said.refusal !== '');
    });

    /* ──────────────────────────────────────────── which conversation, by id -- */

    await expect('the replacement is told which conversation to continue, by name', async () => {
      // `--continue` means *the folder's newest*, which is a guess that is right
      // nearly always. The sheet promises the conversation **on screen**, and
      // this app knows its id because it put it on the outgoing process's own
      // command line. Naming it is the difference between the promise and a
      // coincidence.
      return rules.conversationToCarry({ plan: plan(), agentSessionId: 'conv-1', readableInTarget: true }) === 'conv-1';
    });

    await expect('but never a transcript the account being switched to cannot see', async () => {
      // This is the crash, one layer up: `--resume` against an id the target's
      // store cannot open is a process that prints an error and exits, and the
      // switch becomes "nothing happened". Falling back to the folder's newest
      // leaves the behaviour exactly as it was, which is the safe direction.
      return rules.conversationToCarry({ plan: plan(), agentSessionId: 'conv-1', readableInTarget: false }) === null;
    });

    await expect('and never a conversation the sheet has just said it would not touch', async () => {
      // `theirs` is the deliberate case where the two logins keep separate
      // stores. Naming this session's own transcript there would reach into a
      // store the person has just been told would be left alone.
      const theirs = plan({ sharedStore: false });
      return rules.conversationToCarry({ plan: theirs, agentSessionId: 'conv-1', readableInTarget: true }) === null;
    });

    /* ─────────────────────────────── the guard that ate every switch there was -- */

    const live = [{ id: 'live-1', cwd: '/w', provider: 'claude', exitCode: null }];

    await expect('a second session in a folder still starts clean, which is the rule this must not break', async () => {
      // The floor. Two live agents resolving one `--continue` fork the
      // transcript silently, and that is what `one-conversation.ts` is for. An
      // exemption that also let an ordinary second tab resume would be a worse
      // bug than the one being fixed.
      return rules.conversationIsHeld(live, '/w', 'claude') === true
        && rules.argsForSpawn({ resume: true, resumeArgs: ['--continue'], args: [], live, cwd: '/w', provider: 'claude', replaces: null }).length === 0;
    });

    await expect('and the one live session a replacement is replacing does not count against it', async () => {
      // The whole of *"it's not keeping the conversation history"*. The switch
      // starts the replacement **before** it stops the outgoing process — so a
      // spawn that cannot start leaves a working session alone — and for those
      // few hundred milliseconds there are two live Claude sessions in one
      // folder. `replaces` is the one caller entitled to say "that one is on its
      // way out", and without it the continue flag was dropped every single time.
      return rules.conversationIsHeld(live, '/w', 'claude', 'live-1') === false
        && rules.argsForSpawn({ resume: true, resumeArgs: ['--continue'], args: [], live, cwd: '/w', provider: 'claude', replaces: 'live-1' })
          .join(' ') === '--continue';
    });

    /* ─────────────────────────────────────── the tab, and where it sits -- */

    await expect('the replacement takes the old session\'s place in the list, not the end of it', async () => {
      // A new process is a new session id for what is, to the person, the tab
      // they were already looking at. Appending it and dropping the old one
      // produces the right *set* and the wrong order — invisible until somebody
      // with four tabs switches the first one and watches it jump to the end.
      const sessions = [
        { id: 'a', cwd: '/x', projectPath: '/x', provider: 'claude', exitCode: null, status: 'idle', statusSince: 0 },
        { id: 'live-1', cwd: '/w', projectPath: '/w', provider: 'claude', exitCode: null, status: 'idle', statusSince: 0, title: 'my tab', namedByUser: true },
        { id: 'c', cwd: '/y', projectPath: '/y', provider: 'claude', exitCode: null, status: 'idle', statusSince: 0 },
      ];
      const after = rules.withReplacedSession(sessions, 'live-1', { ...meta, id: 'live-2', profileId: 'p2', profileName: 'Work' });
      return after.length === 3 && after[1].id === 'live-2' && after[0].id === 'a' && after[2].id === 'c';
    });

    await expect('a name he typed on that tab survives the process underneath it', async () => {
      // A title the person chose is the one fact on the row that came from them.
      // The replacement's own title is the folder's basename, so carrying it
      // over unconditionally would rename his tab in the middle of a switch.
      const sessions = [{ id: 'live-1', cwd: '/w', projectPath: '/w', provider: 'claude', exitCode: null, status: 'idle', statusSince: 0, title: 'billing', namedByUser: true }];
      const after = rules.withReplacedSession(sessions, 'live-1', { ...meta, id: 'live-2', title: 'w' });
      return after[0].title === 'billing' && after[0].namedByUser === true;
    });

    await expect('the tab stays exactly where it was on the bar', async () => {
      // By index, never remove-then-add. The strip holds an arrangement somebody
      // made by hand, and a switch is not a promotion — a tab that was never on
      // the bar must stay off it.
      return rules.replaceInStrip(['a', 'live-1', 'c', 'd'], 'live-1', 'live-2').join(',') === 'a,live-2,c,d'
        && rules.replaceInStrip(['a', 'c'], 'live-1', 'live-2').join(',') === 'a,c';
    });

    await expect('and a split he arranged by hand is still a split afterwards', async () => {
      // Without this the switch is a prune and an insert: the pane holding the
      // old id collapses and the replacement arrives with nowhere to be. Somebody
      // who split their window and switched the left half would watch the layout
      // rearrange itself in response to something that was not a drag.
      const layout = {
        root: {
          type: 'split', id: 'sp', direction: 'horizontal', ratio: 0.5,
          children: [{ type: 'leaf', id: 'L', tabId: 'live-1' }, { type: 'leaf', id: 'R', tabId: 'browser:9' }],
        },
        focusedPaneId: 'L',
      };
      const after = rules.replaceTabInPanes(layout, 'live-1', 'live-2');
      return after.root.type === 'split'
        && after.root.ratio === 0.5
        && after.root.children[0].tabId === 'live-2'
        && after.root.children[1].tabId === 'browser:9';
    });

    /* ──────────────────────────── the name that outlives the process, and the crash -- */

    /**
     * A file with its comments taken out and its whitespace flattened.
     *
     * Both halves matter. Every rule below is argued in prose directly above the
     * line that implements it — the crash has a whole paragraph quoting the
     * error the CLI printed — so a plain search finds the explanation and passes
     * on a build that stopped obeying it. Three tests on this project have
     * already failed from the other direction, on their own comments. Flattening
     * the whitespace afterwards is what keeps a reformat from reading as a
     * regression.
     *
     * @param {string} rel
     */
    const code = async (rel) => String(await read(rel))
      .replace(/\/\*[\s\S]*?\*\//g, ' ')
      .replace(/^[ \t]*\/\/.*$/gm, ' ')
      .replace(/\s+/g, ' ');

    const core = await code('src/main/host-core.ts');

    await expect('the engine\'s own launch path was really read', async () => {
      // The hole these four claims cannot notice about themselves: a renamed or
      // moved file reads as a short string, and a short string contains none of
      // the mistakes below.
      return core.length > 15_000;
    });

    await expect('a replacement inherits the tab name of the session it replaces', async () => {
      // `tabKey` is what the strip's saved arrangement is written in, and it is
      // the one thing about a tab that no amount of looking at the session could
      // work out. Minting a fresh one on a switch would put the tab back where it
      // was for this run and lose its place at the next launch — the slowest
      // possible way to fail.
      return /const tabKey = input\.requested \?\? input\.inherited \?\? input\.mint\(\)/.test(core)
        && /inherited: input\.replaces !== undefined \? ledger\.get\(input\.replaces\)\?\.tabKey : undefined/.test(core);
    });

    await expect('the session being replaced is passed down to the one-conversation guard', async () => {
      // The other end of the exemption proved above. The rule can be perfect and
      // still lose every conversation if nothing hands it the id.
      return /replaces: typeof input\.replaces === 'string' \? input\.replaces : null/.test(core);
    });

    await expect('an id is only ever DECLARED for a conversation that does not exist yet', async () => {
      // The crash, at the line that caused it. `--session-id` declares an id;
      // `--resume` joins one; the CLI refuses the first against a transcript that
      // already exists — `Error: Session ID … is already in use` — and that is
      // exactly the transcript a switch is resuming. Measured 2026-08-20: the
      // agent printed it, exited, and left the tab empty. `declaredId` is null on
      // every resume path, which is what makes the wrong command line
      // unreachable rather than merely unintended.
      return /const declaredId = namesConversation \? randomUUID\(\) : null/.test(core)
        && /'--session-id', declaredId/.test(core);
    });

    await expect('and the id being resumed can never reach that flag', async () => {
      // The same fault spelled any of the ways it could come back. The line used
      // to read `agentSessionId === null ? chosen : …--session-id…`, and on the
      // one path where those two differ it threw away the arguments chosen for
      // the resume and rebuilt them around the id it was resuming.
      return /'--session-id',\s*(agentSessionId|input\.resumeConversationId)/.test(core) === false
        && /\['--resume', input\.resumeConversationId as string\]/.test(core);
    });

    /* ────────────────────────────── and the same switch, at his next message -- */

    await expect('the deferred switch still carries the line he was typing across', async () => {
      // *"if we change the account, the running agent will keep running on the
      // previous one… when we give another command and it starts working, it will
      // be changed."* The message is typed into the old process one keystroke at
      // a time, and that process is about to be stopped — so the Enter is
      // intercepted, not passed through, and the line is replayed into the
      // replacement. Delivered exactly once, to exactly one account.
      const armed = new rules.PendingSwitches();
      armed.arm({ sessionId: 'live-1', profileId: 'p2', accountName: 'Work', plan: plan() });
      const typing = armed.observe('live-1', 'run the tests');
      const enter = armed.observe('live-1', '\r');
      return typing.kind === 'pass'
        && enter.kind === 'switch'
        && enter.line === 'run the tests'
        && enter.submit === true
        // Fired, so nothing is armed any more: a register that kept it would run
        // the switch again on his next message.
        && armed.get('live-1') === null;
    });

    await expect('a line it could not read exactly is put in the prompt rather than sent', async () => {
      // One press of the Up arrow used to turn `run the tests` into
      // `run the tests[A`, and that is what the replacement was handed:
      // *"what the fuck is this? This came in my message automatically."* The
      // model now admits it lost track instead of guessing — the line stays his,
      // and it is left for him to check.
      const armed = new rules.PendingSwitches();
      armed.arm({ sessionId: 'live-1', profileId: 'p2', accountName: 'Work', plan: plan() });
      armed.observe('live-1', 'run the tests');
      // The real bytes an Up arrow sends: escape, bracket, A — spelled as an
      // escape rather than pasted as one, because the old model classified the
      // escape byte alone as "a control I do not understand", gave up its
      // certainty, and then appended the printable tail as though he had typed it.
      armed.observe('live-1', '\x1b[A');
      const enter = armed.observe('live-1', '\r');
      return enter.kind === 'switch' && enter.line === 'run the tests' && enter.submit === false;
    });

    await expect('nothing is armed on a session nobody armed, and cancelling really disarms', async () => {
      // Both floors of a register that intercepts keystrokes. A switch leaking
      // onto another session would eat somebody else's Enter, and a cancel that
      // did not take would fire a switch he had changed his mind about.
      const armed = new rules.PendingSwitches();
      armed.arm({ sessionId: 'live-1', profileId: 'p2', accountName: 'Work', plan: plan() });
      const elsewhere = armed.observe('other-9', '\r');
      const dropped = armed.cancel('live-1');
      return elsewhere.kind === 'pass' && dropped === true && armed.observe('live-1', '\r').kind === 'pass';
    });

    await expect('the replayed line is written the way a message actually submits', async () => {
      // Two writes, never one. A stdin chunk of about 64 bytes or more is
      // classified as *pasted text*, where a carriage return is a newline rather
      // than submit — measured from the other direction when the composer's send
      // button turned out to be a no-op for every message with an attachment.
      // Almost every real prompt is longer than 64 characters, so a one-write
      // replay would leave the message sitting in the prompt while the app said
      // it had been sent.
      const [line, submit] = rules.replayWrites('run the tests', true);
      return line === 'run the tests' && submit === '\r';
    });

    /* ────────────────────────────────────────── asked of the running app -- */

    await expect('every door this feature needs is on the bridge and answers to its own name', async () => {
      // This app has registered a channel under one name and called it under
      // another three times in three days, and the rejection is silent
      // everywhere except here. Losing `switchSessionAccountLater` is the
      // quietest of the seven: the sheet then offers the immediate switch alone,
      // which looks like a design rather than a break.
      const missing = String(await page.evaluate(
        "['planSessionSwitch','switchSessionAccount','switchSessionAccountLater','cancelSessionSwitch',"
        + "'armedSessionSwitches','onSessionSwitched','onSessionSwitchFailed']"
        + ".filter(n=>typeof window.deck?.[n]!=='function').join(', ')",
      ));
      return missing === '';
    });

    await expect('the engine answers what is armed right now, with nothing armed', async () => {
      // Read from the register in the main process rather than remembered by the
      // window: a switch that fired while a settings window was open is gone, and
      // a chip drawing from its own memory would still be promising it.
      const said = String(await page.evaluate(
        "(async()=>{try{const a=await window.deck.armedSessionSwitches();"
        + "return Array.isArray(a)?'OK '+a.length:'NOT A LIST'}catch(e){return 'REJECTED '+String(e&&e.message||e)}})()",
      ));
      return said.startsWith('OK ');
    });

    await expect('and asking for a plan about nothing is answered with a sentence, not a rejection', async () => {
      /*
       * Asked with ids that name **nothing**, and that is not laziness.
       *
       * A plan for a real session and a real account is the one read-only-looking
       * call in this feature that writes: it links both logins' `projects/`
       * together before it reads them, deliberately, because the answer to "is
       * there a conversation here" is different on either side of the link. A
       * guard may not restructure somebody's account stores to watch them. So
       * this asks the question the refusal ladder answers before any disk is
       * touched — which is also the state a stale chip produces in the running
       * app, and the one the window has to survive.
       */
      const said = String(await page.evaluate(
        "(async()=>{try{const p=await window.deck.planSessionSwitch('no-such-session-guard','no-such-account-guard');"
        + "return (p&&typeof p.refusal==='string'&&p.refusal!=='')?'REFUSED':'ANSWERED WITHOUT A REASON'}"
        + "catch(e){return 'REJECTED '+String(e&&e.message||e)}})()",
      ));
      return said === 'REFUSED';
    });

    /** How many logins of one agent this install has to switch between. */
    const most = Number(await page.evaluate(
      "(async()=>{try{const s=await window.deck.listProfiles();"
      + "const rows=(s&&Array.isArray(s.profiles))?s.profiles:[];const by={};"
      + "for(const r of rows){const p=String(r&&r.provider||'');by[p]=(by[p]||0)+1}"
      + "return Math.max(0,...Object.values(by))}catch(e){return -1}})()",
    ));

    // ── and here is what this guard cannot do, said out loud ──────────────
    //
    // The proof he would recognise is the thing he did twelve times: open a
    // session, send two messages, switch account from the chip, and see the same
    // tab in the same place with both messages still on screen and the agent
    // still answering out of that conversation. That needs **two real signed-in
    // logins of one agent on this machine**, and a guard may not create an
    // account or sign one in — that is the product changing under the thing
    // watching it. Nor may it press the switch: pressing stops somebody's agent.
    //
    // NOT PROVED rather than failed. Failing here would print "a bug that was
    // already fixed is back" about a switch nobody made, on the defect he has
    // reported more often than any other — and a false alarm on this one is
    // exactly how a guard stops being believed.
    if (most < 2) {
      cannotRunHere(
        `this install has ${most < 0 ? 'no readable account list' : `at most ${most} login of any one agent`}, `
        + 'so there is no second account to switch a session to. Add a second account for the same agent, sign both '
        + 'in, and this guard\'s end-to-end half becomes answerable on the machine that runs the check.',
      );
    }
  },
};
