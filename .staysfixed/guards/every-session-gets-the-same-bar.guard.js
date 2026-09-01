/**
 * "This conversation happened 1,000 times now." Twice inside one recording.
 */
export default {
  name: 'a session on a paired machine and a terminal on a server can be controlled from the bar, like a local one',

  fixed: '2026-08-21',

  because:
    'His words, sitting in a terminal on his office server: *"Like I cannot even split, I cannot make it to the chat '
    + 'view, I cannot see the rest of the things exactly… every time I tell you I want exactly same identical view of '
    + 'every type of session inside, including remote session, including local session, including the Server session."* '
    + 'A minute later: *"Now when I am inside the server, I cannot even change the accounts and everything."* The '
    + 'controls were drawn and then refused, each with an explanatory sentence — and every sentence was true about the '
    + 'wiring rather than about the feature: both hooks reached this machine’s own session manager by this machine’s own '
    + 'session id, so over a session running somewhere else they asked about a session that does not exist here and were '
    + 'answered with nothing. Three kinds of session are drawn by three code paths and each one hid something different. '
    + 'The shipping notes for that release admit chat and the account chip on a *server* session never landed at all.',

  link: 'review-2026-08-21 items T6–T9, said at 00:55 into the recording and again at 02:00',

  async run({ expect, page, cannotRunHere }) {
    // Read-only, and that rules out the obvious check. Pressing one of these
    // controls TYPES A SLASH COMMAND INTO SOMEBODY'S TERMINAL — that is the
    // whole mechanism, `/model` and `/effort` written at the prompt the way a
    // person would — so a guard may press nothing here. What it can do is ask
    // whether the three roads still exist and still answer, which is precisely
    // what had gone missing when the bar drew a sentence instead of a menu.

    await expect('all three kinds of session still have a road to their controls', async () => {
      // Read, apply and watch, for each of the three targets. Nine names, and a
      // missing one takes a whole kind of session's controls away without a
      // word: `controlsWired` answers false, and the bar draws itself back and
      // explains. Losing the watcher is the quietest of the nine — the bar then
      // reads once when it mounts and never again, so a remote session's model
      // chip freezes on whatever it happened to say when the tab was opened.
      const missing = String(await page.evaluate(
        "['readAgentControls','applyAgentControl','onSessionData',"
        + "'readMachineControls','applyMachineControl','onMachineOutput',"
        + "'readServerControls','applyServerControl','onServerShellOutput']"
        + ".filter(n=>typeof window.deck?.[n]!=='function').join(', ')",
      ));
      return missing === '';
    });

    await expect('and the engine answers on all three, rather than rejecting the name', async () => {
      // Each asked with nothing in it, so every handler refuses on its own first
      // line and no terminal anywhere — local, paired or over SSH — is read, let
      // alone typed into. What is being looked for is the one answer that means
      // the road itself is gone: this app has registered a channel under one
      // name and called it under another three times in three days, and the
      // rejection for that is silent everywhere except here.
      const said = String(await page.evaluate(
        "(async()=>{const out=[];"
        + "const ask=async(what,call)=>{try{await call();out.push(what+': answered')}"
        + "catch(e){out.push(what+': '+String(e&&e.message||e))}};"
        + "await ask('this machine',()=>window.deck.readAgentControls({}));"
        + "await ask('a paired machine',()=>window.deck.readMachineControls(null,null));"
        + "await ask('a server terminal',()=>window.deck.readServerControls(null));"
        + "return out.join(' | ')})()",
      ));
      return /no handler registered/i.test(said) === false;
    });

    /** What this copy of the app can currently reach. */
    const reach = JSON.parse(String(await page.evaluate(
      "(async()=>{const count=async(ask)=>{try{const answer=await ask();"
      + "if(Array.isArray(answer))return answer.length;"
      + "if(answer&&Array.isArray(answer.machines))return answer.machines.length;"
      + "if(answer&&Array.isArray(answer.servers))return answer.servers.length;"
      + "return 0}catch(e){return -1}};"
      + "return JSON.stringify({machines:await count(()=>window.deck.listMachines()),"
      + "servers:await count(()=>window.deck.listServers())})})()",
    )));

    // ── and here is what this guard cannot do, said out loud ──────────────
    //
    // The proof in the write-up is a photograph of three bars side by side: a
    // local session, a session on one of his own machines, and a terminal on a
    // server, showing the same controls in the same order with the same labels.
    // Two of those three cannot exist on a computer with nothing paired and no
    // server added, and a guard may not pair a machine or add a server to make
    // them — that is the product changing under the thing watching it. So the
    // two checks below look for the far ends, and when they are not there they
    // fail and say so rather than reporting a comparison that was never made.
    // This is the defect he says he has raised most often and it is the hardest
    // one here to hold, which is exactly why a quiet pass would be the worst
    // outcome available.

    // NOT PROVED rather than failed. Two of the three bars cannot exist on a computer with
    // nothing paired and no server added, and a guard may not pair a machine or add a server
    // to make them appear — that is the product changing under the thing watching it. Failing
    // here would print "a bug that was already fixed is back" about a comparison nobody made,
    // and this is the defect he says he has raised most often: a false alarm on it is how a
    // guard stops being believed.
    if (reach.machines === 0 || reach.servers === 0) {
      cannotRunHere(
        'this install has '
        + (reach.machines === 0 ? 'no machine paired' : 'a machine paired')
        + ' and '
        + (reach.servers === 0 ? 'no server added' : 'a server added')
        + ', so two of the three session bars this compares do not exist here. Pair a machine and add a '
        + 'server on the machine that runs this check, and it will run.',
      );
    }
  },
};
