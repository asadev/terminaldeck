/**
 * His browser pages did not blank when something else took the window. They were gone.
 */
export default {
  name: 'a browser page outlives a panel, a split, a swarm or a remote session taking the frame',

  fixed: '2026-08-20',

  because:
    'The browser pages were mounted in the LAST branch of the function that draws the main frame, and six branches '
    + 'return before it — a sidebar view, a split, the swarm grid, a session on a paired machine, a shell on a server, '
    + 'an empty window. So any of those unmounted every page at once, and unmounting a `BrowserWorkspace` closes its '
    + '`WebContentsView` for real: coming back mounted a fresh component with a blank tab. He filmed it in the second '
    + 'recording of 2026-08-20 and the first diagnosis blamed remote sessions, because a remote session was the trigger '
    + 'he happened to pull — it was one of six, and the cause was being drawn from a function that draws one thing. The '
    + 'fix hoists the mounts into the long-lived pane area beside that function, where views that must outlive a view '
    + 'change belong. Nothing in the language stops the next person putting a pane back inside the branch that reads '
    + 'most naturally, which is where all three families of pane started.',

  link: 'memory/session_2026-08-20_qrs_uncommitted.md S3; filmed in the second recording of 2026-08-20',

  async run({ expect, page, read, cannotRunHere }) {
    const source = String(await read('src/renderer/App.tsx'));

    /**
     * The body of the function that draws the main frame, matched by braces rather than
     * guessed at by line numbers — it is five hundred lines long and everything in this file
     * moves.
     */
    const mainView = (() => {
      const at = source.indexOf('const mainView = () => {');
      if (at < 0) return '';
      const opens = source.indexOf('{', source.indexOf('=>', at));
      let depth = 0;
      for (let i = opens; i < source.length; i += 1) {
        if (source[i] === '{') depth += 1;
        else if (source[i] === '}') {
          depth -= 1;
          if (depth === 0) return source.slice(opens, i + 1);
        }
      }
      return '';
    })();

    await expect('the function that draws one thing was actually found and read', async () => {
      // A brace match that fell off the end, or a renamed function, would leave an empty
      // string that satisfies every claim below by containing nothing — which is the one
      // failure this whole tool exists to prevent. It was 548 lines when this was written.
      return mainView.length > 5000;
    });

    await expect('all six things that can take the frame are still branches of that one function', async () => {
      /*
       * This is what makes the claim below worth anything. Each of these is a state that
       * returns before the branch the pages used to be in, and each one is a trigger somebody
       * pulled: opening a sidebar view, splitting, the swarm grid, a session on a paired
       * machine, a shell on a server, and a window with no tabs at all.
       *
       * Named by the state each branch tests rather than by the words around it. If one of
       * them ever stops being a branch here, this guard fails and somebody looks — which is
       * the right outcome, because a seventh way to take the frame is the next version of this
       * bug and it would arrive as an addition to exactly this list.
       */
      const triggers = ['showingPanel', 'splitting', 'swarm', 'openMachineSession', 'openServerSession', 'tabs.length === 0'];
      return triggers.every((state) => mainView.includes(state));
    });

    await expect('and not one browser page is mounted inside it', async () => {
      // The bug, in one sentence. `<BrowserWorkspace` inside this function is a page whose
      // life is the life of whichever branch happened to return it.
      return mainView.includes('<BrowserWorkspace') === false;
    });

    await expect('while the window does still mount pages somewhere', async () => {
      // The other half, and it is not a formality: deleting the mount entirely would satisfy
      // the claim above perfectly. The pages are mounted in `.panes`, beside that function
      // rather than inside it, which is the whole of the fix.
      const panes = source.indexOf('<div className="panes"');
      return panes > 0 && source.indexOf('<BrowserWorkspace', panes) > panes;
    });

    /**
     * Where the pages this window is holding are actually standing, asked of the running app.
     *
     * The source above says where they are written; this says where they ended up. Both,
     * because the arrangement only works if the mount is a SIBLING of the frame — a page
     * moved into the pane's own subtree is a remount by another name, and a remount is the
     * bug whatever the source looks like.
     */
    const standing = async () => {
      const said = String(await page.evaluate(
        '(()=>{const pages=[...document.querySelectorAll(".bw")];'
        + 'return JSON.stringify({count:pages.length,'
        + 'besideTheFrame:pages.every(el=>el.parentElement!==null'
        + '&&el.parentElement.classList.contains("panes")),'
        + 'panes:document.querySelectorAll(".panes").length})})()',
      ));
      try {
        return JSON.parse(said);
      } catch {
        // Never a throw. A guard that explodes on an unexpected answer stops at the line it
        // exploded on and everything it had not asked yet goes unasked; these counts read as
        // impossible instead, which fails the claims below by name.
        return { count: -1, besideTheFrame: false, panes: -1 };
      }
    };

    await expect('the pane area this all rests on is in the window exactly once', async () => {
      // Two of them would mean two frames and two ideas of what is in front, and the boxes the
      // pages are given are measured against this element — see `layout/pane-slots.ts`.
      return (await standing()).panes === 1;
    });

    /*
     * A tab is put in the frame FIRST, and that order is the whole discipline of this half.
     *
     * Guards share one running app and read whatever the guard before them left on screen. If
     * that is a sidebar view, then a build with the bug in it has already unmounted every page
     * — so counting the mounts here would find none, find none again afterwards, and report
     * green having watched the defect happen. Selecting an open tab clears the view and puts a
     * real one in the frame, which is the state both builds mount their pages in, and the
     * count taken there is the number the trigger below has to leave alone.
     */
    const somethingIsOpen = Boolean(await page.evaluate(
      "(()=>{const row=document.querySelector('.sb-row.sb-open .sb-row-main');"
      + 'if(row)row.click();return Boolean(row)})()',
    ));
    if (!somethingIsOpen) {
      // A precondition about this MACHINE, not a finding about the product. A window with
      // nothing in it at all cannot be asked this question — there is no frame to take and
      // nothing to take it from — so the trip the rest of this guard watches a page survive
      // does not exist here. Reporting that as "a bug that was already fixed is back" sends
      // somebody hunting a regression nobody has seen; reporting it as green would be worse.
      // It is neither, and it says so. The source claims above have already run and can still
      // fail — only the live half stops here.
      cannotRunHere(
        'nothing is open in this Terminal Deck window: the sidebar lists no session or page to put in the '
        + 'frame, so there is no page whose survival a sidebar view could be watched to interrupt. Open a tab '
        + '(a terminal session or a browser page) in the install this check drives, leave it open, and the '
        + 'live half of this guard will run.',
      );
    }

    await page.wait(600);
    const before = await standing();

    if (before.count > 0) {
      await expect('every page in the window is standing beside the frame, not inside it', async () => {
        return before.besideTheFrame;
      });
    }

    /*
     * One of the six, pulled for real.
     *
     * A sidebar view taking the frame is the only trigger a guard may pull: it is a
     * navigation and it changes nothing. Splitting the window, starting a swarm and opening a
     * session on another machine are all changes to the product — and the last of them needs
     * another computer — so they are not pulled here. The claim above is what covers them,
     * and it covers them properly: they are triggers of one cause, and the cause is whether
     * the mount is inside the function they return from.
     */
    const tookTheFrame = Boolean(await page.evaluate(
      "(()=>{const b=[...document.querySelectorAll('button.sb-nav')]"
      + ".find(e=>((e.querySelector('.sb-label')||{}).textContent||'').trim()==='Machines');"
      + 'if(b)b.click();return Boolean(b)})()',
    ));
    await page.wait(700);
    const during = await standing();

    await expect('a sidebar view really did take the frame, so this was a trigger and not a re-read', async () => {
      const arrived = Boolean(await page.evaluate(
        'Boolean(document.querySelector(\'.panel-page[data-panel="remote"]\'))',
      ));
      return tookTheFrame && arrived;
    });

    if (before.count > 0) {
      await expect('every page is still there with a sidebar view over it', async () => {
        // Not "a tab is still listed" — the strip kept listing tabs perfectly while the pages
        // behind them had been destroyed, which is why the report was about a page coming back
        // blank rather than about a tab disappearing.
        return during.count === before.count;
      });

      await expect('and still standing beside the frame rather than under it', async () => {
        return during.besideTheFrame;
      });
    }

    /*
     * WHAT THIS GUARD CANNOT REACH, said here rather than left to be assumed.
     *
     * Five of the six triggers are changes to the product and a guard may not make them: a
     * split rearranges his window, a swarm starts sessions, a remote session needs a machine
     * paired to this one, and an empty window means closing what is open. Nor can this prove a
     * page's CONTENT survived — reading inside a native view means driving somebody's page.
     *
     * And the counted half only bites in a window somebody has actually opened a page in: the
     * count is zero on a run against a fresh settings folder, and those claims are then
     * skipped rather than passed. That is deliberate — zero pages surviving is not evidence of
     * anything — and it is why the source claims above are written as the primary answer. They
     * hold on any window at all, and they are what covers all six triggers at once.
     */
  },
};
