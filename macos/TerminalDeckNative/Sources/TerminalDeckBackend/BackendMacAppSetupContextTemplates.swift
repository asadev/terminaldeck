import Foundation

/// Generated from source template chunks; no JavaScript runtime or editable settings.
enum BackendMacAppSetupContextTemplates {
 static func render(_ page: String, _ values: [String]) -> String {
  switch page {
  case "index":
   // Slots: preamble(input.version) | BRAND.name | input.version | machine | where | opener
   return "" + values[0] + "\n\n# " + values[1] + " — what a session can look up about the app around it\n\nA session running in this app was told, at the top of its context, that this\ndirectory exists. This file is the index: it says what the other files answer, so\nthat a question about this app can be looked up rather than guessed at.\n\nNothing here is a secret and nothing here needs repeating back. It is a\ndescription of the surroundings, so that \"open it in the browser\", \"which machine\nis this\" and \"look at B2\" mean something specific.\n\n## This install\n\n- Version: " + values[2] + "\n- Machine: " + values[3] + "" + values[4] + "\n- " + values[5] + "\n\n## The other files here\n\n- `sessions-and-machines.md` — what a session is here, which machine it is\n  running on, and how this app learns what a session is doing.\n- `browser-windows.md` — the browser windows this app has of its own, how one\n  comes to belong to a session, what `B1` and `B2` mean, and what that lets a\n  session do.\n"
  case "sessions":
   // Slots: preamble(input.version) | home.via === 'ssh' ? sshWhatASessionIs() : localWhatASessionIs() | home.via === 'ssh' ? sshHowItKnows() : localHowItKnows() | BRAND.name |  home.via === 'ssh' ? `This session is running on ${input.machineName}, and the app — with its screen, its browser windows and the person reading this — is on ${home.appMachineName}.` : `This session is running on ${input.machineName}.` 
   return "" + values[0] + "\n\n# Sessions and machines\n\n## What a session is here\n\n" + values[1] + "\n\nThe agents this build starts are Claude Code, Codex CLI, Gemini CLI, a plain\nshell, and any other command the person added themselves.\n\n## How the app knows what a session is doing\n\n" + values[2] + "\n\n## Machines\n\n" + values[3] + " runs sessions on more than one machine: the computer it is running\non, any machine paired with it, and any server it is signed in to over SSH. They\nare listed under Integrations in the app's sidebar, and a session started on one\nof them runs *there* — with that machine's filesystem, shell, network and logins.\n\nThis matters most when it is least obvious. The person reading your output may be\nsitting at a different computer from the one you are running on. Their files are\nnot the files you can see, their `localhost` is not your `localhost`, and a path\nthey paste may not exist here.\n\n" + values[4] + "\n"
  case "browser":
   // Slots: preamble(input.version) | BRAND.name |  home.via === 'ssh' ? `, on ${home.appMachineName}` : ''  | opening | drivingSection(input, home)
   return "" + values[0] + "\n\n# Browser windows\n\n" + values[1] + " has browser windows of its own, in the same window as the sessions" + values[2] + ".\nOne of them can be attached to a session, and that relation is what gives \"the\nbrowser\" an address instead of leaving it a guess.\n\n## Names\n\nA window attached to a session is called `B1`, `B2`, `B3` … The number belongs\nto that session, is given out when the window is attached, and is never reused —\nso `B2` means the same window for as long as the session lives, including after\n`B1` has been detached.\n\nWhen the windows attached to a session change, that session is told: at the top\nof its next turn, or at its very next tool call if it is already working. The\nline for a window carries its name, its title and its address — each part left\noff entirely when the window has not reported it, rather than filled in with a\nplaceholder that would read like a fact.\n\nIt carries one more part only when that part is true: the machine actually\nserving the page. A page reached through this app's tunnel wears a `localhost`\naddress on the machine it is being viewed from, so the URL alone would say the\nopposite of the truth, and `— served by <machine>` is the correction.\n\n## How a window comes to belong to a session\n\nA person does this. Two places, and they are the same relation seen from either\nend:\n\n- from the session — the `⋯` menu beside it, then **Connect browser**, then the\n  window;\n- from the browser window — its own menu, then the session.\n\nBoth are checklists: the ticked row is the current relation, ticking another\nmoves it, and unticking the ticked one detaches. A session cannot attach a window\nto itself, so asking for one is a request for the person to act on, not a tool\ncall to look for.\n\n" + values[3] + "\n\n## What a session can do with a window\n\n" + values[4] + "\n"
  case "localSession":
   // Slots: BRAND.name | BRAND.sessionEnvVar
   return "One agent CLI, in one pseudo-terminal, in one folder, started by " + values[0] + ".\nEvery session has an id, and a session's own id is in its environment as\n`" + values[1] + "`.\n\nThat variable is also how this app tells its own sessions apart from everything\nelse on the machine. The hooks below are installed for the whole account, so they\nfire for a `claude` somebody started in a plain terminal too — and that one is\nanswered with nothing, deliberately. If you were given this map, you are inside\nthe app."
  case "sshSession":
   // Slots: BRAND.name
   return "One agent CLI, in one SSH shell that " + values[0] + " opened on this server, shown\nas a session in the app on the other end of that connection: its own tab, its own\nrow in the rail, and browser windows of its own.\n\nThere is no session id in this shell's environment, and there is nothing here to\nlook one up in. What ties this shell to that tab is the folder this file is in,\nwhich the app made for this terminal alone and removes when it closes."
  case "localHooks":
   // Slots: BRAND.id
   return "Through the CLI's own hook file — `~/.claude/settings.json`,\n`~/.codex/hooks.json` or `~/.gemini/settings.json` — which this app writes one\nentry into per lifecycle event, each tagged `# " + values[0] + "-hook`. Entries\nbelonging to anything else are never touched.\n\nEach event POSTs the CLI's own event JSON to a unix socket (a named pipe on\nWindows) that only this account can open. The app reads the event name, the\nworking directory and the tool being called, and turns them into the status shown\non that session's tab.\n\nThe reply to that same POST is how the context at the top of this session\narrived. It reaches the model through the CLI's own hook output, so no character\nof it is typed into the terminal the person is looking at, and there is nothing\nfor them to scroll back to."
  case "sshHooks":
   // Slots: BRAND.id
   return "Through this server's own `claude`, started by a small wrapper that is first on\nthis shell's PATH. The wrapper adds two settings files from the folder this\ndocument is in: one that gives the agent this app's browser verbs, and one that\ninstalls three lifecycle hooks tagged `# " + values[0] + "-hook`.\n\nNothing was written into this account's home directory. `~/.claude/settings.json`\non this server is exactly as its owner left it, and everything this app put here\nis inside one folder under `/tmp` that goes when this terminal closes, when the\npermission for this server is switched off, or when the app quits.\n\nEach hook POSTs the CLI's own event JSON back to the app over a port on this\nserver's own loopback, which the app's SSH connection opened and which nothing off\nthis machine can reach. The reply to that POST is how the context at the top of\nthis session arrived, and how a browser window attached while you are working is\nannounced at your next tool call. No character of any of it is typed into the\nterminal the person is looking at."
  case "driving":
   // Slots: which | without | opener | closing
   return "" + values[0] + "\n\n**The verbs.** They are on the session's own tool list, carried in by a tool\nserver this app names on the command line: `browser_open`, `browser_read`,\n`browser_step`, `browser_screenshot`, `browser_handover`, `browser_close`,\nand a `tools_describe` that indexes the rest — usually under whatever prefix\nthe CLI puts on a tool it did not define. That list is the authority on what\neach one takes; nothing here repeats a schema that would go stale. They reach\nthe windows attached to **this** session and no others: with no target they take\nthe first one, `B1`, and `window: \"B2\"` names another of this session's own." + values[1] + "" + values[2] + "\n\n" + values[3] + ""
  case "openingShim":
   // Slots:  home.via === 'ssh' ? "this server's" : "the machine's"  |  home.via === 'ssh' ? `, on ${home.appMachineName},` : ''  |  home.via === 'ssh' ? 'this server' : 'the machine' 
   return "## Opening a page\n\n`open <url>` is on this session's PATH ahead of " + values[0] + " own opener, so a\n`http://` or `https://` URL you open lands in a window in this app" + values[1] + " and the\ncommand prints which one. If a window is already attached to this session, the\npage goes there. If none is, the app opens one, attaches it, and says so.\n\nEverything that is not a single http(s) URL — `open .`, `open -a Xcode f.swift`,\n`open -R`, a PDF, a bare `open` — is handed to the real opener untouched. So is\nevery URL when this app cannot be reached: the command falls through to " + values[2] + "\nand says that it did, rather than exiting quietly having opened nothing."
  case "openingSSH":
   // Slots: 
   return "## Opening a page\n\nThis app could not put its own opener on this shell's PATH, so `open` here is\nthis server's own and a URL you open opens **on this server** rather than in the\napp. Windows already attached to this session are still yours to read about\nbelow; ask the person to open a page into one of them."
  case "openingBare":
   // Slots: platformNoun(platform)
   return "## Opening a page\n\nThis build does not put an opener on a session's PATH on " + values[0] + ",\nso `open` here is the machine's own and a URL you open does not land in this\napp. Windows already attached to this session are still yours to read about\nbelow."
  case "drivingOpener":
   // Slots: 
   return "\n\n`open <url>` does not depend on any of this. It is a script on this session's\nPATH, so a session without the verbs can still put a page in front of the person\nand say what it would have done with it."
  case "whichSSH":
   // Slots: 
   return "This session has this app's browser verbs, and that is not a hope. They\narrive through the `claude` wrapper that is first on this shell's PATH, and\nthis app puts these documents on a server only in the same breath as that\nwrapper — so a session able to read this page is a session able to act on its\nwindows."
  case "whichLocal":
   // Slots: 
   return "Two answers, and a session is told which one is its own rather than left to\nfind out by trying."
  case "without":
   // Slots: noVerbsReasons() .map((clause) => `- ${clause[0].toUpperCase()}${clause.slice(1)}.`) .join('\n')
   return "\n\n**Without them.** They ride on a launch flag only Claude Code takes, added by\nthis app when it starts the session, and there are launches that cannot be given\nit:\n\n" + values[0] + "\n\nSuch a session is told which of those it is, in one sentence carrying the reason\nand what to do instead, at the top of its context as soon as it has a window to\nbe told about. There is no second way in: reading the page through a debugging\nport, a browser driver or an extension of the session's own is not a route this\napp leaves open, and a turn spent looking for one is a turn spent on a door that\nis not there."
  case "closingLocal":
   // Slots: 
   return "So \"look at B2\" from the person means: read `B2` if this session has the\nverbs, and otherwise put a page there and ask them what it says."
  case "closingSSH":
   // Slots: 
   return "So \"look at B2\" from the person means: read `B2`."
  default: preconditionFailure("Unknown app context template")
  }
 }
}
