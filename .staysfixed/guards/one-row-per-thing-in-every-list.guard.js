/**
 * Four times in five days, on four different lists: his iPhone twice in
 * Devices, his email twice in the account menu, one box twice on Machines, and
 * one server sitting in two lists at once.
 */
export default {
  name: 'one phone, one login, one machine appears exactly once in every list',

  fixed: '2026-08-28',

  because:
    'Every list in this app is a list of things a person owns, and each of them found its own way to show one thing '
    + 'twice. Settings → Devices listed his iPhone twice — same name, same kind, the same fingerprint — one row saying '
    + '"Connected now" and one "Seen 7m ago", because signing in again always wrote a brand-new row instead of '
    + 'refreshing the one already there. The account menu printed the same email address twice, because an account is a '
    + 'config directory and two directories on one login are two accounts by the app\'s definition and one by every '
    + 'definition a person has. The machines page listed one box twice. A server that was connected appeared in two '
    + 'places at once. None of it is cosmetic: nothing on those screens tells the two rows apart, so Remove on the '
    + 'wrong one cuts off the phone in your hand. It keeps coming back because the rule is not in one place — every new '
    + 'list is a new place to forget it, and appending is always the shorter thing to write.',

  link: 'd0672ac, 43ada9b, b1fca8f, 5951076 — four lists in five days',

  async run({ expect, page }) {
    /**
     * Ask the engine for a list. Only questions: nothing here pairs a device,
     * adds an account, adds a server or opens a connection.
     *
     * A channel that is not registered in this build answers with a rejection
     * rather than an empty array, and the two mean opposite things — "nothing in
     * it" versus "could not be read" — so they are kept apart all the way down.
     */
    const listFrom = async (call, pick) => {
      const said = String(await page.evaluate(
        `(async()=>{try{ if (typeof window.deck?.${call} !== 'function') return JSON.stringify({missing:true});
           const answer = await window.deck.${call}();
           return JSON.stringify({ answer: answer === undefined ? null : answer });
         }catch(e){ return JSON.stringify({ refused: String(e && e.message || e) }); }})()`,
      ));
      const parsed = JSON.parse(said);
      if (parsed.missing || parsed.refused) return { readable: false, rows: [] };
      const rows = pick(parsed.answer);
      return { readable: Array.isArray(rows), rows: Array.isArray(rows) ? rows : [] };
    };

    /**
     * The four lists, and what identity means on each one.
     *
     * Identity is a measured fact in every case, never the name: every iPhone
     * since iOS 16 calls itself "iPhone", two people do call both their accounts
     * "Work", and a machine's label is editable. The key is the thing the app
     * itself is keyed on — the X25519 key a handshake proves, the directory
     * handed to the CLI, the address and login a connection is opened with.
     */
    const LISTS = [
      {
        what: 'devices',
        call: 'listRemoteDevices',
        pick: (answer) => answer,
        // A row with no key is deliberately never matched by anything: a device
        // paired over the tailnet has nothing to prove it is itself with, and
        // merging two of those on a display name would merge two strangers'
        // phones. So they are excluded here for the same reason.
        identity: (row) => (typeof row?.fingerprint === 'string' && row.fingerprint !== '' ? `key:${row.fingerprint}` : null),
      },
      {
        what: 'accounts',
        call: 'listProfiles',
        pick: (answer) => answer?.profiles,
        // An account **is** a config directory — that is the whole mechanism —
        // so two rows on one directory are provably one account. Two names can
        // look alike; two paths cannot.
        identity: (row) => (typeof row?.configDir === 'string' && row.configDir !== '' ? `dir:${row.configDir}` : null),
      },
      {
        what: 'servers',
        call: 'listServers',
        pick: (answer) => answer,
        // "The same login twice is the same server, not a second one." Port
        // included, because a box reached on 2222 and the same box on 22 are two
        // different things to sign in to; absent means 22 and is written out so
        // it cannot compare unequal to a row that spelled it.
        identity: (row) =>
          typeof row?.address === 'string' && row.address !== ''
            ? `ssh:${String(row.username ?? '').toLowerCase()}@${row.address.toLowerCase()}:${Number(row.port ?? 22)}`
            : null,
      },
      {
        what: 'machines',
        call: 'listMachines',
        pick: (answer) => answer?.machines,
        // Its public name at the relay, which is what a link is opened against.
        identity: (row) => (typeof row?.hostId === 'string' && row.hostId !== '' ? `host:${row.hostId}` : null),
      },
    ];

    /** @type {{what: string, readable: boolean, rows: unknown[], keys: (string|null)[]}[]} */
    const read = [];
    for (const list of LISTS) {
      const answered = await listFrom(list.call, list.pick);
      read.push({ ...answered, what: list.what, keys: answered.rows.map(list.identity) });
    }

    const readable = read.filter((one) => one.readable);
    const withRows = readable.filter((one) => one.rows.length > 0);

    await expect('enough of the four lists answered for this to mean anything', async () => {
      // A run that could read nothing would pass by knowing about nothing. Three
      // rather than four on purpose: the devices channel is only registered once
      // the remote half of the app is set up, and a machine that has never been
      // paired to anything genuinely does not have it.
      return readable.length >= 3;
    });

    await expect('every row that came back carries the identity the rule is keyed on', async () => {
      // The quiet way this check dies: a payload that stopped carrying
      // fingerprints, or config directories, and a comparison that is then
      // holding `null` against `null` and reporting that all is well. A row
      // whose identity cannot be read is a row this list cannot prove is unique,
      // and that is a red, not a pass — the one exception being a device with no
      // key at all, which the product itself refuses to match on.
      return read.every((one) =>
        one.what === 'devices' || one.keys.every((key) => typeof key === 'string'));
    });

    for (const one of readable) {
      await expect(`no two rows in ${one.what} name the same thing`, async () => {
        const seen = new Set();
        for (const key of one.keys) {
          if (key === null) continue;
          if (seen.has(key)) return false;
          seen.add(key);
        }
        return true;
      });
    }

    await expect('a list holding the same thing twice would actually be caught', async () => {
      // The floor, proved rather than assumed, and proved on the shapes this run
      // just read rather than on invented ones. Without it every claim above is
      // satisfied by a machine with nothing on it — which is exactly the machine
      // a check runs on. One real row, duplicated, has to come back as a clash.
      const sample = withRows.find((one) => one.keys.some((key) => key !== null));
      if (sample === undefined) return false;
      const key = sample.keys.find((one) => one !== null);
      const doubled = [...sample.keys, key];
      const seen = new Set();
      for (const one of doubled) {
        if (one === null) continue;
        if (seen.has(one)) return true;
        seen.add(one);
      }
      return false;
    });

    /* ------------------------------------------------ and on the screen itself -- */

    /**
     * The Machines page, opened first.
     *
     * Guards share one running app and run one after another, so a guard that
     * reads the screen reads whatever the guard before it left there. This is
     * the page his photographs were of — devices, machines and servers all draw
     * their rows on it — so it is opened by name and its arrival is proved by
     * the id the page draws on itself rather than assumed from a click.
     */
    const arrived = Boolean(await page.evaluate(
      "(()=>{const b=[...document.querySelectorAll('button.sb-nav')]"
      + ".find(e=>((e.querySelector('.sb-label')||{}).textContent||'').trim()==='Machines');"
      + 'if(b)b.click();return Boolean(b)})()',
    ));
    await page.wait(900);
    const onScreen = Boolean(await page.evaluate(
      'Boolean(document.querySelector(\'.panel-page[data-panel="remote"]\'))',
    ));

    await expect('the Machines page is the one on screen', async () => {
      return arrived && onScreen;
    });

    /**
     * Rows compared against each other, never against any wording.
     *
     * Two rows in one list that read *identically* is the complaint stated
     * exactly: "nothing on that screen tells them apart". It needs no knowledge
     * of what any row is supposed to say, so it survives every rewrite of the
     * words — and a row is only counted once it has something to say at all,
     * because two empty separators are not two of anything.
     */
    const twins = String(await page.evaluate(
      "(()=>{const page=document.querySelector('.panel-page[data-panel=\"remote\"]');"
      + 'if(!page)return JSON.stringify({found:false});'
      + "const out=[];for(const list of page.querySelectorAll('ul,ol')){"
      + "const rows=[...list.children].filter(el=>el.tagName==='LI')"
      + '.map(el=>(el.innerText||"").replace(/\\s+/g," ").trim()).filter(text=>text.length>=8);'
      + 'const seen=new Set();for(const text of rows){if(seen.has(text))out.push(text);seen.add(text)}}'
      + 'return JSON.stringify({found:true,twins:out})})()',
    ));

    await expect('no list on that page draws the same row twice', async () => {
      const said = JSON.parse(twins);
      return said.found === true && said.twins.length === 0;
    });

    /*
     * NOT asserted here, and it is a hole rather than an omission: the same four
     * lists exist on the iPhone and on Android, and two of the four reports were
     * photographed there — `DeckTabs.swift` and `MachinesScreen.kt` draw their
     * own rosters from their own stores. Neither app is opened by any check on
     * this machine (the config says so too), so a guard claiming anything about
     * them would be claiming it about code it never ran. The host-side rule that
     * feeds all of them is proved separately, in the guard that watches one key
     * naming one device.
     */
  },
};
