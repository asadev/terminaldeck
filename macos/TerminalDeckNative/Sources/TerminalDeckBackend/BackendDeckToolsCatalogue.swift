import Foundation
import TerminalDeckNativeCore

/// Verbatim metadata statically extracted from the four source tool factories.
public enum BackendDeckToolsCatalogue {
    public struct Entry: Sendable {
        public let module: String, title: String
        public let index: String?
        public let spec: BackendMCPTool
    }
    public static func entries() throws -> [Entry] {
        let raw = try NativeRPCValue.parseJSON(Data(metadata.utf8))
        return try (raw.elements ?? []).map { item in
            guard let tier = BackendMCPTier(rawValue: item["tier"].string ?? "") else { throw NativeRPCError.malformed("Invalid source tool tier") }
            return Entry(module: item["module"].string!, title: item["title"].string!, index: item["index"].string,
                spec: try BackendMCPTool(id: item["id"].string!, wireName: item["wire"].string!, description: item["description"].string!, inputSchema: item["inputSchema"], tier: tier))
        }
    }
    private static let metadata = ####"""
[
  {
    "module": "files-tools",
    "id": "files.list",
    "wire": "files_list",
    "tier": "read",
    "title": "List a folder in a project",
    "description": "One level of an open project’s folder tree, as the Files view shows it: names, folders first, with whether each is a link or is blocked (a link that leaves the project, a device). Files the project’s .gitignore or .deckignore hide are left out unless `showIgnored`. Walk deeper by passing a `path`.",
    "index": "One level of an open project’s file tree, as the Files view shows it.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "cwd": {
          "type": "string",
          "description": "An open project folder."
        },
        "path": {
          "type": "string",
          "description": "A folder inside it, relative. Omit for the top."
        },
        "showIgnored": {
          "type": "boolean"
        },
        "withStats": {
          "type": "boolean",
          "description": "Add sizes and dates (one stat per entry)."
        }
      },
      "required": [
        "cwd"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "files-tools",
    "id": "files.read",
    "wire": "files_read",
    "tier": "read",
    "title": "Read a file in a project",
    "description": "Read a text file in an open project, as the file viewer shows it — a page of lines at a time; `fromLine` reads further. Binary files and files over 2 MB are reported, not returned. Files whose whole purpose is a credential (.env, .npmrc, private keys, keystores, terraform state, cloud credential folders) are refused by name; that is a reduction, not a guarantee, so do not treat a readable file as secret-free.",
    "index": "Read a text file in an open project, a page of lines at a time. Credential files are refused.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "cwd": {
          "type": "string",
          "description": "An open project folder."
        },
        "path": {
          "type": "string",
          "description": "The file, relative to the project."
        },
        "fromLine": {
          "type": "integer",
          "description": "First line to return, from 1. Default 1."
        },
        "lines": {
          "type": "integer",
          "description": "How many lines. Default 400, max 2000."
        }
      },
      "required": [
        "cwd",
        "path"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "files-tools",
    "id": "files.find",
    "wire": "files_find",
    "tier": "read",
    "title": "Find files by name",
    "description": "Find files in an open project by part of their name or path, like the ⌘P quick open: every word of `query` must appear in the path, file-name matches first. Uses git’s list of files where there is one, so ignored and generated files are left out. `refresh` lists again instead of using the last few seconds’ answer.",
    "index": "Find files in an open project by part of their name or path — the ⌘P quick open.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "cwd": {
          "type": "string",
          "description": "An open project folder."
        },
        "query": {
          "type": "string"
        },
        "limit": {
          "type": "integer",
          "description": "Default 50, max 200."
        },
        "refresh": {
          "type": "boolean"
        }
      },
      "required": [
        "cwd",
        "query"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "files-tools",
    "id": "files.ignored",
    "wire": "files_ignored",
    "tier": "read",
    "title": "What a project hides, and why",
    "description": "The ignore rules this app applies to a project (its .gitignore, then its .deckignore, which can re-include). \"overview\": the rule files and how many rules. \"explain\": which rule hides `path`, including when a parent folder is what is hidden. \"filter\": which of `paths` are kept. `refresh` re-reads the rule files first, after one has been edited.",
    "index": "A project’s .gitignore/.deckignore rules, which rule hides a path, or which of some paths are kept.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "enum": [
            "overview",
            "explain",
            "filter"
          ]
        },
        "cwd": {
          "type": "string",
          "description": "An open project folder."
        },
        "path": {
          "type": "string",
          "description": "For \"explain\", relative to the project."
        },
        "isFolder": {
          "type": "boolean",
          "description": "For \"explain\": the path is a folder."
        },
        "paths": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "For \"filter\", relative paths."
        },
        "refresh": {
          "type": "boolean"
        }
      },
      "required": [
        "action",
        "cwd"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "files-tools",
    "id": "files.upload",
    "wire": "files_upload",
    "tier": "act",
    "title": "Put a file on this machine",
    "description": "Save a small file you hold — a screenshot, a log, a document — onto this machine, the way pasting an image into a session does, and get back the path it landed at. Then mention that path in sessions.send (e.g. @\"<path>\"), or bring it inside a held session with sessions.attach. Base64 content, at most 160 KB. It lands in this app’s uploads folder; a second file with the same name lands beside the first, never over it.",
    "index": "Send a small file (e.g. a screenshot) to this machine and get its path, to mention in a session.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "A file name, e.g. \"screenshot.png\". Only the last part is used."
        },
        "contentBase64": {
          "type": "string"
        }
      },
      "required": [
        "name",
        "contentBase64"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "files-tools",
    "id": "sessions.attach",
    "wire": "sessions_attach",
    "tier": "act",
    "title": "Give a session files from this machine",
    "description": "Get files from anywhere on this machine to a session, the way dropping them on it does. A session held inside a folder (one a phone started, for instance) cannot read outside it, so each file is COPIED into \"<its folder>/Terminal Deck/\" and the copy’s path is returned; an ordinary session reads the original, so nothing is copied. Either way the answer has a `mention` per file to put in sessions.send. Omit `paths` to just ask whether the session is held in a folder. Folders and credential files (keys, .env and the like) are not handed over.",
    "index": "Make files on this machine readable by a session — copied inside it if the session is held in a folder.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": {
          "type": "string"
        },
        "paths": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Absolute paths, up to 10."
        }
      },
      "required": [
        "sessionId"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "project-tools",
    "id": "projects.browse",
    "wire": "projects_browse",
    "tier": "read",
    "title": "Look for a folder to open",
    "description": "The folders inside one folder on this machine — the look-around a person does in the Open Project panel, without the panel. Starts at the home folder; pass `path` to go deeper. Folders only, and hidden ones only when asked. Each row says whether it is already an open project and whether it is a git repository. Then projects.add opens the one you want.",
    "index": "List the folders inside a folder on this machine (from home), to find one to open with projects.add.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "An absolute folder. Omit for the home folder."
        },
        "showHidden": {
          "type": "boolean",
          "description": "Include folders whose names start with a dot."
        }
      },
      "additionalProperties": false
    }
  },
  {
    "module": "project-tools",
    "id": "projects.add",
    "wire": "projects_add",
    "tier": "alter",
    "title": "Open a folder as a project",
    "description": "Open a folder as a project: it joins the sidebar, and sessions.start, git, files and the other tools may then name it. Find one with projects.browse. It is confirmed by the person, because the open projects are the boundary of which folders these tools may touch. Nothing is written into the folder.",
    "index": "Open a folder as a project so sessions can start in it. Confirmed — it widens what tools may name.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "An absolute folder on this machine."
        }
      },
      "required": [
        "path"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "project-tools",
    "id": "projects.remove",
    "wire": "projects_remove",
    "tier": "alter",
    "title": "Put a project away",
    "description": "Take a folder off the list of open projects, so the tools may no longer name it. Confirmed. Nothing in the folder is touched, and sessions already running there keep running — stop them with sessions.stop first if that is what is wanted.",
    "index": "Take a folder off the open projects. Confirmed. Sessions running in it keep running.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string"
        }
      },
      "required": [
        "path"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "project-tools",
    "id": "git.init",
    "wire": "git_init",
    "tier": "act",
    "title": "Make a project a git repository",
    "description": "Run `git init` in an open project that is not yet a repository — the Source control view’s Initialise button — and answer with the new status. A folder that is already a repository is left alone.",
    "index": "Turn an open project that is not a git repository into one (git init). Answers with its new status.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "cwd": {
          "type": "string"
        }
      },
      "required": [
        "cwd"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "project-tools",
    "id": "dev.servers",
    "wire": "dev_servers",
    "tier": "read",
    "title": "Dev servers",
    "description": "The dev servers of the open projects, as the Browser view’s panel shows them. \"list\": each project’s dev script and whether it is idle, starting, ready (with its URL) or failed. \"start\": run one project’s dev script in a new shell session and return at once with `starting` — list again to see it become ready, or read its session with sessions.screen. \"ports\": every local port something is listening on, and which program holds it.",
    "index": "Each open project’s dev server — list them, start one, or see what is listening on which port.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "enum": [
            "list",
            "start",
            "ports"
          ]
        },
        "cwd": {
          "type": "string",
          "description": "The project, for \"start\"."
        },
        "refresh": {
          "type": "boolean",
          "description": "For \"ports\": scan again instead of using the last few seconds’ answer."
        }
      },
      "required": [
        "action"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "project-tools",
    "id": "dashboard.layout",
    "wire": "dashboard_layout",
    "tier": "read",
    "title": "A project’s Overview arrangement",
    "description": "How a project’s Overview page is arranged — which tiles, where. \"read\" returns the saved arrangement (null means the default). \"save\" stores one you pass as `layout`, in the shape \"read\" returned. \"reset\" forgets it so the default comes back. The window applies a change the next time that Overview opens.",
    "index": "Read, save or reset how a project’s Overview tiles are arranged.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "enum": [
            "read",
            "save",
            "reset"
          ]
        },
        "cwd": {
          "type": "string",
          "description": "An open project folder."
        },
        "layout": {
          "type": "object",
          "description": "For \"save\": the arrangement, as \"read\" returned it."
        }
      },
      "required": [
        "action",
        "cwd"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "project-tools",
    "id": "artifacts.list",
    "wire": "artifacts_list",
    "tier": "read",
    "title": "What the agents made in a project",
    "description": "The Artifacts view: every file the agents in a project wrote or edited, read from their transcripts — when, how many times, by which conversation. Pass `path` (relative to the project) for that one file’s history: each write and edit, with what changed. `scope: \"all\"` includes conversations from every project that touched files here.",
    "index": "Every file agents wrote or edited in a project, from their transcripts — or one file’s history.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "cwd": {
          "type": "string",
          "description": "An open project folder."
        },
        "path": {
          "type": "string",
          "description": "One file, relative to the project, for its history."
        },
        "scope": {
          "type": "string",
          "enum": [
            "project",
            "all"
          ]
        },
        "limit": {
          "type": "integer",
          "description": "Files (or changes) to return. Default 50, max 300."
        }
      },
      "required": [
        "cwd"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "asset-tools",
    "id": "assets.rendition",
    "wire": "assets_rendition",
    "tier": "act",
    "title": "Find the biggest copy of an asset",
    "description": "Sites serve the same file at several sizes, usually one path segment or one query parameter apart. Give the URL the page printed and the rewrites worth trying, and this answers with the URL to actually fetch. Every candidate is probed; anything that 404s, answers with a page instead of a file, or comes back no bigger than the original is refused, and the original URL is always the last candidate and is always tried. A bad rewrite therefore costs you quality, never the asset. `attempts` says what was tried and why each one was refused.",
    "index": "Given the URL a page printed, probe rewrites to find the biggest copy of that image or file that really exists.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "The asset URL as the page gave it."
        },
        "rules": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": {
                "type": "string",
                "description": "What to record when this rule is the one that won."
              },
              "match": {
                "type": "string",
                "description": "A regular expression, tested against the whole URL."
              },
              "replace": {
                "type": "string",
                "description": "The replacement, with $1-style back-references."
              },
              "flags": {
                "type": "string",
                "description": "Regular-expression flags. Use g when the size appears twice."
              }
            },
            "required": [
              "id",
              "match",
              "replace"
            ],
            "additionalProperties": false
          },
          "description": "Rewrites to try, best first. Each is applied to the original URL; when there is more than one, all of them applied together is tried first as well."
        },
        "minBytes": {
          "type": "number",
          "description": "Refuse an upgrade smaller than this many bytes."
        },
        "requireLarger": {
          "type": "boolean",
          "description": "Probe the original too and refuse an upgrade that is not larger. Default true. Turning it off is how a server quietly re-serving the small copy gets recorded as an upgrade."
        },
        "profileId": {
          "type": "string",
          "description": "Probe from this browser profile’s cookie jar. Needed for anything behind a login."
        }
      },
      "required": [
        "url"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "asset-tools",
    "id": "assets.ledger",
    "wire": "assets_ledger",
    "tier": "read",
    "title": "Resume ledger, keyed on the bytes",
    "description": "Ask whether an asset is already downloaded, and write down the ones that are. `decide` says skip only when the file is still on disk, is the length recorded for it, and hashes to the digest recorded for it — a ledger keyed on the URL alone answers \"you asked for this once\", which is not the question during a re-download that is happening because the files were bad. `record` hashes the file itself; it never takes a digest from you. `mode: refetch` does not read the ledger at all. `verify` checks every recorded file and is what \"did this run work?\" means.",
    "index": "Ask whether an asset is already downloaded, intact and the right length, and record the ones that are. Resume or verify a download run.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "runId": {
          "type": "string",
          "description": "Names this run’s ledger. The same id resumes it."
        },
        "op": {
          "type": "string",
          "enum": [
            "decide",
            "record",
            "verify",
            "summary"
          ],
          "description": "decide: should this URL be fetched? record: write down one that was. verify: check every recorded file against its digest. summary: the counts so far."
        },
        "mode": {
          "type": "string",
          "enum": [
            "resume",
            "refetch"
          ],
          "description": "resume consults the ledger. refetch does not read it at all, for a deliberate re-download. Default resume."
        },
        "url": {
          "type": "string",
          "description": "For decide and record: the URL that was asked for."
        },
        "path": {
          "type": "string",
          "description": "For record: the absolute path the file was written to."
        },
        "fetchedUrl": {
          "type": "string",
          "description": "For record: what was actually fetched, if not url."
        },
        "ruleId": {
          "type": "string",
          "description": "For record: the rendition rule that won, if any."
        },
        "expectDigest": {
          "type": "string",
          "description": "For decide: what this run believes the file should hash to. A mismatch is a fetch even when the file on disk is internally consistent."
        }
      },
      "required": [
        "runId",
        "op"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "asset-tools",
    "id": "assets.coverage",
    "wire": "assets_coverage",
    "tier": "act",
    "title": "Compare what you captured against what the page says exists",
    "description": "Pages state their own totals — \"showing 12 of 340\". Give this the page text and how many items you actually got, and it says complete, short, over, or unknown, and writes the answer into the run so it can be read at the end. `unknown` — nothing on the page stated a total — is not success: it means this page cannot be called complete. Give `pattern` whenever you can; without one only generic shapes are tried and two that disagree deliberately produce no answer.",
    "index": "Compare how many items you captured against the total the page itself states, and record complete, short or unknown.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "runId": {
          "type": "string"
        },
        "op": {
          "type": "string",
          "enum": [
            "check",
            "summary"
          ],
          "description": "check: compare one page. summary: every check this run recorded. Default check."
        },
        "captured": {
          "type": "number",
          "description": "How many items this run actually got from the page."
        },
        "text": {
          "type": "string",
          "description": "Text from the page, from browser.read. The page’s own stated total is read out of this."
        },
        "pattern": {
          "type": "string",
          "description": "A regular expression whose first group is the stated total. Give one whenever you can — without it only generic shapes are tried, and two that disagree produce no answer at all."
        },
        "flags": {
          "type": "string"
        },
        "stated": {
          "type": "number",
          "description": "The total, when you already know it. Used instead of reading text."
        },
        "tolerance": {
          "type": "number",
          "description": "How many items short is still complete. Default 0."
        },
        "what": {
          "type": "string",
          "description": "What was being counted, for the record."
        },
        "pageUrl": {
          "type": "string",
          "description": "The page this is about, for the record."
        },
        "profileId": {
          "type": "string",
          "description": "Which browser profile this run belongs to. Its stored pattern is used when none is given."
        }
      },
      "required": [
        "runId"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "asset-tools",
    "id": "assets.fetch",
    "wire": "assets_fetch",
    "tier": "act",
    "title": "Fetch assets to disk, byte for byte",
    "description": "Downloads the assets you name into a folder, through the browser profile you name, so the cookies and the clearance are the ones this browser already has. The bytes on disk are exactly the bytes the server sent — nothing rewrites them, a body shorter than the length promised is thrown away, and no partial download is left under a real name. A rewrite rule is tried first and the original is always the last candidate and is always tried, so a bad rule costs quality and never the asset; the row says which URL produced the bytes. The ledger skips on the digest of the file on disk, never on the URL alone. Every asset comes back fetched, fell-back, skipped or failed, with a reason.",
    "index": "Download the assets you name, through a browser profile, byte for byte — with the rewrite rule, the ledger and the fallback all applied.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "runId": {
          "type": "string",
          "description": "Names this run’s ledger and folder. The same id resumes it."
        },
        "dir": {
          "type": "string",
          "description": "An absolute folder to write the files into. It is made if it is not there."
        },
        "urls": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "The asset URLs as the page gave them, best first. Each is fetched in turn; the orchestration of how many batches to run belongs outside this app."
        },
        "rules": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": {
                "type": "string",
                "description": "What to record when this rule is the one that won."
              },
              "match": {
                "type": "string",
                "description": "A regular expression, tested against the whole URL."
              },
              "replace": {
                "type": "string",
                "description": "The replacement, with $1-style back-references."
              },
              "flags": {
                "type": "string",
                "description": "Regular-expression flags. Use g when the size appears twice."
              }
            },
            "required": [
              "id",
              "match",
              "replace"
            ],
            "additionalProperties": false
          },
          "description": "Rewrites to try for a bigger copy. The upgraded URL is fetched first and the original is always the last candidate and is always tried, so a bad rule costs quality, never the asset."
        },
        "mode": {
          "type": "string",
          "enum": [
            "resume",
            "refetch"
          ],
          "description": "resume skips an asset only when the file is on disk, the right length, and hashes to the digest recorded for it. refetch does not read the ledger at all. Default resume."
        },
        "profileId": {
          "type": "string",
          "description": "Fetch from this browser profile’s cookie jar — the same jar the page and the probe use. Needed for anything behind a login or a signed cookie. Omit for a public CDN."
        },
        "minBytes": {
          "type": "number",
          "description": "Refuse anything smaller than this many bytes."
        },
        "requireLarger": {
          "type": "boolean",
          "description": "Probe the original too and refuse an upgrade that is not larger. Default true. Turning it off is how a server quietly re-serving the small copy gets recorded as an upgrade."
        }
      },
      "required": [
        "runId",
        "dir",
        "urls"
      ],
      "additionalProperties": false
    }
  },
  {
    "module": "asset-tools",
    "id": "assets.blocks",
    "wire": "assets_blocks",
    "tier": "read",
    "title": "The pages that refused us, with pictures",
    "description": "The browser photographs a page that blocks it at the moment it happens — a 403, a 429, a challenge, a navigation that ended somewhere unexpected — because by the time anything could be asked to take that picture the page has changed. This lists what it caught: the address, the status, which signal fired, and the path to the screenshot and to the evidence beside it.",
    "index": "The pages that refused this browser — a 403, a 429, a challenge — with the screenshot taken at the moment it happened.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "limit": {
          "type": "number",
          "description": "How many, newest first. Default 20."
        },
        "since": {
          "type": "number",
          "description": "Only blocks captured after this epoch millisecond."
        }
      },
      "additionalProperties": false
    }
  },
  {
    "module": "tour-tool",
    "id": "tour.play",
    "wire": "tour_play",
    "tier": "act",
    "title": "Drive the screen through what matters",
    "description": "Walk the person through what happened, on their own screen: for each stop the app navigates to the session, draws a box around the exact text you quoted and lays a field of dots over everything else, then moves straight on at machine speed. It does NOT pause for them to read — they watch it work, and the reading happens at the end, when you post the combined answer. You write the whole tour in one call and the app plays it — there is no second turn per stop, so everything you want shown has to be in this one plan. At most 12 stops; a longer plan is REFUSED rather than trimmed, and so is a quote over 600 characters or a note over 160. Put the actual answer in `headline` — it is posted to this chat before anything moves, so the person has it whether or not they watch. The tour is the evidence, not the answer. Every quote is checked against the real transcript or the real terminal before it is shown, and every `why` is re-checked against this app's own data; a stop that fails either is dropped and the drop is reported to the person. So quote exactly, and only claim what is true. Nothing in a tour types, sends, starts or stops anything, and while it is playing the tools that change things are refused — ask afterwards. Do not use this for one thing you could say in a sentence.",
    "index": "Drive the person's screen through what happened, quoting the real transcripts, as one plan of up to 12 stops.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "question": {
          "type": "string",
          "description": "What they asked, in their words. Kept in the record so the recap says what it answers."
        },
        "headline": {
          "type": "string",
          "description": "The answer, in prose. Posted to this chat before the first stop. Write it as if the tour will not be watched."
        },
        "start": {
          "type": "string",
          "enum": [
            "now",
            "offer"
          ],
          "description": "'now' plays it. 'offer' posts a notification and waits for a click — the only thing a routine with nobody at the machine may ask for."
        },
        "stops": {
          "type": "array",
          "maxItems": 12,
          "description": "In the order they should be seen. Worst first, as sessions.list already orders them.",
          "items": {
            "type": "object",
            "properties": {
              "kind": {
                "type": "string",
                "enum": [
                  "screen",
                  "anchor"
                ],
                "description": "'screen' points at a passage of terminal output, found by its text. 'anchor' points at a changed file or a session's usage reading, and carries no quote, because there is no source to check one against."
              },
              "sessionId": {
                "type": "string",
                "description": "The session this stop is about."
              },
              "quote": {
                "type": "string",
                "maxLength": 600,
                "description": "Verbatim, exactly as it appears. This is checked; text that is not really there means the stop is dropped."
              },
              "at": {
                "type": "string",
                "enum": [
                  "git-file",
                  "usage"
                ],
                "description": "Which place. 'git-file' is a changed file in Source control; 'usage' is the session's own usage reading — the stacked limit bars in the toolbar above it."
              },
              "path": {
                "type": "string",
                "description": "For a git-file anchor: the path git reports as changed."
              },
              "note": {
                "type": "string",
                "maxLength": 160,
                "description": "Your one line about why this matters. Not a restatement of the quote."
              },
              "why": {
                "type": "string",
                "enum": [
                  "blocked-on-you",
                  "failed",
                  "finished",
                  "looping",
                  "tool-failing",
                  "compacted",
                  "expensive",
                  "files-changed",
                  "question-asked",
                  "decision"
                ],
                "description": "The reason this app will check. Nine of these are looked up in data this app already holds. \"decision\" is the one that is not — you get at most one per session, and its quote still has to be real."
              }
            },
            "required": [
              "kind",
              "sessionId",
              "note",
              "why"
            ],
            "additionalProperties": false
          }
        }
      },
      "required": [
        "question",
        "headline",
        "stops"
      ],
      "additionalProperties": false
    }
  }
]
"""####
}
