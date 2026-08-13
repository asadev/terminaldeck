"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target2) => (target2 = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target2, "default", { value: mod, enumerable: true }) : target2,
  mod
));
const node_path = require("node:path");
const electron = require("electron");
const node_crypto = require("node:crypto");
const pty = require("node-pty");
const headless = require("@xterm/headless");
const node_child_process = require("node:child_process");
const node_util = require("node:util");
const node_fs = require("node:fs");
const chokidar = require("chokidar");
const promises = require("node:fs/promises");
const node_os = require("node:os");
const node_string_decoder = require("node:string_decoder");
const node_net = require("node:net");
const electronUpdater = require("electron-updater");
const node_http = require("node:http");
const node_tls = require("node:tls");
const index_js = require("@modelcontextprotocol/sdk/client/index.js");
const stdio_js = require("@modelcontextprotocol/sdk/client/stdio.js");
const types_js = require("@modelcontextprotocol/sdk/types.js");
function _interopNamespaceDefault(e) {
  const n = Object.create(null, { [Symbol.toStringTag]: { value: "Module" } });
  if (e) {
    for (const k in e) {
      if (k !== "default") {
        const d = Object.getOwnPropertyDescriptor(e, k);
        Object.defineProperty(n, k, d.get ? d : {
          enumerable: true,
          get: () => e[k]
        });
      }
    }
  }
  n.default = e;
  return Object.freeze(n);
}
const pty__namespace = /* @__PURE__ */ _interopNamespaceDefault(pty);
const BRAND = {
  /** Display name, shown in the UI and window title. */
  name: "Terminal Deck",
  /** Lowercase slug used for folders, npm name, CLI command. */
  id: "terminaldeck",
  /** Per-project config directory created inside a user's project. */
  projectConfigDir: ".terminaldeck",
  /** Env var injected into each spawned session. */
  sessionEnvVar: "TERMINALDECK_SESSION_ID",
  /** One-line description. */
  tagline: "Run your coding agents on one deck"
};
const KEEP = /* @__PURE__ */ new Set(["CLAUDE_CONFIG_DIR"]);
const STRIP = /^(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_AGENT_SDK_VERSION|CLAUDE_CODE_.*|CLAUDE_PREVIEW_.*)$/;
function stripInheritedSessionEnv(env, ownSessionVar) {
  const out = {};
  for (const [key, value] of Object.entries(env)) {
    if (value === void 0) continue;
    if (key === ownSessionVar) continue;
    if (KEEP.has(key)) {
      out[key] = value;
      continue;
    }
    if (STRIP.test(key)) continue;
    out[key] = value;
  }
  return out;
}
function currentPlatform() {
  return process.platform;
}
function isWindows(platform) {
  return platform === "win32";
}
function isPathKey(key, platform) {
  return isWindows(platform) ? key.toUpperCase() === "PATH" : key === "PATH";
}
function pathKey(env, platform) {
  if (!isWindows(platform)) return "PATH";
  const existing = Object.keys(env).find((key) => isPathKey(key, platform));
  return existing ?? "Path";
}
function envPath(env, platform) {
  const key = Object.keys(env).find((name) => isPathKey(name, platform));
  return (key === void 0 ? void 0 : env[key]) ?? "";
}
function withPath(env, value, platform) {
  const next = {};
  for (const [key, existing] of Object.entries(env)) {
    if (isPathKey(key, platform)) continue;
    next[key] = existing;
  }
  next[pathKey(env, platform)] = value;
  return next;
}
function stripAnsi(input) {
  return input.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "").replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "").replace(/\x1b[()#][0-9A-Za-z]/g, "").replace(/\x1b./g, "").replace(/\r/g, "\n");
}
const WORKING = [
  /esc to interrupt/i,
  /\btokens?\b.*\besc\b/i,
  /^\s*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/m,
  /thinking[.…]/i
];
const NEEDS_INPUT = [
  /\bdo you want\b/i,
  /\(y\/n\)/i,
  /\[y\/N\]/i,
  /\byes\b.*\bno\b.*\?\s*$/i,
  /^\s*❯?\s*\d+\.\s/m,
  /press enter to continue/i,
  /overwrite\?/i
];
const WAITING = [
  /^\s*❯\s*$/m,
  // Claude Code, empty prompt
  /^\s*│\s*>\s*│?\s*$/m,
  // boxed prompt styles
  /^\s*>\s*$/m,
  /^.*[%$#]\s*$/m
  // shell prompts
];
function matchesAny(patterns, text2) {
  return patterns.some((re) => re.test(text2));
}
function lastLines(text2, count) {
  const lines2 = text2.split("\n").filter((l) => l.trim() !== "");
  return lines2.slice(-count).join("\n");
}
function classify(tail, exited) {
  const text2 = stripAnsi(tail);
  if (matchesAny(WORKING, lastLines(text2, 12))) return "working";
  const recent = lastLines(text2, 6);
  if (matchesAny(WAITING, recent)) return "waiting";
  if (matchesAny(NEEDS_INPUT, lastLines(text2, 10))) return "input";
  return "idle";
}
const SETTLE_MS$1 = 700;
class ActivityTracker {
  constructor(id2, onChange, cols = 100, rows = 30) {
    this.id = id2;
    this.onChange = onChange;
    this.term = new headless.Terminal({ cols, rows, allowProposedApi: true, scrollback: 200 });
  }
  id;
  onChange;
  term;
  status = "idle";
  timer;
  exited = false;
  push(chunk) {
    if (this.exited) return;
    this.term.write(chunk);
    this.set("working");
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.term.write("", () => this.set(classify(this.visibleText())));
    }, SETTLE_MS$1);
  }
  resize(cols, rows) {
    try {
      this.term.resize(Math.max(cols, 1), Math.max(rows, 1));
    } catch {
    }
  }
  /**
   * The visible viewport, as the user sees it.
   *
   * Public because the status classifier is not the only thing that needs to
   * know what is on screen: the chat controls read the permission-mode footer
   * and the CLI's replies to slash commands from this same buffer. One shadow
   * terminal per session, read by everyone — a second one fed the same bytes
   * would drift the moment a resize was missed on one of them.
   */
  settledText() {
    return new Promise((resolve) => this.term.write("", () => resolve(this.visibleText())));
  }
  visibleText() {
    const buf = this.term.buffer.active;
    const lines2 = [];
    for (let y = 0; y < this.term.rows; y++) {
      const line = buf.getLine(buf.viewportY + y);
      if (line) lines2.push(line.translateToString(true));
    }
    return lines2.join("\n");
  }
  markExited() {
    this.exited = true;
    clearTimeout(this.timer);
    this.set("exited");
  }
  dispose() {
    clearTimeout(this.timer);
    this.term.dispose();
  }
  set(next) {
    if (next === this.status) return;
    this.status = next;
    this.onChange(this.id, next);
  }
}
const SCROLLBACK_LIMIT = 4e3;
class PtyManager {
  constructor(onData, onExit, onStatus) {
    this.onData = onData;
    this.onExit = onExit;
    this.onStatus = onStatus;
  }
  onData;
  onExit;
  onStatus;
  sessions = /* @__PURE__ */ new Map();
  create(input, spawnSpec) {
    const id2 = node_crypto.randomUUID();
    const meta = {
      id: id2,
      cwd: input.cwd,
      title: node_path.basename(input.cwd) || input.cwd,
      provider: spawnSpec.provider,
      exitCode: null,
      createdAt: Date.now(),
      // Read off the request rather than the spawn spec: `resumeArgs` is empty
      // for providers with no resume flag, so the spec cannot say whether the
      // user asked to continue — and a continued session writes into a
      // transcript older than itself, which is the one case where "started
      // before this tab did" stops meaning "not this tab's".
      resumed: input.resume === true
    };
    const proc = pty__namespace.spawn(spawnSpec.command, spawnSpec.args, {
      name: "xterm-256color",
      cols: input.cols,
      rows: input.rows,
      cwd: input.cwd,
      env: {
        // Not `process.env` directly: if this app was launched from inside an
        // agent session, its markers are in here and the CLI would treat the
        // new session as a child — which turns transcript saving off, and
        // chat mode and cost both read those transcripts.
        //
        // A GUI app inherits a minimal PATH; use the login shell's instead so
        // CLIs installed via nvm/Homebrew/~/.local/bin resolve. Written through
        // `withPath` rather than as a literal `PATH:` key — Windows spells the
        // variable `Path`, and a spread copy would hand the child both
        // spellings with no defined winner. `platform/host.ts` documents it.
        ...withPath(
          stripInheritedSessionEnv(process.env, BRAND.sessionEnvVar),
          spawnSpec.path,
          currentPlatform()
        ),
        // A profile redirects the agent's config dir, which is what actually
        // keeps two logins apart. Applied last so it wins.
        ...spawnSpec.env ?? {},
        [BRAND.sessionEnvVar]: id2,
        TERM: "xterm-256color",
        COLORTERM: "truecolor"
      }
    });
    const activity = new ActivityTracker(id2, this.onStatus, input.cols, input.rows);
    const session = { meta, proc, scrollback: [], activity };
    this.sessions.set(id2, session);
    proc.onData((data) => {
      session.scrollback.push(data);
      if (session.scrollback.length > SCROLLBACK_LIMIT) session.scrollback.shift();
      activity.push(data);
      this.onData(id2, data);
    });
    proc.onExit(({ exitCode }) => {
      session.meta.exitCode = exitCode;
      activity.markExited();
      this.onExit(id2, exitCode);
    });
    return meta;
  }
  write(id2, data) {
    this.sessions.get(id2)?.proc.write(data);
  }
  resize(id2, cols, rows) {
    const s = this.sessions.get(id2);
    if (!s || s.meta.exitCode !== null) return;
    s.activity.resize(cols, rows);
    try {
      s.proc.resize(Math.max(cols, 1), Math.max(rows, 1));
    } catch {
    }
  }
  /** Replay buffered output so a re-mounted terminal shows its history. */
  scrollback(id2) {
    return this.sessions.get(id2)?.scrollback.join("") ?? "";
  }
  /**
   * What the session is showing right now, or null when there is no such
   * session. Not the same thing as `scrollback`: agent CLIs repaint with cursor
   * moves, so the raw stream and the screen say different things, and every
   * question of the form "what state is the agent in?" needs the screen.
   */
  async screen(id2) {
    const session = this.sessions.get(id2);
    return session ? session.activity.settledText() : null;
  }
  kill(id2) {
    const s = this.sessions.get(id2);
    if (!s) return;
    s.activity.dispose();
    try {
      s.proc.kill();
    } catch {
    }
    this.sessions.delete(id2);
  }
  list() {
    return [...this.sessions.values()].map((s) => s.meta);
  }
  killAll() {
    for (const id2 of [...this.sessions.keys()]) this.kill(id2);
  }
}
function lookupSpec(platform, bin) {
  return isWindows(platform) ? { command: "where.exe", args: [bin] } : { command: "which", args: [bin] };
}
function firstLookupPath(stdout) {
  for (const line of stdout.split(/\r?\n/)) {
    const path = line.trim();
    if (path === "") continue;
    if (/^(INFO|ERROR):/i.test(path)) continue;
    return path;
  }
  return null;
}
function loginPathSpec(platform, env) {
  if (isWindows(platform)) return null;
  return { command: env.SHELL || "/bin/zsh", args: ["-lic", 'echo -n "$PATH"'] };
}
const run$a = node_util.promisify(node_child_process.execFile);
function providersFor(platform, env) {
  const windows = isWindows(platform);
  const launch = (bin, args, resumeArgs) => {
    if (!windows) return { command: bin, args, resumeArgs };
    const shell = env.COMSPEC || "cmd.exe";
    return {
      command: shell,
      args: ["/c", bin, ...args],
      resumeArgs: resumeArgs.length > 0 ? ["/c", bin, ...resumeArgs] : []
    };
  };
  const shellBin = windows ? env.COMSPEC || "cmd.exe" : env.SHELL || "/bin/zsh";
  const shellArgs = windows ? [] : ["-l"];
  return {
    // --continue verified against `claude --help` on this machine.
    claude: {
      id: "claude",
      label: "Claude Code",
      bin: "claude",
      args: [],
      resumeArgs: ["--continue"],
      spawn: launch("claude", [], ["--continue"])
    },
    // UNVERIFIED: codex/gemini --help block on stdin so the flags could not be
    // confirmed here. An empty resumeArgs simply starts a fresh session, so a
    // wrong guess would silently do the wrong thing — codex is left in because
    // `resume --last` is documented, gemini is left empty until confirmed.
    codex: {
      id: "codex",
      label: "Codex CLI",
      bin: "codex",
      args: [],
      resumeArgs: ["resume", "--last"],
      spawn: launch("codex", [], ["resume", "--last"])
    },
    gemini: {
      id: "gemini",
      label: "Gemini CLI",
      bin: "gemini",
      args: [],
      resumeArgs: [],
      spawn: launch("gemini", [], [])
    },
    shell: {
      id: "shell",
      label: "Shell",
      bin: shellBin,
      args: shellArgs,
      resumeArgs: [],
      // Already an executable path, so it needs no command-processor wrapper.
      spawn: { command: shellBin, args: shellArgs, resumeArgs: [] }
    }
  };
}
const PROVIDERS = providersFor(currentPlatform(), process.env);
let cachedPath = null;
async function loginPath(platform = currentPlatform()) {
  if (cachedPath) return cachedPath;
  const spec = loginPathSpec(platform, process.env);
  if (spec === null) {
    cachedPath = envPath(process.env, platform);
    return cachedPath;
  }
  try {
    const { stdout } = await run$a(spec.command, spec.args, { timeout: 5e3 });
    cachedPath = stdout.trim() || envPath(process.env, platform);
  } catch {
    cachedPath = envPath(process.env, platform);
  }
  return cachedPath;
}
async function detectProviders(platform = currentPlatform()) {
  const PATH = await loginPath(platform);
  const env = withPath(process.env, PATH, platform);
  const table = providersFor(platform, process.env);
  const found = {};
  await Promise.all(
    Object.keys(table).map(async (id2) => {
      if (id2 === "shell") {
        found[id2] = true;
        return;
      }
      const spec = lookupSpec(platform, table[id2].bin);
      try {
        const { stdout } = await run$a(spec.command, spec.args, { env, windowsHide: true });
        found[id2] = firstLookupPath(stdout) !== null;
      } catch {
        found[id2] = false;
      }
    })
  );
  return found;
}
const DEFAULTS = {
  version: 1,
  projects: [],
  preferences: {
    theme: "dark",
    defaultProvider: "claude",
    restoreSessions: true,
    notifyOnComplete: true
  }
};
class Store {
  file;
  state;
  constructor() {
    this.file = node_path.join(electron.app.getPath("userData"), "state.json");
    this.state = this.load();
  }
  load() {
    try {
      const raw = JSON.parse(node_fs.readFileSync(this.file, "utf8"));
      return {
        ...DEFAULTS,
        ...raw,
        preferences: { ...DEFAULTS.preferences, ...raw.preferences },
        projects: Array.isArray(raw.projects) ? raw.projects : []
      };
    } catch {
      return structuredClone(DEFAULTS);
    }
  }
  persist() {
    try {
      node_fs.mkdirSync(node_path.dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      node_fs.writeFileSync(tmp, JSON.stringify(this.state, null, 2), "utf8");
      node_fs.renameSync(tmp, this.file);
    } catch (err) {
      console.error("[store] failed to persist state:", err);
    }
  }
  getState() {
    return this.state;
  }
  getPreferences() {
    return this.state.preferences;
  }
  setPreferences(patch) {
    this.state.preferences = { ...this.state.preferences, ...patch };
    this.persist();
    return this.state.preferences;
  }
  getProjects() {
    return [...this.state.projects].sort((a, b) => b.lastOpenedAt - a.lastOpenedAt);
  }
  addProject(path) {
    const existing = this.state.projects.find((p) => p.path === path);
    if (existing) {
      existing.lastOpenedAt = Date.now();
      this.persist();
      return existing;
    }
    const project = { path, lastOpenedAt: Date.now() };
    this.state.projects.push(project);
    this.persist();
    return project;
  }
  removeProject(path) {
    this.state.projects = this.state.projects.filter((p) => p.path !== path);
    this.persist();
  }
  setWindowBounds(bounds) {
    this.state.windowBounds = bounds;
    this.persist();
  }
}
let instance$1 = null;
function store() {
  if (!instance$1) instance$1 = new Store();
  return instance$1;
}
const STATE = "state.json";
function pinUserData(app) {
  const fromName = app.getPath("userData");
  const pinned = node_path.join(node_path.dirname(fromName), BRAND.id);
  if (fromName === pinned) return;
  try {
    node_fs.mkdirSync(pinned, { recursive: true });
    if (!node_fs.existsSync(node_path.join(pinned, STATE)) && node_fs.existsSync(node_path.join(fromName, STATE))) {
      node_fs.copyFileSync(node_path.join(fromName, STATE), node_path.join(pinned, STATE));
    }
    app.setPath("userData", pinned);
  } catch {
  }
}
const MILLION = 1e6;
const CACHE_READ_MULTIPLIER = 0.1;
const CACHE_WRITE_5M_MULTIPLIER = 1.25;
const CACHE_WRITE_1H_MULTIPLIER = 2;
const SYNTHETIC_MODEL = "<synthetic>";
function emptyUsage() {
  return { input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0 };
}
function addUsage(a, b) {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
    cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
    cacheRead: a.cacheRead + b.cacheRead
  };
}
function sumUsage(items) {
  let total = emptyUsage();
  for (const item of items) total = addUsage(total, item);
  return total;
}
function promptTokens(usage) {
  return usage.input + usage.cacheWrite5m + usage.cacheWrite1h + usage.cacheRead;
}
function totalTokens(usage) {
  return promptTokens(usage) + usage.output;
}
function cacheHitRate(usage) {
  const prompt = promptTokens(usage);
  return prompt === 0 ? 0 : usage.cacheRead / prompt;
}
const MODELS = {
  "claude-fable-5": { input: 10, output: 50, contextWindow: 1e6 },
  "claude-mythos-5": { input: 10, output: 50, contextWindow: 1e6 },
  "claude-opus-5": {
    input: 5,
    output: 25,
    contextWindow: 1e6,
    fast: { input: 10, output: 50 }
  },
  "claude-opus-4-8": { input: 5, output: 25, contextWindow: 1e6 },
  "claude-opus-4-7": { input: 5, output: 25, contextWindow: 1e6 },
  "claude-opus-4-6": { input: 5, output: 25, contextWindow: 1e6 },
  "claude-opus-4-5": { input: 5, output: 25, contextWindow: 2e5, legacy: true },
  "claude-sonnet-5": {
    input: 3,
    output: 15,
    contextWindow: 1e6,
    // Introductory pricing, ends 2026-08-31 inclusive.
    intro: { input: 2, output: 10, until: Date.UTC(2026, 8, 1) }
  },
  "claude-sonnet-4-6": { input: 3, output: 15, contextWindow: 1e6 },
  "claude-sonnet-4-5": { input: 3, output: 15, contextWindow: 2e5, legacy: true },
  "claude-haiku-4-5": { input: 1, output: 5, contextWindow: 2e5 },
  // Retired or deprecated, historical list prices only.
  "claude-opus-4-1": { input: 15, output: 75, contextWindow: 2e5, legacy: true },
  "claude-opus-4-0": { input: 15, output: 75, contextWindow: 2e5, legacy: true },
  "claude-sonnet-4-0": { input: 3, output: 15, contextWindow: 2e5, legacy: true },
  "claude-3-5-haiku": { input: 0.8, output: 4, contextWindow: 2e5, legacy: true },
  "claude-3-haiku": { input: 0.25, output: 1.25, contextWindow: 2e5, legacy: true },
  "claude-3-opus": { input: 15, output: 75, contextWindow: 2e5, legacy: true }
};
const DEFAULT_CONTEXT_WINDOW = 2e5;
function normalizeModelId(model) {
  return model.trim().toLowerCase().replace(/^(?:us|eu|apac|global)\./, "").replace(/^anthropic\./, "").replace(/\[1m\]$/, "").replace(/@\d{8}$/, "").replace(/-v\d+:\d+$/, "").replace(/-\d{8}$/, "");
}
function isBillableModel(model) {
  const id2 = normalizeModelId(model);
  return id2 !== "" && id2 !== SYNTHETIC_MODEL;
}
function splitSpeed(id2) {
  return id2.endsWith("-fast") ? { id: id2.slice(0, -"-fast".length), fast: true } : { id: id2, fast: false };
}
function priceFor(model, opts = {}) {
  const { id: id2, fast: fastSuffix } = splitSpeed(normalizeModelId(model));
  const entry = MODELS[id2];
  if (!entry) return null;
  const at = opts.at ?? Date.now();
  let { input, output } = entry;
  if (entry.intro && at < entry.intro.until) {
    input = entry.intro.input;
    output = entry.intro.output;
  }
  if ((opts.speed === "fast" || fastSuffix) && entry.fast) {
    input = entry.fast.input;
    output = entry.fast.output;
  }
  return {
    model: id2,
    input,
    output,
    cacheWrite5m: input * CACHE_WRITE_5M_MULTIPLIER,
    cacheWrite1h: input * CACHE_WRITE_1H_MULTIPLIER,
    cacheRead: input * CACHE_READ_MULTIPLIER,
    contextWindow: entry.contextWindow,
    legacy: entry.legacy ?? false
  };
}
function emptyCost() {
  return { input: 0, output: 0, cacheWrite: 0, cacheRead: 0, total: 0 };
}
function costOf$1(usage, model, opts = {}) {
  const price = priceFor(model, opts);
  if (!price) return null;
  const input = usage.input * price.input / MILLION;
  const output = usage.output * price.output / MILLION;
  const cacheWrite = (usage.cacheWrite5m * price.cacheWrite5m + usage.cacheWrite1h * price.cacheWrite1h) / MILLION;
  const cacheRead = usage.cacheRead * price.cacheRead / MILLION;
  return { input, output, cacheWrite, cacheRead, total: input + output + cacheWrite + cacheRead };
}
function addCost(a, b) {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cacheWrite: a.cacheWrite + b.cacheWrite,
    cacheRead: a.cacheRead + b.cacheRead,
    total: a.total + b.total
  };
}
function aggregateCost(byModel, opts = {}) {
  const result = {
    cost: emptyCost(),
    byModel: {},
    unpricedModels: [],
    usedLegacyRate: false
  };
  for (const [model, usage] of byModel) {
    if (!isBillableModel(model)) continue;
    const cost = costOf$1(usage, model, opts);
    if (!cost) {
      const id22 = normalizeModelId(model);
      if (!result.unpricedModels.includes(id22)) result.unpricedModels.push(id22);
      continue;
    }
    const id2 = normalizeModelId(model);
    result.byModel[id2] = result.byModel[id2] ? addCost(result.byModel[id2], cost) : cost;
    result.cost = addCost(result.cost, cost);
    if (priceFor(model, opts)?.legacy) result.usedLegacyRate = true;
  }
  result.unpricedModels.sort();
  return result;
}
function mergeAggregates(parts) {
  const merged = {
    cost: emptyCost(),
    byModel: {},
    unpricedModels: [],
    usedLegacyRate: false
  };
  const unpriced = /* @__PURE__ */ new Set();
  for (const part of parts) {
    merged.cost = addCost(merged.cost, part.cost);
    for (const [model, cost] of Object.entries(part.byModel)) {
      merged.byModel[model] = merged.byModel[model] ? addCost(merged.byModel[model], cost) : cost;
    }
    for (const model of part.unpricedModels) unpriced.add(model);
    if (part.usedLegacyRate) merged.usedLegacyRate = true;
  }
  merged.unpricedModels = [...unpriced].sort();
  return merged;
}
const CONTEXT_WARNING_PERCENT = 70;
const CONTEXT_CRITICAL_PERCENT = 90;
const PRE_CONTEXT_BLOAT_PERCENT = 15;
function contextWindowFor(model) {
  return priceFor(model)?.contextWindow ?? DEFAULT_CONTEXT_WINDOW;
}
const WINDOW_TIERS = [2e5, 1e6];
function effectiveContextWindow(modelWindow, observedPromptTokens) {
  if (observedPromptTokens <= modelWindow) return modelWindow;
  return WINDOW_TIERS.find((tier) => tier >= observedPromptTokens) ?? observedPromptTokens;
}
function contextLevel(percent) {
  if (percent >= CONTEXT_CRITICAL_PERCENT) return "critical";
  if (percent >= CONTEXT_WARNING_PERCENT) return "warning";
  return "ok";
}
function contextUsage(latestPromptTokens, model, windowOverride) {
  const window = windowOverride && windowOverride > 0 ? windowOverride : contextWindowFor(model);
  const tokens = Math.max(0, latestPromptTokens);
  const percent = window > 0 ? tokens / window * 100 : 0;
  return {
    tokens,
    window,
    percent,
    remaining: Math.max(0, window - tokens),
    level: contextLevel(percent)
  };
}
function contextWarning(usage) {
  if (usage.level === "ok") return null;
  const pct = Math.round(usage.percent);
  return {
    kind: "context-window",
    level: usage.level,
    percent: usage.percent,
    message: usage.level === "critical" ? `Context ${pct}% full — compaction is imminent, and quality drops before it lands.` : `Context ${pct}% full.`
  };
}
function preContextWarning(preContextTokens, window) {
  if (window <= 0 || preContextTokens <= 0) return null;
  const percent = preContextTokens / window * 100;
  if (percent < PRE_CONTEXT_BLOAT_PERCENT) return null;
  return {
    kind: "pre-context",
    level: percent >= PRE_CONTEXT_BLOAT_PERCENT * 2 ? "critical" : "warning",
    percent,
    message: `Pre-context is ${Math.round(percent)}% of the window (${formatTokens(
      preContextTokens
    )} tokens) before the conversation starts — check CLAUDE.md and MCP tool schemas.`
  };
}
function formatUsd(usd) {
  const abs = Math.abs(usd);
  if (abs === 0) return "$0.00";
  if (abs < 0.01) return `$${usd.toFixed(4)}`;
  if (abs < 10) return `$${usd.toFixed(3)}`;
  return `$${usd.toFixed(2)}`;
}
const K_ROUNDS_TO_MILLION = 999950;
function formatTokens(tokens) {
  const abs = Math.abs(tokens);
  if (abs >= K_ROUNDS_TO_MILLION) return `${(tokens / MILLION).toFixed(2).replace(/\.?0+$/, "")}M`;
  if (abs >= 1e3) return `${(tokens / 1e3).toFixed(1).replace(/\.0$/, "")}k`;
  return String(Math.round(tokens));
}
function encodeProjectPath(cwd) {
  return node_path.resolve(cwd).replace(/[^a-zA-Z0-9]/g, "-");
}
function claudeConfigDir() {
  const override = process.env.CLAUDE_CONFIG_DIR?.trim();
  return override && override.length > 0 ? override : node_path.join(node_os.homedir(), ".claude");
}
function transcriptDir(cwd, configDir = claudeConfigDir()) {
  return node_path.join(configDir, "projects", encodeProjectPath(cwd));
}
async function listTranscripts(dir) {
  let names;
  try {
    names = await promises.readdir(dir);
  } catch {
    return [];
  }
  const files = [];
  for (const name of names) {
    if (node_path.extname(name) !== ".jsonl") continue;
    const path = node_path.join(dir, name);
    try {
      const info = await promises.stat(path);
      if (!info.isFile()) continue;
      const born = info.birthtimeMs;
      files.push({
        path,
        sessionId: node_path.basename(name, ".jsonl"),
        createdAt: born > 0 && born <= info.mtimeMs ? born : info.mtimeMs,
        modifiedAt: info.mtimeMs,
        bytes: info.size
      });
    } catch {
    }
  }
  return files.sort((a, b) => b.modifiedAt - a.modifiedAt);
}
async function newestTranscript(dir) {
  const files = await listTranscripts(dir);
  return files[0] ?? null;
}
function isRecord$b(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function num$1(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}
function str$4(value) {
  return typeof value === "string" && value.length > 0 ? value : void 0;
}
function parseUsage(raw) {
  if (!isRecord$b(raw)) return null;
  const declaredWrite = num$1(raw.cache_creation_input_tokens);
  const detail = isRecord$b(raw.cache_creation) ? raw.cache_creation : void 0;
  const write5m = detail ? num$1(detail.ephemeral_5m_input_tokens) : 0;
  const write1h = detail ? num$1(detail.ephemeral_1h_input_tokens) : 0;
  const unattributed = Math.max(0, declaredWrite - write5m - write1h);
  return {
    input: num$1(raw.input_tokens),
    output: num$1(raw.output_tokens),
    cacheWrite5m: write5m + unattributed,
    cacheWrite1h: write1h,
    cacheRead: num$1(raw.cache_read_input_tokens)
  };
}
function parseEventLine(line) {
  const trimmed = line.trim();
  if (trimmed.length === 0) return null;
  let raw;
  try {
    raw = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (!isRecord$b(raw)) return null;
  const type = str$4(raw.type);
  if (!type) return null;
  const event = {
    type,
    uuid: str$4(raw.uuid),
    requestId: str$4(raw.requestId),
    timestamp: typeof raw.timestamp === "string" ? Date.parse(raw.timestamp) || 0 : 0,
    sessionId: str$4(raw.sessionId),
    cwd: str$4(raw.cwd),
    isSidechain: raw.isSidechain === true
  };
  if (type === "system" && str$4(raw.subtype) === "compact_boundary") {
    const meta = isRecord$b(raw.compactMetadata) ? raw.compactMetadata : void 0;
    event.compactedFrom = meta ? num$1(meta.preTokens) : 0;
    return event;
  }
  if (type !== "assistant" || !isRecord$b(raw.message)) return null;
  const message = raw.message;
  const usage = parseUsage(message.usage);
  if (!usage) return null;
  event.messageId = str$4(message.id);
  event.model = str$4(message.model);
  event.usage = usage;
  if (isRecord$b(message.usage) && str$4(message.usage.speed) === "fast") event.speed = "fast";
  return event;
}
function mayCarryCost(line) {
  return line.includes('"usage"') || line.includes("compact_boundary");
}
const CHUNK_BYTES$3 = 4 * 1024 * 1024;
const MAX_LINE_BYTES$3 = 8 * 1024 * 1024;
class TranscriptTail {
  constructor(path) {
    this.path = path;
  }
  path;
  offset = 0;
  partial = "";
  decoder = new node_string_decoder.StringDecoder("utf8");
  /** Bytes consumed so far. */
  get position() {
    return this.offset;
  }
  rewind() {
    this.offset = 0;
    this.partial = "";
    this.decoder = new node_string_decoder.StringDecoder("utf8");
  }
  async read() {
    let size;
    try {
      size = (await promises.stat(this.path)).size;
    } catch {
      return { events: [], reset: false, more: false };
    }
    let reset = false;
    if (size < this.offset) {
      this.rewind();
      reset = true;
    }
    if (size === this.offset) return { events: [], reset, more: false };
    const length = Math.min(CHUNK_BYTES$3, size - this.offset);
    const buffer = Buffer.allocUnsafe(length);
    const handle2 = await promises.open(this.path, "r");
    try {
      const { bytesRead } = await handle2.read(buffer, 0, length, this.offset);
      if (bytesRead === 0) return { events: [], reset, more: false };
      this.offset += bytesRead;
      const text2 = this.partial + this.decoder.write(buffer.subarray(0, bytesRead));
      const lines2 = text2.split("\n");
      this.partial = lines2.pop() ?? "";
      if (this.partial.length > MAX_LINE_BYTES$3) this.partial = "";
      const events = [];
      for (const line of lines2) {
        if (!mayCarryCost(line)) continue;
        const event = parseEventLine(line);
        if (event) events.push(event);
      }
      return { events, reset, more: this.offset < size };
    } finally {
      await handle2.close();
    }
  }
}
const UNKNOWN_MODEL = "unknown";
function rateKey$1(normalizedModel, speed) {
  if (speed !== "fast" || normalizedModel.endsWith("-fast")) return normalizedModel;
  return `${normalizedModel}-fast`;
}
class SessionAggregator {
  constructor(transcriptPath, sessionId = node_path.basename(transcriptPath, ".jsonl")) {
    this.transcriptPath = transcriptPath;
    this.sessionId = sessionId;
  }
  transcriptPath;
  seen = /* @__PURE__ */ new Set();
  byModel = /* @__PURE__ */ new Map();
  requests = 0;
  sidechainRequests = 0;
  compactions = 0;
  firstPromptTokens = 0;
  lastPromptTokens = 0;
  /** Model of the most recent *main-thread* request — the one holding the window. */
  lastMainModel = "";
  /** Model of the most recent request of any kind, used only as a fallback. */
  lastAnyModel = "";
  maxPromptTokens = 0;
  startedAt = 0;
  lastActivityAt = 0;
  sessionId;
  cwd = "";
  /**
   * Add one event. Returns true when it changed the totals.
   *
   * The deduplication is the load-bearing part. A single API request produces
   * one JSONL line per content block — a thinking block, a text block and two
   * tool calls come out as four `assistant` lines — and **every one of them
   * repeats the same `usage` object verbatim**. Verified across 133 real
   * transcripts: 2,801 multi-line requests, all with byte-identical usage, up
   * to 19 lines for one request. Summing per line rather than per request
   * inflates the bill by ~2.7x on average.
   */
  add(event) {
    if (event.sessionId && !this.sessionId) this.sessionId = event.sessionId;
    if (event.cwd && !this.cwd) this.cwd = event.cwd;
    if (event.timestamp > 0) {
      if (this.startedAt === 0) this.startedAt = event.timestamp;
      if (event.timestamp > this.lastActivityAt) this.lastActivityAt = event.timestamp;
    }
    if (event.compactedFrom !== void 0) {
      this.compactions += 1;
      if (event.compactedFrom > this.maxPromptTokens) this.maxPromptTokens = event.compactedFrom;
      return true;
    }
    if (!event.usage) return false;
    const key = event.messageId ?? event.requestId ?? event.uuid;
    if (key) {
      if (this.seen.has(key)) return false;
      this.seen.add(key);
    }
    const model = event.model ?? "";
    const prompt = promptTokens(event.usage);
    this.requests += 1;
    if (event.isSidechain) this.sidechainRequests += 1;
    if (!isBillableModel(model) && normalizeModelId(model) === "" && totalTokens(event.usage) > 0) {
      this.byModel.set(
        UNKNOWN_MODEL,
        addUsage(this.byModel.get(UNKNOWN_MODEL) ?? emptyUsage(), event.usage)
      );
    }
    if (isBillableModel(model)) {
      const id2 = rateKey$1(normalizeModelId(model), event.speed);
      this.byModel.set(id2, addUsage(this.byModel.get(id2) ?? emptyUsage(), event.usage));
      this.lastAnyModel = id2;
      if (!event.isSidechain) this.lastMainModel = id2;
    }
    if (prompt > 0) {
      if (!event.isSidechain) {
        if (this.firstPromptTokens === 0) this.firstPromptTokens = prompt;
        this.lastPromptTokens = prompt;
        if (prompt > this.maxPromptTokens) this.maxPromptTokens = prompt;
      }
    }
    return true;
  }
  /** Epoch ms of the last event seen. Cheap enough to sort a watcher's files by. */
  get activityAt() {
    return this.lastActivityAt;
  }
  /** Discard everything — used when a tail reports the file was replaced. */
  reset() {
    this.seen.clear();
    this.byModel.clear();
    this.requests = 0;
    this.sidechainRequests = 0;
    this.compactions = 0;
    this.firstPromptTokens = 0;
    this.lastPromptTokens = 0;
    this.lastMainModel = "";
    this.lastAnyModel = "";
    this.maxPromptTokens = 0;
    this.startedAt = 0;
    this.lastActivityAt = 0;
  }
  get isEmpty() {
    return this.requests === 0;
  }
  summary(at = Date.now()) {
    const usageByModel = {};
    for (const [model, usage] of this.byModel) usageByModel[model] = usage;
    const models = [...this.byModel.entries()].sort((a, b) => promptTokens(b[1]) + b[1].output - (promptTokens(a[1]) + a[1].output)).map(([model]) => model);
    const pricedAt = this.lastActivityAt > 0 ? this.lastActivityAt : at;
    const cost = aggregateCost(this.byModel, { at: pricedAt });
    const contextModel = this.lastMainModel || this.lastAnyModel || models[0] || "";
    const window = effectiveContextWindow(contextWindowFor(contextModel), this.maxPromptTokens);
    const context = this.lastPromptTokens > 0 ? contextUsage(this.lastPromptTokens, contextModel, window) : null;
    const warnings = [];
    if (context) {
      const live = contextWarning(context);
      if (live) warnings.push(live);
    }
    const prefix = preContextWarning(this.firstPromptTokens, window);
    if (prefix) warnings.push(prefix);
    return {
      sessionId: this.sessionId,
      transcriptPath: this.transcriptPath,
      cwd: this.cwd,
      models,
      requests: this.requests,
      usage: sumUsage(this.byModel.values()),
      usageByModel,
      cost,
      context,
      warnings,
      preContextTokens: this.firstPromptTokens,
      compactions: this.compactions,
      sidechainRequests: this.sidechainRequests,
      startedAt: this.startedAt,
      lastActivityAt: this.lastActivityAt
    };
  }
}
async function readTranscript(path) {
  const tail = new TranscriptTail(path);
  const aggregator = new SessionAggregator(path);
  for (; ; ) {
    const { events, reset, more } = await tail.read();
    if (reset) aggregator.reset();
    for (const event of events) aggregator.add(event);
    if (!more) break;
  }
  return aggregator.summary();
}
const DEFAULT_DEBOUNCE_MS = 300;
const DEFAULT_MAX_AGE_MS$1 = 90 * 24 * 60 * 60 * 1e3;
const DEFAULT_MAX_SESSIONS$1 = 40;
class TranscriptWatcher {
  constructor(options) {
    this.options = options;
    this.dir = transcriptDir(options.cwd, options.configDir);
  }
  options;
  dir;
  tails = /* @__PURE__ */ new Map();
  aggregators = /* @__PURE__ */ new Map();
  queue = /* @__PURE__ */ new Set();
  watcher = null;
  timer;
  draining = false;
  scanning = true;
  stopped = false;
  get directory() {
    return this.dir;
  }
  async start() {
    const maxAge = this.options.maxAgeMs ?? DEFAULT_MAX_AGE_MS$1;
    const maxSessions = this.options.maxSessions ?? DEFAULT_MAX_SESSIONS$1;
    const cutoff = maxAge > 0 ? Date.now() - maxAge : 0;
    const files = (await listTranscripts(this.dir)).filter((file) => file.modifiedAt >= cutoff).slice(0, maxSessions);
    for (const file of files) this.queue.add(file.path);
    this.watcher = chokidar.watch(this.dir, {
      ignoreInitial: true,
      depth: 0,
      persistent: true
    });
    this.watcher.on("add", (path) => this.enqueue(path));
    this.watcher.on("change", (path) => this.enqueue(path));
    this.watcher.on("unlink", (path) => this.forget(path));
    this.watcher.on(
      "error",
      (err) => console.error("[transcript] watch failed:", this.dir, err)
    );
    await this.drain();
    this.scanning = false;
    this.emit();
  }
  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    void this.watcher?.close();
    this.watcher = null;
  }
  /** Current numbers without waiting for the next change. */
  summary() {
    const sessions2 = [...this.aggregators.values()].filter((agg) => !agg.isEmpty).map((agg) => agg.summary()).sort((a, b) => b.lastActivityAt - a.lastActivityAt);
    const byModel = /* @__PURE__ */ new Map();
    let requests = 0;
    for (const session of sessions2) {
      requests += session.requests;
      for (const [model, usage] of Object.entries(session.usageByModel)) {
        byModel.set(model, addUsage(byModel.get(model) ?? emptyUsage(), usage));
      }
    }
    return {
      cwd: this.options.cwd,
      transcriptDir: this.dir,
      sessions: sessions2,
      usage: sumUsage(byModel.values()),
      // Add the sessions' money rather than re-pricing their pooled tokens:
      // each session is already priced against when it ran.
      cost: mergeAggregates(sessions2.map((session) => session.cost)),
      requests,
      activeSessionId: sessions2[0]?.sessionId ?? null,
      scanning: this.scanning,
      updatedAt: Date.now()
    };
  }
  enqueue(path) {
    if (this.stopped || node_path.extname(path) !== ".jsonl") return;
    this.queue.add(path);
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      void this.drain().then(() => this.emit());
    }, this.options.debounceMs ?? DEFAULT_DEBOUNCE_MS);
  }
  forget(path) {
    this.tails.delete(path);
    this.aggregators.delete(path);
    this.emit();
  }
  /** Process every queued file to EOF, one at a time so memory stays bounded. */
  async drain() {
    if (this.draining) return;
    this.draining = true;
    try {
      while (this.queue.size > 0 && !this.stopped) {
        const path = this.queue.values().next().value;
        this.queue.delete(path);
        try {
          await this.consume(path);
        } catch (err) {
          console.error("[transcript] failed to read", path, err);
          continue;
        }
        if (this.scanning) this.emit();
      }
      this.prune();
    } finally {
      this.draining = false;
    }
  }
  /**
   * Keep at most `maxSessions` transcripts resident.
   *
   * The cap was only ever applied to the initial scan, so a watcher left
   * running on a busy project grew a tail and an aggregator — each holding a
   * dedup set of every request id it ever saw — for every new session forever.
   * Oldest activity is dropped first; if that file is appended to again it is
   * simply re-read from the start.
   */
  prune() {
    const max = this.options.maxSessions ?? DEFAULT_MAX_SESSIONS$1;
    if (max <= 0 || this.aggregators.size <= max) return;
    const stale = [...this.aggregators.entries()].sort((a, b) => b[1].activityAt - a[1].activityAt).slice(max);
    for (const [path] of stale) {
      this.aggregators.delete(path);
      this.tails.delete(path);
    }
  }
  async consume(path) {
    let tail = this.tails.get(path);
    if (!tail) {
      tail = new TranscriptTail(path);
      this.tails.set(path, tail);
    }
    let aggregator = this.aggregators.get(path);
    if (!aggregator) {
      aggregator = new SessionAggregator(path);
      this.aggregators.set(path, aggregator);
    }
    for (; ; ) {
      const { events, reset, more } = await tail.read();
      if (reset) aggregator.reset();
      for (const event of events) aggregator.add(event);
      if (!more || this.stopped) break;
    }
  }
  emit() {
    if (this.stopped) return;
    this.options.onUpdate(this.summary());
  }
}
const COST_UPDATE_CHANNEL = "cost:update";
const entries$1 = /* @__PURE__ */ new Map();
function projectKey(cwd) {
  if (typeof cwd !== "string" || cwd.trim().length === 0) {
    throw new Error("cost: a project path is required");
  }
  return node_path.resolve(cwd);
}
function assertTranscriptPath$2(path) {
  if (typeof path !== "string" || path.length === 0) {
    throw new Error("cost: a transcript path is required");
  }
  const resolved = node_path.resolve(path);
  const root = node_path.resolve(claudeConfigDir(), "projects");
  if (!resolved.startsWith(root + node_path.sep) || node_path.extname(resolved) !== ".jsonl") {
    throw new Error(`cost: refusing to read outside the transcript store: ${path}`);
  }
  return resolved;
}
function broadcast$2(entry, summary) {
  for (const contents of entry.subscribers) {
    if (contents.isDestroyed()) {
      entry.subscribers.delete(contents);
      continue;
    }
    try {
      contents.send(COST_UPDATE_CHANNEL, summary);
    } catch (err) {
      entry.subscribers.delete(contents);
      console.error("[cost] dropping a dead subscriber:", err);
    }
  }
}
function ensureWatcher(cwd) {
  const existing = entries$1.get(cwd);
  if (existing) return existing;
  const entry = {
    watcher: new TranscriptWatcher({
      cwd,
      onUpdate: (summary) => broadcast$2(entry, summary)
    }),
    subscribers: /* @__PURE__ */ new Set(),
    // Replaced immediately below — `start()` can only be called once `entry`
    // exists, because its updates route through the subscriber set.
    started: Promise.resolve()
  };
  entry.started = entry.watcher.start().catch((err) => {
    console.error("[cost] watcher failed to start for", cwd, err);
  });
  entries$1.set(cwd, entry);
  return entry;
}
function release$1(cwd, contents) {
  const entry = entries$1.get(cwd);
  if (!entry) return;
  entry.subscribers.delete(contents);
  if (entry.subscribers.size === 0) {
    entry.watcher.stop();
    entries$1.delete(cwd);
  }
}
function releaseAll$1(contents) {
  for (const cwd of [...entries$1.keys()]) release$1(cwd, contents);
}
function registerCostIpc(ipcMain) {
  ipcMain.handle("cost:project", async (_e, cwd) => {
    const key = projectKey(cwd);
    const entry = entries$1.get(key);
    if (entry) {
      await entry.started;
      return entry.watcher.summary();
    }
    const cutoff = Date.now() - DEFAULT_MAX_AGE_MS$1;
    const files = (await listTranscripts(transcriptDir(key))).filter((file) => file.modifiedAt >= cutoff).slice(0, DEFAULT_MAX_SESSIONS$1);
    const summaries = [];
    for (const file of files) {
      summaries.push(await readTranscript(file.path));
    }
    return summarizeStandalone(key, summaries);
  });
  ipcMain.handle(
    "cost:session",
    (_e, transcriptPath) => readTranscript(assertTranscriptPath$2(transcriptPath))
  );
  ipcMain.handle(
    "cost:sessions",
    (_e, cwd) => listTranscripts(transcriptDir(projectKey(cwd)))
  );
  ipcMain.handle("cost:watch", async (event, cwd) => {
    const entry = ensureWatcher(projectKey(cwd));
    const contents = event.sender;
    if (!entry.subscribers.has(contents)) {
      entry.subscribers.add(contents);
      contents.once("destroyed", () => releaseAll$1(contents));
    }
    await entry.started;
    return entry.watcher.summary();
  });
  ipcMain.handle("cost:unwatch", (event, cwd) => {
    release$1(projectKey(cwd), event.sender);
  });
  ipcMain.handle(
    "cost:pricing",
    (_e, model) => priceFor(model)
  );
  ipcMain.handle(
    "cost:format",
    (_e, value) => ({
      usd: typeof value.usd === "number" ? formatUsd(value.usd) : void 0,
      tokens: typeof value.tokens === "number" ? formatTokens(value.tokens) : void 0
    })
  );
}
function summarizeStandalone(cwd, sessions2) {
  const ordered = [...sessions2].filter((session) => session.requests > 0).sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  const byModel = /* @__PURE__ */ new Map();
  let requests = 0;
  for (const session of ordered) {
    requests += session.requests;
    for (const [model, usage] of Object.entries(session.usageByModel)) {
      byModel.set(model, addUsage(byModel.get(model) ?? emptyUsage(), usage));
    }
  }
  return {
    cwd,
    transcriptDir: transcriptDir(cwd),
    sessions: ordered,
    usage: sumUsage(byModel.values()),
    // Sum the sessions' already-priced money — re-pricing the pooled tokens
    // would value historical work at today's rates.
    cost: mergeAggregates(ordered.map((session) => session.cost)),
    requests,
    activeSessionId: ordered[0]?.sessionId ?? null,
    scanning: false,
    updatedAt: Date.now()
  };
}
const run$9 = node_util.promisify(node_child_process.execFile);
const KIND_BY_CODE = {
  A: "added",
  M: "modified",
  D: "deleted",
  R: "renamed",
  C: "copied",
  T: "typechange",
  U: "conflicted",
  "?": "untracked"
};
function emptyBranch() {
  return { name: null, detached: false, oid: null, upstream: null, ahead: 0, behind: 0 };
}
function makeFile(path, group, code, origPath = null, score = null) {
  return {
    path,
    origPath,
    group,
    code,
    kind: group === "conflicted" ? "conflicted" : KIND_BY_CODE[code] ?? "unknown",
    score,
    insertions: null,
    deletions: null,
    binary: false
  };
}
function applyHeader(record2, branch) {
  const parts = record2.split(" ");
  const value = parts.slice(2).join(" ");
  switch (parts[1]) {
    case "branch.oid":
      branch.oid = value === "(initial)" ? null : value;
      break;
    case "branch.head":
      branch.detached = value === "(detached)";
      branch.name = branch.detached ? null : value;
      break;
    case "branch.upstream":
      branch.upstream = value;
      break;
    case "branch.ab": {
      const match = /^\+(\d+) -(\d+)$/.exec(value);
      if (match) {
        branch.ahead = Number(match[1]);
        branch.behind = Number(match[2]);
      }
      break;
    }
  }
}
function parsePorcelainV2(output) {
  const records2 = output.split("\0");
  const branch = emptyBranch();
  const staged2 = [];
  const unstaged = [];
  const untracked = [];
  const conflicted = [];
  for (let i = 0; i < records2.length; i++) {
    const record2 = records2[i];
    if (!record2) continue;
    const tag = record2[0];
    if (tag === "#") {
      applyHeader(record2, branch);
      continue;
    }
    if (tag === "?") {
      untracked.push(makeFile(record2.slice(2), "untracked", "?"));
      continue;
    }
    if (tag === "!") continue;
    const parts = record2.split(" ");
    const xy = parts[1] ?? "..";
    const x = xy[0] ?? ".";
    const y = xy[1] ?? ".";
    if (tag === "u") {
      conflicted.push(makeFile(parts.slice(10).join(" "), "conflicted", xy));
      continue;
    }
    if (tag === "1") {
      const path = parts.slice(8).join(" ");
      if (x !== ".") staged2.push(makeFile(path, "staged", x));
      if (y !== ".") unstaged.push(makeFile(path, "unstaged", y));
      continue;
    }
    if (tag === "2") {
      const origPath = records2[i + 1] ?? "";
      i += 1;
      const score = Number.parseInt((parts[8] ?? "").slice(1), 10);
      const path = parts.slice(9).join(" ");
      if (x !== ".") {
        staged2.push(makeFile(path, "staged", x, origPath, Number.isNaN(score) ? null : score));
      }
      if (y !== ".") unstaged.push(makeFile(path, "unstaged", y));
    }
  }
  return { branch, staged: staged2, unstaged, untracked, conflicted };
}
function parseNumstat(output) {
  const records2 = output.split("\0");
  const stats = [];
  for (let i = 0; i < records2.length; i++) {
    const record2 = records2[i];
    if (!record2) continue;
    const fields = record2.split("	");
    if (fields.length < 3) continue;
    const added = fields[0] ?? "";
    const deleted = fields[1] ?? "";
    let path = fields.slice(2).join("	");
    let origPath = null;
    if (path === "") {
      origPath = records2[i + 1] ?? "";
      path = records2[i + 2] ?? "";
      i += 2;
    }
    const binary = added === "-" || deleted === "-";
    stats.push({
      path,
      origPath,
      insertions: binary ? 0 : Number.parseInt(added, 10) || 0,
      deletions: binary ? 0 : Number.parseInt(deleted, 10) || 0,
      binary
    });
  }
  return stats;
}
function applyStats(files, stats) {
  const byPath = new Map(stats.map((s) => [s.path, s]));
  for (const file of files) {
    const found = byPath.get(file.path);
    if (!found) continue;
    file.insertions = found.insertions;
    file.deletions = found.deletions;
    file.binary = found.binary;
  }
}
const GIT_TIMEOUT_MS$3 = 8e3;
const MAX_BUFFER$2 = 16 * 1024 * 1024;
async function git$2(cwd, args) {
  const PATH = await loginPath();
  const { stdout } = await run$9("git", args, {
    cwd,
    timeout: GIT_TIMEOUT_MS$3,
    maxBuffer: MAX_BUFFER$2,
    windowsHide: true,
    env: {
      ...process.env,
      PATH,
      // Never take index.lock for a read: this module polls in the background
      // and must not lose a race with the agent's own git commands.
      GIT_OPTIONAL_LOCKS: "0",
      // Porcelain output is stable, but error text is localised — pin it so
      // the "not a repository" check below works in any locale.
      LC_ALL: "C"
    }
  });
  return stdout;
}
function notRepo(cwd, reason, message) {
  return { repo: false, cwd, reason, message };
}
function classifyFailure(cwd, error) {
  const failure2 = error;
  const text2 = (failure2?.stderr || failure2?.message || "").trim();
  if (failure2?.code === "ENOENT") {
    return notRepo(cwd, "git-missing", "git is not installed, or not on the login PATH");
  }
  if (/not a git repository|detected dubious ownership/i.test(text2)) {
    return notRepo(cwd, "not-a-repo", text2);
  }
  return notRepo(cwd, "error", text2 || "git failed");
}
async function findGitDir(cwd) {
  try {
    return (await git$2(cwd, ["rev-parse", "--absolute-git-dir"])).trim() || null;
  } catch {
    return null;
  }
}
async function readGitStatus(cwd) {
  if (typeof cwd !== "string" || !node_path.isAbsolute(cwd)) {
    return notRepo(String(cwd), "no-such-folder", "Project path must be absolute");
  }
  try {
    const info = await promises.stat(cwd);
    if (!info.isDirectory()) return notRepo(cwd, "no-such-folder", "Not a folder");
  } catch {
    return notRepo(cwd, "no-such-folder", "Folder does not exist");
  }
  let root;
  try {
    root = (await git$2(cwd, ["rev-parse", "--show-toplevel"])).trim() || cwd;
  } catch (error) {
    return classifyFailure(cwd, error);
  }
  try {
    const [statusOut, worktreeOut, indexOut] = await Promise.all([
      // --untracked-files is left at the default "normal": "all" expands every
      // file inside an untracked folder, which turns a fresh clone with an
      // unignored build directory into tens of thousands of rows.
      git$2(cwd, ["status", "--porcelain=v2", "--branch", "-z"]),
      git$2(cwd, ["diff", "--numstat", "-z", "--no-ext-diff"]),
      git$2(cwd, ["diff", "--numstat", "-z", "--no-ext-diff", "--cached"])
    ]);
    const parsed = parsePorcelainV2(statusOut);
    applyStats(parsed.unstaged, parseNumstat(worktreeOut));
    applyStats(parsed.staged, parseNumstat(indexOut));
    return {
      repo: true,
      cwd,
      root,
      branch: parsed.branch,
      staged: parsed.staged,
      unstaged: parsed.unstaged,
      untracked: parsed.untracked,
      conflicted: parsed.conflicted,
      clean: parsed.staged.length === 0 && parsed.unstaged.length === 0 && parsed.untracked.length === 0 && parsed.conflicted.length === 0
    };
  } catch (error) {
    return classifyFailure(cwd, error);
  }
}
function repoRelative(root, path) {
  if (typeof path !== "string" || path === "" || path.includes("\0")) return null;
  if (node_path.isAbsolute(path)) return null;
  const rel = node_path.relative(root, node_path.resolve(root, path));
  if (rel === "" || rel === ".." || rel.startsWith(`..${node_path.sep}`) || node_path.isAbsolute(rel)) return null;
  return rel;
}
async function readFileDiff(cwd, path, options = {}) {
  if (!node_path.isAbsolute(cwd) || path === "") return "";
  let root;
  try {
    root = (await git$2(cwd, ["rev-parse", "--show-toplevel"])).trim() || cwd;
  } catch {
    return "";
  }
  const safe2 = repoRelative(root, path);
  if (!safe2) return "";
  if (options.untracked) {
    try {
      return await git$2(root, [
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--no-index",
        "--",
        "/dev/null",
        safe2
      ]);
    } catch (error) {
      const failure2 = error;
      return typeof failure2?.stdout === "string" ? failure2.stdout : "";
    }
  }
  const args = ["diff", "--no-color", "--no-ext-diff"];
  if (options.staged) args.push("--cached");
  args.push("--", safe2);
  try {
    return await git$2(root, args);
  } catch {
    return "";
  }
}
const GIT_STATUS_CHANGED = "git:status-changed";
const POLL_MS$2 = 1e3;
const FULL_REFRESH_MS = 4e3;
const watches = /* @__PURE__ */ new Map();
const teardownBound = /* @__PURE__ */ new Set();
function watchKey(target2, cwd) {
  return `${target2.id}\0${cwd}`;
}
async function signatureOf(gitDir) {
  if (!gitDir) return "";
  const parts = await Promise.all(
    ["HEAD", "index"].map(async (name) => {
      try {
        const info = await promises.stat(node_path.join(gitDir, name));
        return `${info.mtimeMs}:${info.size}`;
      } catch {
        return "-";
      }
    })
  );
  return parts.join("|");
}
function stopWatch(watch) {
  watch.stopped = true;
  if (watch.timer) clearTimeout(watch.timer);
  watch.timer = null;
}
async function emit$1(watch) {
  const result = await readGitStatus(watch.cwd);
  watch.lastFullRun = Date.now();
  if (result.repo && !watch.gitDir) watch.gitDir = await findGitDir(watch.cwd);
  watch.signature = await signatureOf(watch.gitDir);
  const payload = JSON.stringify(result);
  if (payload === watch.payload) return;
  watch.payload = payload;
  if (!watch.target.isDestroyed()) watch.target.send(GIT_STATUS_CHANGED, watch.cwd, result);
}
async function tick(watch) {
  if (watch.stopped) return;
  try {
    if (watch.target.isDestroyed()) {
      stopWatch(watch);
      return;
    }
    const signature2 = await signatureOf(watch.gitDir);
    const due = Date.now() - watch.lastFullRun >= FULL_REFRESH_MS;
    if (signature2 !== watch.signature || due) await emit$1(watch);
  } catch {
  } finally {
    if (!watch.stopped) watch.timer = setTimeout(() => void tick(watch), POLL_MS$2);
  }
}
function bindTeardown(target2) {
  const id2 = target2.id;
  if (teardownBound.has(id2)) return;
  teardownBound.add(id2);
  target2.once("destroyed", () => {
    teardownBound.delete(id2);
    for (const [key, watch] of watches) {
      if (watch.target !== target2) continue;
      stopWatch(watch);
      watches.delete(key);
    }
  });
}
async function startWatch(target2, cwd) {
  const key = watchKey(target2, cwd);
  const existing = watches.get(key);
  if (existing && !existing.stopped) {
    existing.refs += 1;
    return readGitStatus(cwd);
  }
  if (existing) stopWatch(existing);
  const watch = {
    cwd,
    target: target2,
    gitDir: null,
    timer: null,
    signature: "",
    payload: "",
    lastFullRun: 0,
    stopped: false,
    refs: 1
  };
  watches.set(key, watch);
  bindTeardown(target2);
  const first = await readGitStatus(cwd);
  watch.gitDir = first.repo ? await findGitDir(cwd) : null;
  watch.lastFullRun = Date.now();
  watch.signature = await signatureOf(watch.gitDir);
  watch.payload = JSON.stringify(first);
  if (!watch.stopped) watch.timer = setTimeout(() => void tick(watch), POLL_MS$2);
  return first;
}
function stopAllGitWatches() {
  for (const watch of watches.values()) stopWatch(watch);
  watches.clear();
  teardownBound.clear();
}
function asPath$1(value) {
  return typeof value === "string" && value.length > 0 && node_path.isAbsolute(value) ? value : null;
}
function registerGitIpc(ipcMain) {
  ipcMain.handle("git:status", (_event, cwd) => {
    const path = asPath$1(cwd);
    return path ? readGitStatus(path) : Promise.resolve(notRepo(String(cwd), "no-such-folder", "Project path must be absolute"));
  });
  ipcMain.handle("git:diff", (_event, cwd, file, options) => {
    const path = asPath$1(cwd);
    if (!path || typeof file !== "string") return Promise.resolve("");
    const opts = typeof options === "object" && options !== null ? options : {};
    return readFileDiff(path, file, { staged: !!opts.staged, untracked: !!opts.untracked });
  });
  ipcMain.handle("git:watch", (event, cwd) => {
    const path = asPath$1(cwd);
    return path ? startWatch(event.sender, path) : Promise.resolve(notRepo(String(cwd), "no-such-folder", "Project path must be absolute"));
  });
  ipcMain.on("git:unwatch", (event, cwd) => {
    const path = asPath$1(cwd);
    if (!path) return;
    const key = watchKey(event.sender, path);
    const watch = watches.get(key);
    if (!watch) return;
    watch.refs -= 1;
    if (watch.refs > 0) return;
    stopWatch(watch);
    watches.delete(key);
  });
}
const MAX_FILE_BYTES$2 = 2 * 1024 * 1024;
const MAX_ENTRIES = 2e3;
const ALWAYS_IGNORED = /* @__PURE__ */ new Set(["node_modules", ".git"]);
function isAlwaysIgnored(name) {
  return ALWAYS_IGNORED.has(name);
}
const IGNORE_FILES = [".gitignore", ".deckignore"];
const BINARY_SNIFF_BYTES = 8192;
function escapeLiteral(ch) {
  return /[.*+?^${}()|[\]\\/]/.test(ch) ? `\\${ch}` : ch;
}
function findClassEnd(pattern, start) {
  let i = start + 1;
  if (pattern[i] === "!" || pattern[i] === "^") i++;
  if (pattern[i] === "]") i++;
  for (; i < pattern.length; i++) {
    if (pattern[i] === "\\") i++;
    else if (pattern[i] === "]") return i;
  }
  return -1;
}
function compileClass(body) {
  let out = "[";
  let i = 0;
  if (body[0] === "!" || body[0] === "^") {
    out += "^";
    i = 1;
  }
  for (; i < body.length; i++) {
    const ch = body[i];
    if (ch === "\\") {
      out += `\\${body[++i] ?? "\\"}`;
      continue;
    }
    out += ch === "]" || ch === "^" ? `\\${ch}` : ch;
  }
  return `(?!/)${out}]`;
}
function patternToRegExp(pattern, anchored) {
  let out = anchored ? "^" : "(?:^|/)";
  let i = 0;
  while (i < pattern.length) {
    const ch = pattern[i];
    if (ch === "\\") {
      const next = pattern[i + 1];
      out += next === void 0 ? "\\\\" : escapeLiteral(next);
      i += 2;
      continue;
    }
    if (ch === "*") {
      if (pattern[i + 1] === "*") {
        let j = i + 2;
        while (pattern[j] === "*") j++;
        if (pattern[j] === "/") {
          out += "(?:.*/)?";
          i = j + 1;
        } else {
          out += ".*";
          i = j;
        }
        continue;
      }
      out += "[^/]*";
      i++;
      continue;
    }
    if (ch === "?") {
      out += "[^/]";
      i++;
      continue;
    }
    if (ch === "[") {
      const end = findClassEnd(pattern, i);
      if (end === -1) {
        out += "\\[";
        i++;
        continue;
      }
      out += compileClass(pattern.slice(i + 1, end));
      i = end + 1;
      continue;
    }
    out += escapeLiteral(ch);
    i++;
  }
  return new RegExp(`${out}$`);
}
function compileIgnorePattern(line) {
  let pattern = line.replace(/(?<!\\)\s+$/, "");
  if (pattern === "" || pattern.startsWith("#")) return null;
  let negated = false;
  if (pattern.startsWith("!")) {
    negated = true;
    pattern = pattern.slice(1);
  } else if (pattern.startsWith("\\#") || pattern.startsWith("\\!")) {
    pattern = pattern.slice(1);
  }
  let dirOnly = false;
  if (pattern.endsWith("/")) {
    dirOnly = true;
    pattern = pattern.slice(0, -1);
  }
  if (pattern === "") return null;
  const anchored = pattern.includes("/");
  if (pattern.startsWith("/")) pattern = pattern.slice(1);
  if (pattern === "") return null;
  return { source: line, negated, dirOnly, re: patternToRegExp(pattern, anchored) };
}
function parseIgnoreFile(text2) {
  const rules = [];
  for (const line of text2.split(/\r?\n/)) {
    const rule = compileIgnorePattern(line);
    if (rule) rules.push(rule);
  }
  return rules;
}
function evaluate(rules, path, isDir) {
  let ignored2 = false;
  for (const rule of rules) {
    if (rule.dirOnly && !isDir) continue;
    if (rule.re.test(path)) ignored2 = !rule.negated;
  }
  return ignored2;
}
function createIgnoreMatcher(rules) {
  return (relPath, isDir) => {
    const segments = relPath.split("/").filter((s) => s !== "");
    if (segments.length === 0) return false;
    if (segments.some((s) => ALWAYS_IGNORED.has(s))) return true;
    for (let i = 0; i < segments.length; i++) {
      const last = i === segments.length - 1;
      const hit = evaluate(rules, segments.slice(0, i + 1).join("/"), last ? isDir : true);
      if (last) return hit;
      if (hit) return true;
    }
    return false;
  };
}
class PathEscapeError extends Error {
  constructor(message) {
    super(message);
    this.name = "PathEscapeError";
  }
}
function isWithinRoot(root, target2) {
  const rel = node_path.relative(node_path.resolve(root), node_path.resolve(target2));
  if (rel === "") return true;
  return rel !== ".." && !rel.startsWith(`..${node_path.sep}`) && !node_path.isAbsolute(rel);
}
function safeJoin(root, relPath) {
  if (relPath.includes("\0")) throw new PathEscapeError("path contains a null byte");
  if (node_path.isAbsolute(relPath)) {
    throw new PathEscapeError(`expected a path relative to the project root, got ${relPath}`);
  }
  const abs = node_path.resolve(root, relPath);
  if (!isWithinRoot(root, abs)) {
    throw new PathEscapeError(`refusing to read outside the project root: ${relPath}`);
  }
  return abs;
}
function createsLoop(containerRealPath, targetRealPath) {
  return isWithinRoot(targetRealPath, containerRealPath);
}
const ignoreCache = /* @__PURE__ */ new Map();
async function ignoreStamp$1(root) {
  const parts = await Promise.all(
    IGNORE_FILES.map(async (name) => {
      try {
        const info = await promises.stat(node_path.join(root, name));
        return `${name}:${info.mtimeMs}:${info.size}`;
      } catch {
        return `${name}:-`;
      }
    })
  );
  return parts.join("|");
}
async function ignoreMatcherFor(root) {
  const stamp2 = await ignoreStamp$1(root);
  const cached2 = ignoreCache.get(root);
  if (cached2 && cached2.stamp === stamp2) return cached2.matcher;
  const rules = [];
  for (const name of IGNORE_FILES) {
    try {
      rules.push(...parseIgnoreFile(await promises.readFile(node_path.join(root, name), "utf8")));
    } catch {
    }
  }
  const matcher = createIgnoreMatcher(rules);
  ignoreCache.set(root, { matcher, stamp: stamp2 });
  return matcher;
}
function compareEntries(a, b) {
  if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1;
  return a.name.localeCompare(b.name, void 0, { numeric: true, sensitivity: "base" });
}
async function listDirectory(root, relDir = "", options = {}) {
  const rootReal = await promises.realpath(node_path.resolve(root));
  const dirReal = await promises.realpath(safeJoin(rootReal, relDir));
  if (!isWithinRoot(rootReal, dirReal)) {
    throw new PathEscapeError(`refusing to read outside the project root: ${relDir}`);
  }
  const ignores = await ignoreMatcherFor(rootReal);
  const dirents = await promises.readdir(dirReal, { withFileTypes: true });
  const entries2 = [];
  for (const dirent of dirents) {
    if (isAlwaysIgnored(dirent.name)) continue;
    const relPath = relDir === "" ? dirent.name : `${relDir}/${dirent.name}`;
    const symlink = dirent.isSymbolicLink();
    let kind = dirent.isDirectory() ? "dir" : "file";
    let blocked = false;
    if (symlink) {
      const abs = node_path.join(dirReal, dirent.name);
      try {
        const targetReal = await promises.realpath(abs);
        kind = (await promises.stat(abs)).isDirectory() ? "dir" : "file";
        blocked = !isWithinRoot(rootReal, targetReal) || kind === "dir" && createsLoop(dirReal, targetReal);
      } catch {
        kind = "file";
        blocked = true;
      }
    } else if (!dirent.isDirectory() && !dirent.isFile()) {
      blocked = true;
    }
    if (!options.showIgnored && ignores(relPath, kind === "dir")) continue;
    entries2.push({ name: dirent.name, relPath, kind, symlink, blocked });
  }
  entries2.sort(compareEntries);
  const truncated = entries2.length > MAX_ENTRIES;
  if (truncated) entries2.length = MAX_ENTRIES;
  return { relPath: relDir, entries: entries2, truncated };
}
function looksBinary(buf) {
  const end = Math.min(buf.length, BINARY_SNIFF_BYTES);
  for (let i = 0; i < end; i++) {
    if (buf[i] === 0) return true;
  }
  return false;
}
function countLines(text2) {
  if (text2 === "") return 0;
  let lines2 = 1;
  for (let i = 0; i < text2.length; i++) {
    if (text2.charCodeAt(i) === 10) lines2++;
  }
  return text2.endsWith("\n") ? lines2 - 1 : lines2;
}
async function readTextFile(root, relPath) {
  const rootReal = await promises.realpath(node_path.resolve(root));
  const abs = await promises.realpath(safeJoin(rootReal, relPath));
  if (!isWithinRoot(rootReal, abs)) {
    throw new PathEscapeError(`refusing to read outside the project root: ${relPath}`);
  }
  const info = await promises.lstat(abs);
  if (!info.isFile()) throw new Error(`not a readable file: ${relPath}`);
  if (info.size > MAX_FILE_BYTES$2) {
    return { kind: "too-large", relPath, bytes: info.size, limit: MAX_FILE_BYTES$2 };
  }
  const buf = await promises.readFile(abs);
  if (looksBinary(buf)) return { kind: "binary", relPath, bytes: buf.byteLength };
  const text2 = buf.toString("utf8");
  return { kind: "text", relPath, text: text2, bytes: buf.byteLength, lines: countLines(text2) };
}
function requireString$2(value, label2) {
  if (typeof value !== "string") throw new TypeError(`${label2} must be a string`);
  return value;
}
function registerFsIpc(ipcMain) {
  ipcMain.handle(
    "fs:list",
    (_e, root, relDir, options) => {
      const showIgnored = typeof options === "object" && options !== null && options.showIgnored === true;
      return listDirectory(requireString$2(root, "root"), requireString$2(relDir ?? "", "relDir"), {
        showIgnored
      });
    }
  );
  ipcMain.handle(
    "fs:read",
    (_e, root, relPath) => readTextFile(requireString$2(root, "root"), requireString$2(relPath, "relPath"))
  );
}
const FILE_SEARCH_CHANNEL = "search:files";
const FILE_SEARCH_CANCEL_CHANNEL = "search:cancel";
const FILE_SEARCH_INVALIDATE_CHANNEL = "search:invalidate";
const DEFAULT_IGNORED_DIRS = [
  ".git",
  ".hg",
  ".svn",
  "node_modules",
  "bower_components",
  ".venv",
  "venv",
  "__pycache__",
  ".mypy_cache",
  ".pytest_cache",
  ".tox",
  "dist",
  "build",
  "out",
  "target",
  "coverage",
  ".next",
  ".nuxt",
  ".svelte-kit",
  ".turbo",
  ".parcel-cache",
  ".cache",
  ".gradle",
  ".idea",
  "DerivedData",
  "Pods",
  ".terraform",
  ".serverless",
  ".yarn",
  ".pnpm-store"
];
const DEFAULT_LIMIT$2 = 1e4;
const MAX_LIMIT$1 = 5e4;
const DEFAULT_MAX_DEPTH = 12;
const READ_CONCURRENCY = 12;
const GIT_TIMEOUT_MS$2 = 8e3;
const GIT_MAX_BUFFER = 32 * 1024 * 1024;
const CACHE_TTL_MS = 3e4;
class SearchAbortedError extends Error {
  constructor() {
    super("file search aborted");
    this.name = "AbortError";
  }
}
function isAbortError$1(error) {
  return error instanceof Error && error.name === "AbortError";
}
function throwIfAborted(signal) {
  if (signal?.aborted) throw new SearchAbortedError();
}
function toPosix(path) {
  return node_path.sep === "/" ? path : path.split(node_path.sep).join("/");
}
function parseGitFileList(stdout) {
  const seen = /* @__PURE__ */ new Set();
  for (const entry of stdout.split("\0")) {
    if (entry !== "") seen.add(entry);
  }
  return [...seen];
}
function isIgnoredPath(relativePath, ignored2) {
  const segments = relativePath.split("/");
  for (let i = 0; i < segments.length - 1; i++) {
    if (ignored2.has(segments[i])) return true;
  }
  return false;
}
function isPlausibleProjectRoot(root) {
  if (root === "" || !node_path.isAbsolute(root)) return false;
  const resolved = node_path.resolve(root);
  if (resolved === node_path.parse(resolved).root) return false;
  if (resolved === node_path.resolve(node_os.homedir())) return false;
  return true;
}
function clampLimit$1(limit) {
  if (typeof limit !== "number" || !Number.isFinite(limit)) return DEFAULT_LIMIT$2;
  return Math.max(1, Math.min(MAX_LIMIT$1, Math.floor(limit)));
}
function runGit(args, cwd, signal) {
  return new Promise((done, fail2) => {
    node_child_process.execFile(
      "git",
      [...args],
      {
        cwd,
        signal,
        encoding: "utf8",
        timeout: GIT_TIMEOUT_MS$2,
        maxBuffer: GIT_MAX_BUFFER,
        windowsHide: true
      },
      (error, stdout) => {
        if (error) fail2(error);
        else done(stdout);
      }
    );
  });
}
async function listWithGit(root, signal) {
  try {
    const stdout = await runGit(
      ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
      root,
      signal
    );
    return parseGitFileList(stdout);
  } catch (error) {
    if (isAbortError$1(error)) throw error;
    return null;
  }
}
async function readDirectory(dir) {
  try {
    return await promises.readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
}
async function walkProjectFiles(root, options = {}) {
  const limit = clampLimit$1(options.limit);
  const maxDepth = options.maxDepth ?? DEFAULT_MAX_DEPTH;
  const ignored2 = /* @__PURE__ */ new Set([...DEFAULT_IGNORED_DIRS, ...options.ignoreDirs ?? []]);
  const files = [];
  let truncated = false;
  let queue = [{ absolute: root, relative: "", depth: 0 }];
  while (queue.length > 0) {
    throwIfAborted(options.signal);
    if (files.length >= limit) {
      truncated = true;
      break;
    }
    const batch = queue.splice(0, READ_CONCURRENCY);
    const read = await Promise.all(
      batch.map(async (dir) => ({ dir, entries: await readDirectory(dir.absolute) }))
    );
    const deeper = [];
    for (const { dir, entries: entries2 } of read) {
      for (const entry of entries2) {
        if (files.length >= limit) {
          truncated = true;
          break;
        }
        if (entry.isSymbolicLink()) continue;
        const relative = dir.relative === "" ? entry.name : `${dir.relative}/${entry.name}`;
        if (entry.isDirectory()) {
          if (ignored2.has(entry.name)) continue;
          if (dir.depth >= maxDepth) {
            truncated = true;
            continue;
          }
          deeper.push({
            absolute: node_path.join(dir.absolute, entry.name),
            relative,
            depth: dir.depth + 1
          });
        } else if (entry.isFile()) {
          files.push(relative);
        }
      }
    }
    queue = queue.concat(deeper);
  }
  if (queue.length > 0) truncated = true;
  return { files, truncated };
}
async function listProjectFiles(root, options = {}) {
  const started = Date.now();
  const resolved = node_path.resolve(root);
  const limit = clampLimit$1(options.limit);
  const ignored2 = /* @__PURE__ */ new Set([...DEFAULT_IGNORED_DIRS, ...options.ignoreDirs ?? []]);
  if (options.disableGit !== true) {
    const tracked = await listWithGit(resolved, options.signal);
    if (tracked) {
      throwIfAborted(options.signal);
      const kept = tracked.filter((file) => !isIgnoredPath(file, ignored2));
      return {
        root: resolved,
        files: kept.slice(0, limit),
        truncated: kept.length > limit,
        source: "git",
        tookMs: Date.now() - started
      };
    }
  }
  const walked = await walkProjectFiles(resolved, { ...options, limit });
  return {
    root: resolved,
    files: walked.files.map(toPosix),
    truncated: walked.truncated,
    source: "walk",
    tookMs: Date.now() - started
  };
}
const MAX_CACHED_ROOTS = 8;
const cache$3 = /* @__PURE__ */ new Map();
function invalidateFileList(root) {
  if (root === void 0) cache$3.clear();
  else cache$3.delete(node_path.resolve(root));
}
function readCache(root, limit) {
  const entry = cache$3.get(root);
  if (!entry) return null;
  if (Date.now() - entry.at >= CACHE_TTL_MS) {
    cache$3.delete(root);
    return null;
  }
  if (entry.list.truncated && entry.limit < limit) return null;
  cache$3.delete(root);
  cache$3.set(root, entry);
  return entry.list;
}
function writeCache(root, limit, list) {
  const now = Date.now();
  for (const [key, entry] of [...cache$3]) {
    if (now - entry.at >= CACHE_TTL_MS) cache$3.delete(key);
  }
  cache$3.delete(root);
  cache$3.set(root, { at: now, limit, list });
  while (cache$3.size > MAX_CACHED_ROOTS) {
    const coldest = cache$3.keys().next();
    if (coldest.done) break;
    cache$3.delete(coldest.value);
  }
}
async function isDirectory$1(path) {
  try {
    return (await promises.stat(path)).isDirectory();
  } catch {
    return false;
  }
}
function registerSearchIpc(ipcMain, options = {}) {
  const inFlight2 = /* @__PURE__ */ new Map();
  const watched = /* @__PURE__ */ new Set();
  const cancelFor = (senderId) => {
    inFlight2.get(senderId)?.abort();
    inFlight2.delete(senderId);
  };
  ipcMain.handle(
    FILE_SEARCH_CHANNEL,
    async (event, request) => {
      const payload = request;
      const rawRoot = payload?.root;
      if (typeof rawRoot !== "string" || rawRoot === "") return { ok: false, error: "invalid-root" };
      const root = node_path.resolve(rawRoot);
      if (!isPlausibleProjectRoot(root)) return { ok: false, error: "invalid-root" };
      if (options.isAllowedRoot && !options.isAllowedRoot(root)) {
        return { ok: false, error: "invalid-root" };
      }
      if (!await isDirectory$1(root)) return { ok: false, error: "invalid-root" };
      const senderId = event.sender.id;
      const limit = clampLimit$1(payload?.limit ?? options.limit);
      if (payload?.refresh !== true) {
        const cached2 = readCache(root, limit);
        if (cached2) return { ok: true, ...cached2 };
      }
      cancelFor(senderId);
      const controller = new AbortController();
      inFlight2.set(senderId, controller);
      if (!watched.has(senderId)) {
        watched.add(senderId);
        event.sender.once("destroyed", () => {
          cancelFor(senderId);
          watched.delete(senderId);
        });
      }
      try {
        const list = await listProjectFiles(root, { signal: controller.signal, limit });
        writeCache(root, limit, list);
        return { ok: true, ...list };
      } catch (error) {
        if (isAbortError$1(error)) return { ok: false, error: "cancelled" };
        console.error("[file-search] enumeration failed:", error);
        return { ok: false, error: "failed" };
      } finally {
        if (inFlight2.get(senderId) === controller) inFlight2.delete(senderId);
      }
    }
  );
  ipcMain.handle(FILE_SEARCH_CANCEL_CHANNEL, (event) => {
    cancelFor(event.sender.id);
  });
  ipcMain.handle(FILE_SEARCH_INVALIDATE_CHANNEL, (_event, root) => {
    invalidateFileList(typeof root === "string" ? root : void 0);
  });
}
const MAX_BOARD_BYTES = 4 * 1024 * 1024;
function boardFileName(projectPath2) {
  const canonical = node_path.resolve(projectPath2);
  const slug2 = node_path.basename(canonical).replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 40);
  const hash2 = node_crypto.createHash("sha256").update(canonical).digest("hex").slice(0, 10);
  return `${slug2 || "project"}-${hash2}.json`;
}
function boardsDir() {
  return node_path.join(electron.app.getPath("userData"), "boards");
}
function boardFilePath(projectPath2) {
  return node_path.join(boardsDir(), boardFileName(projectPath2));
}
function assertProjectPath$1(projectPath2) {
  if (typeof projectPath2 !== "string" || !node_path.isAbsolute(projectPath2)) {
    throw new Error("board: an absolute project path is required");
  }
}
function isBoardLike(value) {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value;
  return Array.isArray(candidate.columns) && typeof candidate.cards === "object" && candidate.cards !== null && !Array.isArray(candidate.cards);
}
function loadBoard(projectPath2) {
  assertProjectPath$1(projectPath2);
  const file = boardFilePath(projectPath2);
  try {
    const { size } = node_fs.statSync(file);
    if (size > MAX_BOARD_BYTES) {
      console.error(`[board] ignoring an oversized board file (${size} bytes):`, file);
      return null;
    }
    return JSON.parse(node_fs.readFileSync(file, "utf8"));
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.error("[board] unreadable board, starting a fresh one:", err);
    }
    return null;
  }
}
function saveBoard(projectPath2, board) {
  assertProjectPath$1(projectPath2);
  if (!isBoardLike(board)) {
    throw new Error("board: refusing to save a payload that is not a board");
  }
  const json = JSON.stringify({ ...board, projectPath: projectPath2 }, null, 2);
  if (Buffer.byteLength(json, "utf8") > MAX_BOARD_BYTES) {
    throw new Error("board: payload too large to save");
  }
  const file = boardFilePath(projectPath2);
  const tmp = `${file}.${process.pid}.tmp`;
  node_fs.mkdirSync(boardsDir(), { recursive: true });
  try {
    node_fs.writeFileSync(tmp, json, "utf8");
    node_fs.renameSync(tmp, file);
  } catch (err) {
    try {
      node_fs.unlinkSync(tmp);
    } catch {
    }
    throw err;
  }
}
function registerBoardIpc(ipcMain) {
  ipcMain.handle("board:load", (_e, projectPath2) => loadBoard(projectPath2));
  ipcMain.handle("board:save", (_e, projectPath2, board) => {
    saveBoard(projectPath2, board);
  });
}
function isRecord$a(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function num(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}
function str$3(value) {
  return typeof value === "string" && value.length > 0 ? value : void 0;
}
const MAX_TOKENS = 1e12;
function sanitizeUsage(usage) {
  const clamp2 = (value) => Number.isFinite(value) ? Math.min(MAX_TOKENS, Math.max(0, Math.floor(value))) : 0;
  return {
    input: clamp2(usage.input),
    output: clamp2(usage.output),
    cacheWrite5m: clamp2(usage.cacheWrite5m),
    cacheWrite1h: clamp2(usage.cacheWrite1h),
    cacheRead: clamp2(usage.cacheRead)
  };
}
function parseInsightLine(line) {
  const trimmed = line.trim();
  if (trimmed.length === 0) return null;
  let raw;
  try {
    raw = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (!isRecord$a(raw)) return null;
  const type = str$3(raw.type);
  if (!type) return null;
  const parsed = {
    at: typeof raw.timestamp === "string" ? Date.parse(raw.timestamp) || 0 : 0,
    sessionId: str$3(raw.sessionId),
    cwd: str$3(raw.cwd),
    isSidechain: raw.isSidechain === true,
    request: null,
    toolUses: [],
    toolResults: [],
    compaction: null
  };
  if (type === "system" && str$3(raw.subtype) === "compact_boundary") {
    const meta = isRecord$a(raw.compactMetadata) ? raw.compactMetadata : void 0;
    const count = (value) => Math.min(MAX_TOKENS, Math.max(0, Math.floor(num(value))));
    parsed.compaction = {
      preTokens: meta ? count(meta.preTokens) : 0,
      postTokens: meta ? count(meta.postTokens) : 0,
      trigger: (meta ? str$3(meta.trigger) : void 0) ?? "auto",
      durationMs: meta ? Math.max(0, num(meta.durationMs)) : 0
    };
    return parsed;
  }
  const message = isRecord$a(raw.message) ? raw.message : void 0;
  if (!message) return null;
  if (Array.isArray(message.content)) {
    for (const block of message.content) {
      if (!isRecord$a(block)) continue;
      const blockType = str$3(block.type);
      if (blockType === "tool_use") {
        const id2 = str$3(block.id);
        const name = str$3(block.name);
        if (id2 && name) parsed.toolUses.push({ id: id2, name });
      } else if (blockType === "tool_result") {
        const id2 = str$3(block.tool_use_id);
        if (id2) parsed.toolResults.push({ id: id2, failed: block.is_error === true });
      }
    }
  }
  if (type === "assistant") {
    const usage = parseUsage(message.usage);
    if (usage) {
      parsed.request = {
        messageId: str$3(message.id),
        requestId: str$3(raw.requestId),
        uuid: str$3(raw.uuid),
        model: str$3(message.model) ?? "",
        usage: sanitizeUsage(usage),
        speed: isRecord$a(message.usage) && str$3(message.usage.speed) === "fast" ? "fast" : "standard",
        stopReason: str$3(message.stop_reason) ?? null
      };
    }
  }
  if (!parsed.request && parsed.toolUses.length === 0 && parsed.toolResults.length === 0) {
    return null;
  }
  return parsed;
}
function mayCarryInsight(line) {
  return line.includes('"usage"') || line.includes('"tool_use"') || line.includes('"tool_result"') || line.includes("compact_boundary");
}
const MCP_TOOL = /^mcp__(.+?)__(.+)$/;
function mcpServerOf(toolName) {
  return MCP_TOOL.exec(toolName)?.[1] ?? null;
}
function rateKey(normalizedModel, speed) {
  if (speed !== "fast" || normalizedModel.endsWith("-fast")) return normalizedModel;
  return `${normalizedModel}-fast`;
}
const DEFAULT_MAX_TIMELINE_ENTRIES = 750;
const COSTLIEST_COUNT = 5;
const DEFAULT_MAX_CONTEXT_POINTS = 400;
function downsampleContext(points, target2) {
  if (target2 <= 0) return [];
  if (points.length <= target2) return points;
  const size = points.length / target2;
  const out = [];
  for (let i = 0; i < target2; i += 1) {
    const from = Math.floor(i * size);
    const to = Math.min(points.length, Math.floor((i + 1) * size));
    let peak = points[from];
    for (let j = from + 1; j < to; j += 1) {
      const candidate = points[j];
      if (candidate && (!peak || candidate.percent > peak.percent)) peak = candidate;
    }
    if (peak) out.push(peak);
  }
  return out;
}
function unbillableBucket(request) {
  const normalized = normalizeModelId(request.model);
  if (normalized !== "") return normalized;
  return totalTokens(request.usage) > 0 ? UNKNOWN_MODEL : SYNTHETIC_MODEL;
}
function buildSessionInsights(lines2, options = {}) {
  const requests = [];
  const byKey = /* @__PURE__ */ new Map();
  const toolStats = /* @__PURE__ */ new Map();
  const pendingTools = /* @__PURE__ */ new Map();
  const seenToolUses = /* @__PURE__ */ new Set();
  const seenToolResults = /* @__PURE__ */ new Set();
  const rawCompactions = [];
  let sessionId = options.sessionId ?? "";
  let cwd = "";
  let startedAt = 0;
  let lastActivityAt = 0;
  let toolMs = 0;
  let maxMainPrompt = 0;
  let lastMainModel = "";
  let lastAnyModel = "";
  for (const line of lines2) {
    if (line.sessionId && !sessionId) sessionId = line.sessionId;
    if (line.cwd && !cwd) cwd = line.cwd;
    if (line.at > 0) {
      if (startedAt === 0 || line.at < startedAt) startedAt = line.at;
      if (line.at > lastActivityAt) lastActivityAt = line.at;
    }
    if (line.compaction) {
      rawCompactions.push({
        ...line.compaction,
        at: line.at,
        afterRequest: requests.length
      });
      if (line.compaction.preTokens > maxMainPrompt) maxMainPrompt = line.compaction.preTokens;
      continue;
    }
    let owner;
    if (line.request) {
      const key = line.request.messageId ?? line.request.requestId ?? line.request.uuid ?? "";
      const existing = key ? byKey.get(key) : void 0;
      if (existing) {
        if (line.at > existing.endedAt) existing.endedAt = line.at;
        if (line.at > 0 && (existing.at === 0 || line.at < existing.at)) existing.at = line.at;
        owner = existing;
      } else {
        const normalized = normalizeModelId(line.request.model);
        const billable = isBillableModel(line.request.model);
        const created = {
          index: requests.length + 1,
          key: key || `line-${requests.length + 1}`,
          at: line.at,
          endedAt: line.at,
          model: billable ? rateKey(normalized, line.request.speed) : unbillableBucket(line.request),
          speed: line.request.speed,
          usage: line.request.usage,
          stopReason: line.request.stopReason,
          isSidechain: line.isSidechain,
          tools: []
        };
        requests.push(created);
        if (key) byKey.set(key, created);
        owner = created;
        if (billable) {
          lastAnyModel = created.model;
          if (!line.isSidechain) lastMainModel = created.model;
        }
        const prompt = promptTokens(line.request.usage);
        if (!line.isSidechain && prompt > maxMainPrompt) maxMainPrompt = prompt;
      }
    }
    for (const use of line.toolUses) {
      if (seenToolUses.has(use.id)) continue;
      seenToolUses.add(use.id);
      const stat2 = toolStats.get(use.name) ?? {
        name: use.name,
        calls: 0,
        failures: 0,
        timedCalls: 0,
        totalMs: 0,
        maxMs: 0
      };
      stat2.calls += 1;
      toolStats.set(use.name, stat2);
      pendingTools.set(use.id, { name: use.name, at: line.at });
      const target2 = owner ?? requests[requests.length - 1];
      if (target2) target2.tools.push(use.name);
    }
    for (const result of line.toolResults) {
      if (seenToolResults.has(result.id)) continue;
      seenToolResults.add(result.id);
      const pending = pendingTools.get(result.id);
      if (!pending) continue;
      pendingTools.delete(result.id);
      const stat2 = toolStats.get(pending.name);
      if (!stat2) continue;
      if (result.failed) stat2.failures += 1;
      if (pending.at > 0 && line.at > 0 && line.at >= pending.at) {
        const elapsed = line.at - pending.at;
        stat2.timedCalls += 1;
        stat2.totalMs += elapsed;
        toolMs += elapsed;
        if (elapsed > stat2.maxMs) stat2.maxMs = elapsed;
      }
    }
  }
  const contextModel = lastMainModel || lastAnyModel || requests[requests.length - 1]?.model || "";
  const window = effectiveContextWindow(contextWindowFor(contextModel), maxMainPrompt);
  const entries2 = [];
  const contextSeries = [];
  const byModel = /* @__PURE__ */ new Map();
  const perRequestCost = [];
  let generatingMs = 0;
  let sidechainRequests = 0;
  let previousEnd = 0;
  let firstMainPrompt = 0;
  let lastMainPrompt = 0;
  for (const request of requests) {
    const priced = aggregateCost([[request.model, request.usage]], {
      at: request.at > 0 ? request.at : lastActivityAt
    });
    perRequestCost.push(priced);
    const bucket = byModel.get(request.model) ?? { usage: emptyUsage(), requests: 0, costs: [] };
    bucket.usage = addUsage(bucket.usage, request.usage);
    bucket.requests += 1;
    bucket.costs.push(priced);
    byModel.set(request.model, bucket);
    const prompt = promptTokens(request.usage);
    const streamMs = request.endedAt > request.at ? request.endedAt - request.at : 0;
    generatingMs += streamMs;
    if (request.isSidechain) sidechainRequests += 1;
    else {
      if (firstMainPrompt === 0) firstMainPrompt = prompt;
      lastMainPrompt = prompt;
    }
    const hasCost = Object.keys(priced.byModel).length > 0;
    const percent = request.isSidechain || window <= 0 ? null : prompt / window * 100;
    entries2.push({
      index: request.index,
      key: request.key,
      at: request.at,
      endedAt: request.endedAt,
      streamMs,
      sinceLastMs: previousEnd > 0 && request.at > previousEnd ? request.at - previousEnd : 0,
      model: request.model,
      speed: request.speed,
      usage: request.usage,
      promptTokens: prompt,
      outputTokens: request.usage.output,
      cost: hasCost ? priced.cost : null,
      costUsd: hasCost ? priced.cost.total : null,
      contextPercent: percent,
      isSidechain: request.isSidechain,
      stopReason: request.stopReason,
      tools: request.tools
    });
    if (percent !== null && prompt > 0) {
      contextSeries.push({ index: request.index, at: request.at, tokens: prompt, percent });
    }
    if (request.endedAt > previousEnd) previousEnd = request.endedAt;
  }
  const cost = mergeAggregates(perRequestCost);
  const totalPriced = cost.cost.total;
  const models = [...byModel.entries()].map(([model, bucket]) => {
    const merged = mergeAggregates(bucket.costs);
    const priced = Object.keys(merged.byModel).length > 0;
    return {
      model,
      requests: bucket.requests,
      usage: bucket.usage,
      promptTokens: promptTokens(bucket.usage),
      outputTokens: bucket.usage.output,
      cost: priced ? merged.cost : null,
      costUsd: priced ? merged.cost.total : null,
      share: priced && totalPriced > 0 ? merged.cost.total / totalPriced : 0,
      legacyRate: merged.usedLegacyRate
    };
  }).sort((a, b) => (b.costUsd ?? 0) - (a.costUsd ?? 0) || b.promptTokens - a.promptTokens);
  const totalCalls = [...toolStats.values()].reduce((sum, stat2) => sum + stat2.calls, 0);
  const tools = [...toolStats.values()].map((stat2) => ({
    name: stat2.name,
    server: mcpServerOf(stat2.name),
    calls: stat2.calls,
    failures: stat2.failures,
    timedCalls: stat2.timedCalls,
    totalMs: stat2.totalMs,
    maxMs: stat2.maxMs,
    avgMs: stat2.timedCalls > 0 ? stat2.totalMs / stat2.timedCalls : 0,
    share: totalCalls > 0 ? stat2.calls / totalCalls : 0
  })).sort((a, b) => b.calls - a.calls || a.name.localeCompare(b.name));
  const usage = sumUsage([...byModel.values()].map((bucket) => bucket.usage));
  const context = lastMainPrompt > 0 ? contextUsage(lastMainPrompt, contextModel, window) : null;
  const warnings = [];
  if (context) {
    const live = contextWarning(context);
    if (live) warnings.push(live);
  }
  const prefix = preContextWarning(firstMainPrompt, window);
  if (prefix) warnings.push(prefix);
  const compactions = rawCompactions.map((entry) => ({
    at: entry.at,
    afterRequest: entry.afterRequest,
    preTokens: entry.preTokens,
    postTokens: entry.postTokens,
    reclaimedTokens: Math.max(0, entry.preTokens - entry.postTokens),
    trigger: entry.trigger,
    durationMs: entry.durationMs
  }));
  const max = Math.max(0, Math.floor(options.maxTimelineEntries ?? DEFAULT_MAX_TIMELINE_ENTRIES));
  const timeline = entries2.length > max ? entries2.slice(entries2.length - max) : entries2;
  const costliest = entries2.filter((entry) => entry.costUsd !== null).sort((a, b) => (b.costUsd ?? 0) - (a.costUsd ?? 0) || a.index - b.index).slice(0, COSTLIEST_COUNT);
  const contextPoints = downsampleContext(
    contextSeries,
    Math.max(0, Math.floor(options.maxContextPoints ?? DEFAULT_MAX_CONTEXT_POINTS))
  );
  return {
    sessionId,
    transcriptPath: options.transcriptPath ?? "",
    cwd,
    startedAt,
    lastActivityAt,
    durationMs: lastActivityAt > startedAt ? lastActivityAt - startedAt : 0,
    generatingMs,
    toolMs,
    requests: requests.length,
    sidechainRequests,
    timeline,
    omittedRequests: entries2.length - timeline.length,
    costliest,
    tools,
    toolCalls: totalCalls,
    toolFailures: tools.reduce((sum, tool) => sum + tool.failures, 0),
    models,
    usage,
    cost,
    cacheHitRate: cacheHitRate(usage),
    context,
    contextSeries: contextPoints,
    compactions,
    warnings,
    preContextTokens: firstMainPrompt,
    generatedAt: options.now ?? Date.now()
  };
}
const CHUNK_BYTES$2 = 4 * 1024 * 1024;
const MAX_LINE_BYTES$2 = 8 * 1024 * 1024;
async function readInsightLines(path) {
  let size;
  try {
    const info = await promises.stat(path);
    if (!info.isFile()) return [];
    size = info.size;
  } catch {
    return [];
  }
  const handle2 = await promises.open(path, "r");
  const decoder = new node_string_decoder.StringDecoder("utf8");
  const lines2 = [];
  let offset = 0;
  let partial = "";
  try {
    while (offset < size) {
      const length = Math.min(CHUNK_BYTES$2, size - offset);
      const buffer = Buffer.allocUnsafe(length);
      const { bytesRead } = await handle2.read(buffer, 0, length, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
      const text2 = partial + decoder.write(buffer.subarray(0, bytesRead));
      const chunk = text2.split("\n");
      partial = chunk.pop() ?? "";
      if (partial.length > MAX_LINE_BYTES$2) partial = "";
      for (const line of chunk) {
        if (!mayCarryInsight(line)) continue;
        const parsed = parseInsightLine(line);
        if (parsed) lines2.push(parsed);
      }
    }
  } finally {
    await handle2.close();
  }
  if (partial.length > 0 && mayCarryInsight(partial)) {
    const parsed = parseInsightLine(partial);
    if (parsed) lines2.push(parsed);
  }
  return lines2;
}
async function readSessionInsights(path, options = {}) {
  const lines2 = await readInsightLines(path);
  return buildSessionInsights(lines2, {
    ...options,
    transcriptPath: path,
    sessionId: options.sessionId ?? node_path.basename(path, ".jsonl")
  });
}
function assertTranscriptPath$1(path) {
  if (typeof path !== "string" || path.length === 0) {
    throw new Error("insights: a transcript path is required");
  }
  const resolved = node_path.resolve(path);
  const root = node_path.resolve(claudeConfigDir(), "projects");
  if (!resolved.startsWith(root + node_path.sep) || node_path.extname(resolved) !== ".jsonl") {
    throw new Error(`insights: refusing to read outside the transcript store: ${path}`);
  }
  return resolved;
}
function projectPath$1(cwd) {
  if (typeof cwd !== "string" || cwd.trim().length === 0) {
    throw new Error("insights: a project path is required");
  }
  return node_path.resolve(cwd);
}
function registerInsightsIpc(ipcMain) {
  ipcMain.handle(
    "insights:session",
    (_e, transcriptPath) => readSessionInsights(assertTranscriptPath$1(transcriptPath))
  );
  ipcMain.handle(
    "insights:latest",
    async (_e, cwd) => {
      const newest = await newestTranscript(transcriptDir(projectPath$1(cwd)));
      return newest ? readSessionInsights(newest.path) : null;
    }
  );
  ipcMain.handle(
    "insights:list",
    (_e, cwd) => listTranscripts(transcriptDir(projectPath$1(cwd)))
  );
}
function isRecord$9(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function str$2(value) {
  return typeof value === "string" && value.length > 0 ? value : void 0;
}
const CLI_TAG = /^\s*<(?:command-name|command-message|command-args|command-contents|local-command-stdout|local-command-stderr|bash-input|bash-stdout|bash-stderr|task-notification|user-prompt-submit-hook|system-reminder|user-memory-input|ide-opened-file|ide-selection)[\s>]/;
const SYSTEM_REMINDER = /<system-reminder>[\s\S]*?<\/system-reminder>/g;
function cleanPrompt(text2) {
  return text2.replace(SYSTEM_REMINDER, "").trim();
}
function textBlocks(content) {
  const parts = [];
  for (const block of content) {
    if (!isRecord$9(block) || str$2(block.type) !== "text") continue;
    const text2 = typeof block.text === "string" ? block.text : "";
    if (text2.trim().length > 0) parts.push(text2.trim());
  }
  return parts.join("\n\n");
}
function hasBlock(content, type) {
  return content.some((block) => isRecord$9(block) && str$2(block.type) === type);
}
function parseChatLine(line) {
  const trimmed = line.trim();
  if (trimmed.length === 0) return null;
  let raw;
  try {
    raw = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (!isRecord$9(raw)) return null;
  const type = str$2(raw.type);
  if (type !== "user" && type !== "assistant") return null;
  if (raw.isSidechain === true) return null;
  if (raw.isMeta === true) return null;
  if (raw.isCompactSummary === true) return null;
  if (raw.isVisibleInTranscriptOnly === true) return null;
  const message = isRecord$9(raw.message) ? raw.message : void 0;
  if (!message) return null;
  const uuid = str$2(raw.uuid);
  const at = typeof raw.timestamp === "string" ? Date.parse(raw.timestamp) || 0 : 0;
  const sessionId = str$2(raw.sessionId);
  const cwd = str$2(raw.cwd);
  if (type === "assistant") {
    if (str$2(message.model) === "<synthetic>") return null;
    if (raw.isApiErrorMessage === true) return null;
    if (!Array.isArray(message.content)) return null;
    const text22 = textBlocks(message.content);
    if (text22.length === 0) return null;
    const messageId = str$2(message.id) ?? uuid ?? "";
    return {
      role: "agent",
      text: text22,
      at,
      groupKey: messageId,
      // Blocks of one request repeat their `usage` verbatim but each carries a
      // *different* content block, so the id alone cannot be the key — that
      // would keep the first sentence of a reply and drop the rest. The id plus
      // the text drops only true repeats, which compaction replays do produce.
      dedupeKey: `agent\0${messageId}\0${text22}`,
      sessionId,
      cwd
    };
  }
  const origin = isRecord$9(raw.origin) ? str$2(raw.origin.kind) : void 0;
  if (origin !== void 0 && origin !== "human") return null;
  const content = message.content;
  let text2;
  if (typeof content === "string") {
    text2 = cleanPrompt(content);
    if (text2.length === 0 || CLI_TAG.test(content)) return null;
  } else if (Array.isArray(content)) {
    if (origin !== "human" || hasBlock(content, "tool_result")) return null;
    const joined = textBlocks(content);
    if (CLI_TAG.test(joined)) return null;
    text2 = cleanPrompt(joined);
    if (text2.length === 0) return null;
  } else {
    return null;
  }
  const key = uuid ?? `${at}`;
  return {
    role: "you",
    text: text2,
    at,
    groupKey: key,
    // Prompts are deduped by line identity, never by text: "continue" typed
    // twice is two turns, but the same uuid replayed across a compaction
    // boundary is one.
    dedupeKey: `you\0${key}`,
    sessionId,
    cwd
  };
}
function mayCarryChat(line) {
  if (line.includes('"tool_use_id"')) return false;
  return line.includes('"type":"user"') || line.includes('"type":"assistant"');
}
const JOIN = "\n\n";
class ChatCollapser {
  messages = [];
  open = null;
  ordinal = 0;
  /** The whole conversation so far. */
  get all() {
    return this.messages;
  }
  /**
   * Add a line. Returns the message it changed — a new one, or the open agent
   * message with more text on it — so a caller tailing a live file can send
   * only what moved.
   */
  push(line) {
    if (line.role === "agent" && this.open) {
      this.open.text = this.open.text.length > 0 ? `${this.open.text}${JOIN}${line.text}` : line.text;
      if (this.open.at === 0) this.open.at = line.at;
      return this.open;
    }
    this.ordinal += 1;
    const created = {
      id: `${line.role}:${line.groupKey || `line-${this.ordinal}`}`,
      role: line.role,
      text: line.text,
      at: line.at
    };
    this.messages.push(created);
    this.open = line.role === "agent" ? created : null;
    return created;
  }
  clear() {
    this.messages.length = 0;
    this.open = null;
    this.ordinal = 0;
  }
}
const CHUNK_BYTES$1 = 4 * 1024 * 1024;
const MAX_LINE_BYTES$1 = 8 * 1024 * 1024;
class ChatReader {
  constructor(path, sessionId = node_path.basename(path, ".jsonl")) {
    this.path = path;
    this.sessionId = sessionId;
  }
  path;
  offset = 0;
  partial = "";
  decoder = new node_string_decoder.StringDecoder("utf8");
  collapser = new ChatCollapser();
  /**
   * Lines already folded in.
   *
   * Compaction replays part of the conversation verbatim, so both prompts and
   * replies genuinely arrive twice; 49 duplicate line uuids in one sweep of
   * this machine's transcripts.
   */
  seen = /* @__PURE__ */ new Set();
  sessionId;
  cwd = "";
  get position() {
    return this.offset;
  }
  /** Everything read so far, collapsed. */
  get conversation() {
    return this.collapser.all;
  }
  rewind() {
    this.offset = 0;
    this.partial = "";
    this.decoder = new node_string_decoder.StringDecoder("utf8");
    this.collapser.clear();
    this.seen.clear();
  }
  /** One chunk. `complete` is false while bytes remain. */
  async read() {
    let size;
    try {
      const info = await promises.stat(this.path);
      if (!info.isFile()) return { messages: [], reset: false, complete: true };
      size = info.size;
    } catch {
      return { messages: [], reset: false, complete: true };
    }
    let reset = false;
    if (size < this.offset) {
      this.rewind();
      reset = true;
    }
    if (size === this.offset) return { messages: [], reset, complete: true };
    const length = Math.min(CHUNK_BYTES$1, size - this.offset);
    const buffer = Buffer.allocUnsafe(length);
    const handle2 = await promises.open(this.path, "r");
    let text2;
    try {
      const { bytesRead } = await handle2.read(buffer, 0, length, this.offset);
      if (bytesRead === 0) return { messages: [], reset, complete: true };
      this.offset += bytesRead;
      text2 = this.partial + this.decoder.write(buffer.subarray(0, bytesRead));
    } finally {
      await handle2.close();
    }
    const lines2 = text2.split("\n");
    this.partial = lines2.pop() ?? "";
    if (this.partial.length > MAX_LINE_BYTES$1) this.partial = "";
    const changed = /* @__PURE__ */ new Map();
    for (const line of lines2) {
      if (!mayCarryChat(line)) continue;
      const parsed = parseChatLine(line);
      if (!parsed) continue;
      if (this.seen.has(parsed.dedupeKey)) continue;
      this.seen.add(parsed.dedupeKey);
      if (parsed.sessionId && !this.sessionId) this.sessionId = parsed.sessionId;
      if (parsed.cwd && !this.cwd) this.cwd = parsed.cwd;
      const message = this.collapser.push(parsed);
      changed.set(message.id, message);
    }
    return {
      messages: [...changed.values()].map((m) => ({ ...m })),
      reset,
      complete: this.offset >= size
    };
  }
  /** Read to EOF. */
  async readAll() {
    const merged = /* @__PURE__ */ new Map();
    let reset = false;
    for (; ; ) {
      const chunk = await this.read();
      if (chunk.reset) {
        reset = true;
        merged.clear();
      }
      for (const message of chunk.messages) merged.set(message.id, message);
      if (chunk.complete) break;
    }
    return { messages: [...merged.values()], reset };
  }
}
async function newestChatTranscript(cwd) {
  const newest = await newestTranscript(transcriptDir(node_path.resolve(cwd)));
  return newest?.path ?? null;
}
const readers = /* @__PURE__ */ new Map();
const MAX_READERS = 12;
function assertTranscriptPath(path) {
  if (typeof path !== "string" || path.length === 0) {
    throw new Error("chat: a transcript path is required");
  }
  const resolved = node_path.resolve(path);
  const root = node_path.resolve(claudeConfigDir(), "projects");
  if (!resolved.startsWith(root + node_path.sep) || node_path.extname(resolved) !== ".jsonl") {
    throw new Error(`chat: refusing to read outside the transcript store: ${path}`);
  }
  return resolved;
}
function readerFor(path) {
  const existing = readers.get(path);
  if (existing) return existing;
  if (readers.size >= MAX_READERS) {
    const oldest = readers.keys().next().value;
    if (typeof oldest === "string") readers.delete(oldest);
  }
  const reader = new ChatReader(path);
  readers.set(path, reader);
  return reader;
}
function emptyUpdate(found) {
  return {
    transcriptPath: "",
    sessionId: "",
    cwd: "",
    messages: [],
    reset: false,
    cursor: 0,
    found,
    complete: true,
    updatedAt: Date.now()
  };
}
function updateFrom(reader, messages, reset, complete) {
  return {
    transcriptPath: reader.path,
    sessionId: reader.sessionId,
    cwd: reader.cwd,
    messages,
    reset,
    cursor: reader.position,
    found: true,
    complete,
    updatedAt: Date.now()
  };
}
function requestOf(value) {
  return isRecord$9(value) ? { cwd: str$2(value.cwd), transcriptPath: str$2(value.transcriptPath) } : {};
}
function registerChatIpc(ipcMain) {
  ipcMain.handle("chat:load", async (_e, request) => {
    const { cwd, transcriptPath } = requestOf(request);
    let path = null;
    if (transcriptPath) path = assertTranscriptPath(transcriptPath);
    else if (cwd) path = await newestChatTranscript(cwd);
    if (!path) return emptyUpdate(false);
    readers.delete(path);
    const reader = readerFor(path);
    const { reset } = await reader.readAll();
    return updateFrom(reader, [...reader.conversation], reset, true);
  });
  ipcMain.handle("chat:tail", async (_e, request) => {
    const { cwd, transcriptPath } = requestOf(request);
    let path = null;
    if (transcriptPath) path = assertTranscriptPath(transcriptPath);
    else if (cwd) path = await newestChatTranscript(cwd);
    if (!path) return emptyUpdate(false);
    const known = readers.has(path);
    const reader = readerFor(path);
    const { messages, reset } = await reader.readAll();
    if (!known) return updateFrom(reader, [...reader.conversation], true, true);
    return updateFrom(reader, messages, reset, true);
  });
  ipcMain.on("chat:close", (_e, transcriptPath) => {
    if (typeof transcriptPath !== "string" || transcriptPath.length === 0) return;
    readers.delete(node_path.resolve(transcriptPath));
  });
}
const LOCAL_HOSTS = /* @__PURE__ */ new Set(["", "*", "0.0.0.0", "127.0.0.1", "::", "::1", "[::]", "[::1]"]);
function splitHostPort(address) {
  const match = /(?:^|:)(\d+)$/.exec(address);
  if (!match) return null;
  const port = Number(match[1]);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) return null;
  return { host: address.slice(0, address.lastIndexOf(":")), port };
}
function isLocallyReachable(host) {
  return LOCAL_HOSTS.has(host);
}
const LSOF = { command: "lsof", args: ["-nP", "-iTCP", "-sTCP:LISTEN"] };
function parseLsof(stdout) {
  const owners = [];
  for (const line of stdout.split("\n").slice(1)) {
    const columns = line.split(/\s+/);
    const command = columns[0];
    const address = columns[8];
    if (!command || !address) continue;
    const split2 = splitHostPort(address);
    if (!split2 || !isLocallyReachable(split2.host)) continue;
    owners.push({ port: split2.port, process: command });
  }
  return owners;
}
const NETSTAT = { command: "netstat.exe", args: ["-ano"] };
const TASKLIST = { command: "tasklist.exe", args: ["/FO", "CSV", "/NH"] };
const UNBOUND_PEER = /* @__PURE__ */ new Set(["0.0.0.0:0", "[::]:0", "*:*"]);
function parseNetstat(stdout) {
  const rows = [];
  for (const line of stdout.split(/\r?\n/)) {
    const columns = line.trim().split(/\s+/);
    if (columns.length !== 5) continue;
    const proto = columns[0].toUpperCase();
    if (proto !== "TCP" && proto !== "TCPV6") continue;
    if (!UNBOUND_PEER.has(columns[2])) continue;
    const pid = Number(columns[4]);
    if (!Number.isInteger(pid) || pid < 0) continue;
    const split2 = splitHostPort(columns[1]);
    if (!split2 || !isLocallyReachable(split2.host)) continue;
    rows.push({ port: split2.port, pid });
  }
  return rows;
}
function csvFields(line) {
  const fields = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (quoted) {
      if (char !== '"') field += char;
      else if (line[i + 1] === '"') {
        field += '"';
        i++;
      } else quoted = false;
    } else if (char === '"') quoted = true;
    else if (char === ",") {
      fields.push(field);
      field = "";
    } else field += char;
  }
  fields.push(field);
  return fields;
}
function parseTasklist(stdout) {
  const names = /* @__PURE__ */ new Map();
  for (const line of stdout.split(/\r?\n/)) {
    if (line.trim() === "") continue;
    const fields = csvFields(line);
    if (fields.length < 2) continue;
    const pid = Number(fields[1].trim());
    const name = fields[0].trim().replace(/\.exe$/i, "");
    if (!Number.isInteger(pid) || name === "") continue;
    names.set(pid, name);
  }
  return names;
}
function windowsOwners(rows, names) {
  return rows.map((row) => ({ port: row.port, process: names.get(row.pid) ?? null }));
}
const run$8 = node_util.promisify(node_child_process.execFile);
const NOT_A_DEV_SERVER = /* @__PURE__ */ new Set([
  "rapportd",
  "sshd",
  "launchd",
  "ControlCe",
  "Spotify",
  "Dropbox",
  "iTunes",
  "AirPlay",
  "identityservicesd",
  "remoted",
  "Google",
  "Slack",
  "Postgres",
  "postgres",
  "mysqld",
  "redis-server",
  "mongod",
  "Docker",
  // Windows equivalents. Nothing above ever appears there and nothing here ever
  // appears on macOS, so one list serves both without either platform paying for
  // the other's noise. `System` is PID 4, which holds 135, 445 and 139 on a
  // stock install — three ports offered as dev servers on the very first launch.
  "System",
  "System Idle Process",
  "svchost",
  "services",
  "lsass",
  "wininit",
  "spoolsv",
  "sqlservr",
  "MsMpEng",
  "vmware-hostd",
  "com.docker.backend"
]);
const LIKELY_DEV = ["node", "bun", "deno", "python", "python3", "ruby", "php", "java", "dotnet", "caddy", "nginx"];
function rank$1(entry) {
  const name = entry.process.toLowerCase();
  const likely = LIKELY_DEV.findIndex((candidate) => name.startsWith(candidate));
  if (entry.guessed) return 1e3;
  return likely === -1 ? 500 : likely;
}
const SCAN_TIMEOUT_MS = 5e3;
async function listeningOwners(platform) {
  const options = { timeout: SCAN_TIMEOUT_MS, windowsHide: true };
  if (isWindows(platform)) {
    const [connections, processes] = await Promise.all([
      run$8(NETSTAT.command, NETSTAT.args, options),
      run$8(TASKLIST.command, TASKLIST.args, options).catch(() => ({ stdout: "" }))
    ]);
    return windowsOwners(parseNetstat(connections.stdout), parseTasklist(processes.stdout));
  }
  const { stdout } = await run$8(LSOF.command, LSOF.args, options);
  return parseLsof(stdout);
}
async function listeningPorts(platform) {
  const found = /* @__PURE__ */ new Map();
  for (const owner of await listeningOwners(platform)) {
    if (owner.process !== null && NOT_A_DEV_SERVER.has(owner.process)) continue;
    if (found.has(owner.port)) continue;
    found.set(owner.port, {
      port: owner.port,
      // A port whose owner could not be named still answers; saying "unknown"
      // and flagging it beats either inventing a name or hiding the port.
      process: owner.process ?? "unknown",
      guessed: owner.process === null
    });
  }
  return [...found.values()];
}
const FALLBACK_PORTS = [3e3, 5173, 8080, 4200, 8e3, 5174, 4321, 3001];
function probe(port) {
  return new Promise((resolve) => {
    const socket = node_net.createConnection({ host: "127.0.0.1", port });
    let settled = false;
    const done = (live) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(live);
    };
    socket.setTimeout(250);
    socket.once("connect", () => done(true));
    socket.once("timeout", () => done(false));
    socket.once("error", () => done(false));
  });
}
const CACHE_MS$1 = 4e3;
let cached$2 = null;
let inFlight$3 = null;
async function scanDevPorts(force = false, platform = currentPlatform()) {
  if (!force && cached$2 && Date.now() - cached$2.at < CACHE_MS$1) return cached$2.ports;
  if (inFlight$3) return inFlight$3;
  inFlight$3 = runScan(platform).then((ports) => {
    cached$2 = { at: Date.now(), ports };
    return ports;
  }).finally(() => {
    inFlight$3 = null;
  });
  return inFlight$3;
}
async function runScan(platform) {
  let ports;
  try {
    ports = await listeningPorts(platform);
  } catch {
    const probed = await Promise.all(
      FALLBACK_PORTS.map(async (port) => ({ port, live: await probe(port) }))
    );
    ports = probed.filter((entry) => entry.live).map((entry) => ({ port: entry.port, process: "unknown", guessed: true }));
  }
  return ports.sort((a, b) => rank$1(a) - rank$1(b) || a.port - b.port);
}
function registerDevPortsIpc(ipcMain) {
  ipcMain.handle("dev:ports", (_event, force) => scanDevPorts(force === true));
}
const PERMISSION_MODES = [
  { id: "auto", label: "Auto", screen: /auto mode on/i },
  { id: "manual", label: "Manual", screen: /manual mode on/i },
  { id: "acceptEdits", label: "Accept edits", screen: /accept edits on/i },
  { id: "plan", label: "Plan", screen: /plan mode on/i },
  { id: "bypass", label: "Bypass", screen: /bypass permissions on/i }
];
const EFFORT_LEVELS = [
  { id: "low", label: "Low" },
  { id: "medium", label: "Medium" },
  { id: "high", label: "High" },
  { id: "xhigh", label: "Extra high" },
  { id: "max", label: "Max" },
  { id: "ultracode", label: "Ultracode" },
  { id: "auto", label: "Auto" }
];
const MODEL_ALIASES = [
  { id: "default", label: "Default" },
  { id: "opus", label: "Opus" },
  { id: "fable", label: "Fable" },
  { id: "sonnet", label: "Sonnet" },
  { id: "haiku", label: "Haiku" }
];
function lines(screen) {
  return stripAnsi(screen).split("\n").map((line) => line.trim()).filter((line) => line !== "");
}
function readPermissionMode(screen) {
  const tail = lines(screen).slice(-5);
  for (let i = tail.length - 1; i >= 0; i--) {
    for (const mode of PERMISSION_MODES) {
      if (mode.screen.test(tail[i])) return mode.id;
    }
  }
  return null;
}
function scopeOf(tail) {
  if (/saved as your default/i.test(tail)) return "default";
  if (/\bthis session\b/i.test(tail)) return "session";
  return null;
}
const SCOPE_TEXT = {
  default: "saved as your default for new sessions",
  session: "this session only"
};
function readModelConfirmation(screen) {
  const text2 = lines(screen).join("\n");
  const matches = [
    ...text2.matchAll(/(?:Set model to|Kept model as)\s+(.+?)(?:\s+and saved\b|\s+for this session only\b|$)([^\n]*)/gim)
  ];
  const last = matches[matches.length - 1];
  if (!last) return null;
  const name = last[1].trim();
  if (name === "") return null;
  return { name, scope: scopeOf(`${last[0]}`) };
}
function readModelFromScreen(screen) {
  return readModelConfirmation(screen)?.name ?? null;
}
function readEffortConfirmation(screen) {
  const text2 = lines(screen).join("\n");
  const matches = [...text2.matchAll(/(?:Set effort level to\s+([a-z]+)|Effort level set to\s+(auto))([^\n]*)/gi)];
  const last = matches[matches.length - 1];
  if (!last) return null;
  const level = (last[1] ?? last[2]).toLowerCase();
  return { level, scope: scopeOf(last[0]) };
}
function readEffortFromScreen(screen) {
  return readEffortConfirmation(screen)?.level ?? null;
}
function readFastFromScreen(screen) {
  const text2 = lines(screen).join("\n");
  const refused = /Fast mode (?:unavailable|is not available)[:.]?\s*(.*)$/im.exec(text2);
  if (refused) {
    return {
      value: "off",
      label: "Off",
      source: "screen",
      unavailableReason: refused[1].trim() || "Fast mode is not available on this account"
    };
  }
  const toggled = [...text2.matchAll(/Fast mode (ON|OFF)\b/g)];
  const last = toggled[toggled.length - 1];
  if (!last) return null;
  const on = last[1] === "ON";
  return { value: on ? "on" : "off", label: on ? "On" : "Off", source: "screen" };
}
function readCommandError(screen) {
  const text2 = lines(screen).join("\n");
  const patterns = [
    /Model '[^']*' not found[^\n]*/i,
    /Model '[^']*' is not in the list of available models/i,
    /Model '[^']*' is restricted by your organization's settings[^\n]*/i,
    /Failed to validate model:[^\n]*/i,
    /Invalid argument:[^\n]*/i,
    /Unknown model '[^']*'/i,
    /Fast mode unavailable:[^\n]*/i,
    /Failed to set effort level:[^\n]*/i,
    /Effort '[^']*' exceeds your organization's limit[^\n]*/i,
    /Ultracode [^\n]*Valid options are:[^\n]*/i,
    // Both of these say the change was accepted and then overridden, so they
    // are failures from the user's point of view even though they read calmly.
    /(?:Cleared effort from settings|Effort set to auto for this session), but CLAUDE_CODE_EFFORT_LEVEL=[^\n]*/i,
    /Not applied:[^\n]*/i
  ];
  for (const pattern of patterns) {
    const hit = pattern.exec(text2);
    if (hit) return hit[0].trim();
  }
  return null;
}
function isRecord$8(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
async function readClaudeSettings(configDir = claudeConfigDir()) {
  try {
    const raw = await promises.readFile(node_path.join(configDir, "settings.json"), "utf8");
    const parsed = JSON.parse(raw);
    return isRecord$8(parsed) ? parsed : {};
  } catch {
    return {};
  }
}
function effortFromSettings(settings) {
  if (settings.ultracode === true) return { value: "ultracode", label: "Ultracode", source: "settings" };
  const level = typeof settings.effortLevel === "string" ? settings.effortLevel.toLowerCase() : "";
  const known = EFFORT_LEVELS.find((entry) => entry.id === level);
  if (!known) return { value: null, label: null, source: null };
  return { value: known.id, label: known.label, source: "settings" };
}
function fastFromSettings(settings) {
  if (typeof settings.fastMode !== "boolean") return { value: null, label: null, source: null };
  const on = settings.fastMode === true;
  return { value: on ? "on" : "off", label: on ? "On" : "Off", source: "settings" };
}
async function readModelFromTranscript(cwd) {
  const file = await newestTranscript(transcriptDir(cwd));
  if (!file) return null;
  let raw;
  try {
    raw = await promises.readFile(file.path, "utf8");
  } catch {
    return null;
  }
  const all = raw.split("\n");
  for (let i = all.length - 1; i >= 0 && i >= all.length - 4e3; i--) {
    const line = all[i].trim();
    if (line === "" || !line.includes('"model"')) continue;
    try {
      const parsed = JSON.parse(line);
      if (!isRecord$8(parsed) || parsed.type !== "assistant") continue;
      const message = parsed.message;
      if (!isRecord$8(message)) continue;
      const model = message.model;
      if (typeof model === "string" && model.trim() !== "") return model.trim();
    } catch {
    }
  }
  return null;
}
function labelModelId(raw) {
  const long = /\[1m\]$/i.test(raw.trim());
  const id2 = normalizeModelId(raw);
  const match = /^claude-(opus|sonnet|haiku|fable)-(\d+(?:-\d+)?)/.exec(id2);
  if (!match) return raw.trim();
  const family = match[1][0].toUpperCase() + match[1].slice(1);
  const version2 = match[2].replace(/-/g, ".");
  return `${family} ${version2}${long ? " · 1M" : ""}`;
}
const UNKNOWN = { value: null, label: null, source: null };
async function readControls(access, sessionId, cwd) {
  const screen = sessionId ? await access.screen(sessionId) : null;
  const permission = (() => {
    if (screen === null) return UNKNOWN;
    const mode = readPermissionMode(screen);
    if (!mode) return UNKNOWN;
    const entry = PERMISSION_MODES.find((m) => m.id === mode);
    return { value: mode, label: entry ? entry.label : mode, source: "screen" };
  })();
  const model = await (async () => {
    const confirmed = screen === null ? null : readModelFromScreen(screen);
    if (confirmed) return { value: confirmed, label: confirmed, source: "screen" };
    if (!cwd) return UNKNOWN;
    const raw = await readModelFromTranscript(cwd);
    if (!raw) return UNKNOWN;
    return { value: raw, label: labelModelId(raw), source: "transcript" };
  })();
  const settings = await readClaudeSettings();
  const effort = (() => {
    const override = process.env.CLAUDE_CODE_EFFORT_LEVEL?.trim().toLowerCase();
    if (override) {
      const known = EFFORT_LEVELS.find((entry) => entry.id === override);
      return { value: override, label: known ? known.label : override, source: "env" };
    }
    const confirmed = screen === null ? null : readEffortFromScreen(screen);
    if (confirmed) {
      const known = EFFORT_LEVELS.find((entry) => entry.id === confirmed);
      return { value: confirmed, label: known ? known.label : confirmed, source: "screen" };
    }
    return effortFromSettings(settings);
  })();
  const fast = (() => {
    const confirmed = screen === null ? null : readFastFromScreen(screen);
    if (confirmed) return confirmed;
    return fastFromSettings(settings);
  })();
  return { model, effort, fast, permission, live: screen !== null };
}
const POLL_MS$1 = 120;
const COMMAND_TIMEOUT_MS = 6e3;
const CYCLE_STEP_TIMEOUT_MS = 2500;
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
async function waitForScreen(access, sessionId, timeoutMs, done) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await sleep(POLL_MS$1);
    const screen = await access.screen(sessionId);
    if (screen === null) return null;
    const answer = done(screen);
    if (answer !== null) return answer;
  }
  return null;
}
function sendCommand(access, sessionId, command) {
  access.write(sessionId, `${command}\r`);
}
async function cycleOnce(access, sessionId, from) {
  access.write(sessionId, "\x1B[Z");
  return waitForScreen(access, sessionId, CYCLE_STEP_TIMEOUT_MS, (screen) => {
    const now = readPermissionMode(screen);
    return now !== null && now !== from ? now : null;
  });
}
async function applyPermission(access, sessionId, target2) {
  const wanted = PERMISSION_MODES.find((mode) => mode.id === target2);
  if (!wanted) return { ok: false, message: `${target2} is not a permission mode this build can reach.`, mode: null };
  const screen = await access.screen(sessionId);
  if (screen === null) return { ok: false, message: "That session is no longer running.", mode: null };
  const startedAt = readPermissionMode(screen);
  if (startedAt !== null && startedAt === wanted.id) {
    return { ok: true, message: `Already in ${wanted.label} mode.`, mode: startedAt };
  }
  if (wanted.id === "plan") {
    sendCommand(access, sessionId, "/plan");
    const landed = await waitForScreen(access, sessionId, COMMAND_TIMEOUT_MS, (later) => {
      const mode = readPermissionMode(later);
      return mode === "plan" ? mode : null;
    });
    if (landed) return { ok: true, message: "Enabled plan mode.", mode: landed };
    return { ok: false, message: "Typed /plan but the footer did not change.", mode: readPermissionMode(await access.screen(sessionId) ?? "") };
  }
  if (startedAt === null) {
    return {
      ok: false,
      message: "The permission footer is not on screen, so the current mode is unknown — cycling from an unknown start would be a guess.",
      mode: null
    };
  }
  let current = startedAt;
  const start = startedAt;
  const seen = [current];
  for (let press = 0; press < PERMISSION_MODES.length + 1; press++) {
    const next = await cycleOnce(access, sessionId, current);
    if (next === null) {
      return { ok: false, message: `Pressed shift+tab but the footer stayed on ${current}.`, mode: current };
    }
    current = next;
    if (current === wanted.id) return { ok: true, message: `Switched to ${wanted.label} mode.`, mode: current };
    if (current === start) {
      return {
        ok: false,
        message: `This session's cycle only offers ${seen.join(", ")} — ${wanted.label} is not available in it.`,
        mode: current
      };
    }
    seen.push(current);
  }
  return { ok: false, message: `Gave up cycling; the footer is on ${current}.`, mode: current };
}
async function applyControl(access, request) {
  const { sessionId, cwd, control, value } = request;
  if (await access.screen(sessionId) === null) {
    return { ok: false, message: "That session is no longer running.", reading: UNKNOWN };
  }
  if (control === "permission") {
    const outcome = await applyPermission(access, sessionId, value);
    const entry = PERMISSION_MODES.find((mode) => mode.id === outcome.mode);
    return {
      ok: outcome.ok,
      message: outcome.message,
      reading: outcome.mode ? { value: outcome.mode, label: entry ? entry.label : outcome.mode, source: "screen" } : UNKNOWN
    };
  }
  if (control === "model") {
    if (!MODEL_ALIASES.some((alias) => alias.id === value)) {
      return { ok: false, message: `${value} is not one of the aliases the CLI accepts.`, reading: UNKNOWN };
    }
    const before = readModelFromScreen(await access.screen(sessionId) ?? "");
    sendCommand(access, sessionId, `/model ${value}`);
    const answer = await waitForScreen(access, sessionId, COMMAND_TIMEOUT_MS, (screen) => {
      const failure2 = readCommandError(screen);
      if (failure2) return { ok: false, text: failure2, scope: null };
      const now = readModelConfirmation(screen);
      return now && now.name !== before ? { ok: true, text: now.name, scope: now.scope } : null;
    });
    if (!answer) {
      return {
        ok: false,
        message: "Typed /model but the CLI has not answered yet — it may be mid-turn.",
        reading: await currentModel(access, sessionId, cwd)
      };
    }
    if (!answer.ok) return { ok: false, message: answer.text, reading: await currentModel(access, sessionId, cwd) };
    return {
      ok: true,
      // The scope is quoted from the CLI, not asserted: it decides per call
      // between "saved as your default for new sessions" and "for this session
      // only", and saying the wrong one is a lie about the user's config.
      message: `Model is now ${answer.text}${answer.scope ? ` — ${SCOPE_TEXT[answer.scope]}.` : "."}`,
      reading: { value: answer.text, label: answer.text, source: "screen" }
    };
  }
  if (control === "effort") {
    if (!EFFORT_LEVELS.some((level) => level.id === value)) {
      return { ok: false, message: `${value} is not one of the levels the CLI accepts.`, reading: UNKNOWN };
    }
    sendCommand(access, sessionId, `/effort ${value}`);
    const answer = await waitForScreen(access, sessionId, COMMAND_TIMEOUT_MS, (screen) => {
      const failure2 = readCommandError(screen);
      if (failure2) return { ok: false, text: failure2, scope: null };
      const now = readEffortConfirmation(screen);
      return now && now.level === value ? { ok: true, text: now.level, scope: now.scope } : null;
    });
    const known = EFFORT_LEVELS.find((level) => level.id === value);
    if (!answer) {
      return {
        ok: false,
        message: "Typed /effort but the CLI has not answered yet — it may be mid-turn.",
        reading: effortFromSettings(await readClaudeSettings())
      };
    }
    if (!answer.ok) return { ok: false, message: answer.text, reading: effortFromSettings(await readClaudeSettings()) };
    return {
      ok: true,
      // Not "and saved as your default" — the CLI prints one of two scopes and
      // ultracode is always the session-only one. Quote it or say nothing.
      message: `Effort is now ${known ? known.label : value}${answer.scope ? ` — ${SCOPE_TEXT[answer.scope]}.` : "."}`,
      reading: { value, label: known ? known.label : value, source: "screen" }
    };
  }
  if (control === "fast") {
    if (value !== "on" && value !== "off") {
      return { ok: false, message: "Fast mode is on or off.", reading: UNKNOWN };
    }
    sendCommand(access, sessionId, `/fast ${value}`);
    const answer = await waitForScreen(access, sessionId, COMMAND_TIMEOUT_MS, (screen) => readFastFromScreen(screen));
    if (!answer) {
      return {
        ok: false,
        // The CLI only announces fast mode when it *changes* it, so silence
        // genuinely has two readings and this says both rather than picking
        // the flattering one.
        message: `Typed /fast ${value} but the CLI printed nothing — it announces fast mode only when the setting changes, so it was either already ${value} or it is mid-turn.`,
        reading: fastFromSettings(await readClaudeSettings())
      };
    }
    if (answer.unavailableReason) return { ok: false, message: answer.unavailableReason, reading: answer };
    return { ok: answer.value === value, message: `Fast mode ${answer.label}.`, reading: answer };
  }
  return { ok: false, message: `Unknown control ${String(control)}.`, reading: UNKNOWN };
}
async function currentModel(access, sessionId, cwd) {
  const screen = await access.screen(sessionId);
  const confirmed = screen === null ? null : readModelFromScreen(screen);
  if (confirmed) return { value: confirmed, label: confirmed, source: "screen" };
  if (!cwd) return UNKNOWN;
  const raw = await readModelFromTranscript(cwd);
  return raw ? { value: raw, label: labelModelId(raw), source: "transcript" } : UNKNOWN;
}
function registerAgentControlsIpc(ipcMain, access) {
  ipcMain.handle(
    "agent:controls:read",
    (_event, request) => readControls(access, request?.sessionId, request?.cwd)
  );
  ipcMain.handle("agent:controls:apply", (_event, request) => applyControl(access, request));
}
const EVENT = "browser-window-focus";
const appWindowFocus = (listener) => {
  let detach = null;
  let cancelled = false;
  void import("electron").then((electron2) => {
    const app = electron2.app;
    if (cancelled || typeof app?.on !== "function") return;
    const emitter = app;
    emitter.on(EVENT, listener);
    detach = () => emitter.removeListener(EVENT, listener);
  }).catch(() => {
  });
  return () => {
    cancelled = true;
    detach?.();
    detach = null;
  };
};
const UPDATE_STATE_CHANNEL = "update:state";
function macBundleRoot(execPath) {
  const marker = execPath.lastIndexOf(".app/");
  return marker === -1 ? null : execPath.slice(0, marker + ".app".length);
}
function codeSignaturePath(bundleRoot) {
  return `${bundleRoot}/Contents/_CodeSignature/CodeResources`;
}
const DEV_BUILD_REASON = "This is a development build — it runs from source, so there is nothing to update. Packaged builds check GitHub releases for a newer version.";
const UNSIGNED_REASON = "This build is not code-signed, so it cannot install its own updates: macOS applies updates through Squirrel.Mac, which refuses to replace an app it cannot verify a signature for. Download the new version from Releases and replace the app by hand.";
const NO_FEED_REASON = "This build was packaged without a release feed, so there is nowhere to check. Download new versions from Releases.";
function updateSupport(environment, fileExists) {
  if (!environment.isPackaged) return { supported: false, reason: DEV_BUILD_REASON };
  if (environment.platform === "darwin") {
    const bundle = macBundleRoot(environment.execPath);
    if (!bundle || !fileExists(codeSignaturePath(bundle))) {
      return { supported: false, reason: UNSIGNED_REASON };
    }
  }
  if (!fileExists(environment.feedConfigPath)) return { supported: false, reason: NO_FEED_REASON };
  return { supported: true };
}
const MAX_NOTES_LENGTH = 4e3;
function readNotes(info) {
  const raw = info.releaseNotes;
  if (typeof raw === "string") {
    const trimmed = raw.trim();
    return trimmed === "" ? null : trimmed.slice(0, MAX_NOTES_LENGTH);
  }
  if (Array.isArray(raw)) {
    const joined = raw.map((entry) => typeof entry?.note === "string" ? entry.note.trim() : "").filter((note) => note !== "").join("\n\n");
    return joined === "" ? null : joined.slice(0, MAX_NOTES_LENGTH);
  }
  return null;
}
function readSizeBytes(info) {
  const files = Array.isArray(info.files) ? info.files : [];
  const zip = files.find((file) => typeof file?.url === "string" && file.url.toLowerCase().endsWith(".zip"));
  const chosen = zip ?? files[0];
  const size = chosen?.size;
  return typeof size === "number" && Number.isFinite(size) && size > 0 ? size : null;
}
const LAUNCH_DELAY_MS = 2e4;
const MIN_AUTOMATIC_INTERVAL_MS = 60 * 60 * 1e3;
function signature(state) {
  switch (state.phase) {
    case "idle":
      return `idle:${state.checkedAt ?? ""}`;
    case "checking":
      return "checking";
    case "available":
      return `available:${state.version}:${state.sizeBytes ?? ""}:${state.notes ?? ""}`;
    case "downloading":
      return `downloading:${state.version}:${state.percent}`;
    case "ready":
      return `ready:${state.version}`;
    case "error":
      return `error:${state.message}`;
    case "unsupported":
      return `unsupported:${state.reason}`;
  }
}
function messageOf$1(error) {
  if (error instanceof Error && error.message.trim() !== "") return error.message.trim();
  const text2 = String(error).trim();
  return text2 === "" ? "The update check failed for an unknown reason." : text2;
}
function createUpdateController(deps) {
  const { updater, environment, broadcast: broadcast2 } = deps;
  const fileExists = deps.fileExists ?? node_fs.existsSync;
  const now = deps.now ?? (() => Date.now());
  const verdict = updateSupport(environment, fileExists);
  const manual = deps.manual ?? null;
  const usable = verdict.supported || manual !== null;
  let current = usable ? { phase: "idle", checkedAt: null } : { phase: "unsupported", reason: verdict.reason };
  const read = () => current;
  let lastSignature = signature(current);
  let lastCheckStartedAt = 0;
  let launchTimer = null;
  let unfocus = null;
  let pendingVersion = null;
  function set(next) {
    current = next;
    const nextSignature = signature(next);
    if (nextSignature !== lastSignature) {
      lastSignature = nextSignature;
      broadcast2(UPDATE_STATE_CHANNEL, next);
    }
    return current;
  }
  if (verdict.supported) {
    updater.autoDownload = false;
    updater.autoInstallOnAppQuit = true;
    updater.on("checking-for-update", () => {
      set({ phase: "checking" });
    });
    updater.on("update-available", (info) => {
      pendingVersion = info.version;
      set({
        phase: "available",
        version: info.version,
        notes: readNotes(info),
        sizeBytes: readSizeBytes(info)
      });
    });
    updater.on("update-not-available", () => {
      pendingVersion = null;
      set({ phase: "idle", checkedAt: now() });
    });
    updater.on("download-progress", (progress2) => {
      const percent = Number.isFinite(progress2.percent) ? Math.max(0, Math.min(100, Math.round(progress2.percent))) : 0;
      const rate = Number.isFinite(progress2.bytesPerSecond) ? Math.max(0, Math.round(progress2.bytesPerSecond)) : 0;
      set({
        phase: "downloading",
        version: pendingVersion ?? "",
        percent,
        bytesPerSecond: rate
      });
    });
    updater.on("update-downloaded", (event) => {
      pendingVersion = event.version;
      set({ phase: "ready", version: event.version });
    });
    updater.on("error", (error) => {
      if (read().phase === "ready") return;
      set({ phase: "error", message: messageOf$1(error) });
    });
  }
  async function check2(options) {
    if (manualInUse()) {
      if (read().phase === "downloading") return read();
      set({ phase: "checking" });
      try {
        const found = await manual.check();
        return found === null ? set({ phase: "idle", checkedAt: now() }) : set({ phase: "available", version: found.version, notes: found.notes, sizeBytes: found.sizeBytes });
      } catch (error) {
        return set({ phase: "error", message: messageOf$1(error) });
      }
    }
    const before = read();
    if (before.phase === "unsupported") return before;
    const automatic = options?.automatic === true;
    if (before.phase === "downloading" || before.phase === "ready" || before.phase === "checking") {
      return before;
    }
    if (automatic && lastCheckStartedAt !== 0 && now() - lastCheckStartedAt < MIN_AUTOMATIC_INTERVAL_MS) {
      return before;
    }
    lastCheckStartedAt = now();
    set({ phase: "checking" });
    try {
      await updater.checkForUpdates();
    } catch (error) {
      return set({ phase: "error", message: messageOf$1(error) });
    }
    const after = read();
    if (after.phase === "checking") return set({ phase: "idle", checkedAt: now() });
    return after;
  }
  const manualInUse = () => manual !== null && !verdict.supported;
  async function download() {
    if (manualInUse()) {
      const offered2 = read();
      if (offered2.phase !== "available") return offered2;
      const version22 = offered2.version;
      set({ phase: "downloading", version: version22, percent: 0, bytesPerSecond: 0 });
      const done = await manual.download(version22, (percent, bytesPerSecond) => {
        const now2 = read();
        if (now2.phase === "downloading" && now2.version === version22) {
          set({ phase: "downloading", version: version22, percent, bytesPerSecond });
        }
      });
      return done.ok ? set({ phase: "ready", version: version22 }) : set({ phase: "error", message: done.message });
    }
    const offered = read();
    if (offered.phase !== "available") return offered;
    const version2 = offered.version;
    pendingVersion = version2;
    set({ phase: "downloading", version: version2, percent: 0, bytesPerSecond: 0 });
    try {
      await updater.downloadUpdate();
    } catch (error) {
      return set({ phase: "error", message: messageOf$1(error) });
    }
    const after = read();
    if (after.phase === "downloading") return set({ phase: "ready", version: version2 });
    return after;
  }
  async function installNow() {
    const staged2 = read();
    if (staged2.phase !== "ready") return staged2;
    if (manualInUse()) {
      const done = await manual.install(staged2.version);
      return done.ok ? staged2 : set({ phase: "error", message: done.message });
    }
    updater.quitAndInstall();
    return staged2;
  }
  function start() {
    if (read().phase === "unsupported") return;
    if (launchTimer !== null || unfocus !== null) return;
    launchTimer = setTimeout(() => {
      launchTimer = null;
      void check2({ automatic: true });
    }, LAUNCH_DELAY_MS);
    launchTimer.unref?.();
    unfocus = (deps.onFocus ?? appWindowFocus)(() => {
      void check2({ automatic: true });
    });
  }
  function stop() {
    if (launchTimer !== null) {
      clearTimeout(launchTimer);
      launchTimer = null;
    }
    if (unfocus !== null) {
      unfocus();
      unfocus = null;
    }
  }
  return {
    state: () => current,
    check: check2,
    download,
    installNow,
    start,
    stop
  };
}
function registerUpdateIpc(ipcMain, deps) {
  const controller = createUpdateController(deps);
  ipcMain.handle("update:get", () => controller.state());
  ipcMain.handle("update:check", () => controller.check({ automatic: false }));
  ipcMain.handle("update:download", () => controller.download());
  ipcMain.handle("update:install", () => controller.installNow());
  controller.start();
  return controller;
}
const run$7 = node_util.promisify(node_child_process.execFile);
const PROGRESS_INTERVAL_MS = 250;
const MAX_FEED_BYTES = 1024 * 1024;
const SHA512_BYTES = 64;
const DITTO = "/usr/bin/ditto";
const PLUTIL = "/usr/bin/plutil";
const SAFE_VERSION = /^[0-9A-Za-z][0-9A-Za-z._+-]*$/;
function unquote(value) {
  const single = /^'(.*)'$/s.exec(value);
  if (single) return single[1];
  const double = /^"(.*)"$/s.exec(value);
  return double ? double[1] : value;
}
function splitKeyValue(line) {
  const colon = line.indexOf(":");
  if (colon <= 0) return null;
  const key = line.slice(0, colon).trim();
  if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(key)) return null;
  return { key, value: unquote(line.slice(colon + 1).trim()) };
}
function parseFeed(text2) {
  let version2 = null;
  const files = [];
  let inFiles = false;
  let filesIndent = 0;
  let current = null;
  const flush = () => {
    if (current && typeof current.url === "string" && current.url !== "" && typeof current.sha512 === "string" && current.sha512 !== "" && typeof current.size === "number") {
      files.push({ url: current.url, sha512: current.sha512, size: current.size });
    }
    current = null;
  };
  for (const raw of text2.split(/\r?\n/)) {
    const trimmed = raw.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    const indent = raw.length - raw.trimStart().length;
    if (inFiles && indent <= filesIndent) {
      flush();
      inFiles = false;
    }
    if (!inFiles) {
      if (trimmed === "files:") {
        inFiles = true;
        filesIndent = indent;
        continue;
      }
      const pair2 = splitKeyValue(trimmed);
      if (pair2 && pair2.key === "version" && version2 === null) version2 = pair2.value;
      continue;
    }
    let body = trimmed;
    if (body === "-") {
      flush();
      current = {};
      continue;
    }
    if (body.startsWith("- ")) {
      flush();
      current = {};
      body = body.slice(2).trim();
    }
    const pair = splitKeyValue(body);
    if (!pair || current === null) continue;
    if (pair.key === "url") current.url = pair.value;
    else if (pair.key === "sha512") current.sha512 = pair.value;
    else if (pair.key === "size") {
      const size = Number(pair.value);
      if (Number.isSafeInteger(size) && size > 0) current.size = size;
    }
  }
  flush();
  if (version2 === null || !SAFE_VERSION.test(version2) || version2.length > 64) return null;
  return { version: version2, files };
}
function chooseArchive(feed) {
  return feed.files.find((file) => {
    const path = file.url.split(/[?#]/)[0];
    return path.toLowerCase().endsWith(".zip");
  }) ?? null;
}
function resolveAsset(file, feedUrl) {
  let resolved;
  let feed;
  try {
    feed = new URL(feedUrl);
    resolved = new URL(file.url, feedUrl);
  } catch {
    return null;
  }
  if (resolved.protocol !== "https:") return null;
  if (resolved.origin !== feed.origin) return null;
  let fileName;
  try {
    fileName = decodeURIComponent(node_path.basename(resolved.pathname));
  } catch {
    return null;
  }
  if (fileName === "" || fileName.startsWith("-") || fileName.includes("/")) return null;
  if (fileName.includes("\\") || fileName === "." || fileName === "..") return null;
  if (!fileName.toLowerCase().endsWith(".zip")) return null;
  return { url: resolved.toString(), fileName };
}
function updatesRoot(userDataPath) {
  return node_path.join(userDataPath, "updates");
}
function stagingDir(version2, userDataPath) {
  return node_path.join(updatesRoot(userDataPath), version2);
}
function extractDir(version2, userDataPath) {
  return node_path.join(stagingDir(version2, userDataPath), "bundle");
}
const EXTRACTION_MARKER = ".verified-sha512";
async function readExtractionMarker(bundleDir) {
  try {
    const value = (await promises.readFile(node_path.join(bundleDir, EXTRACTION_MARKER), "utf8")).trim();
    return value === "" ? null : value;
  } catch {
    return null;
  }
}
function canonicalDigest(sha512) {
  return decodeSha512(sha512)?.toString("base64") ?? null;
}
function decodeSha512(value) {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return null;
  const bytes2 = Buffer.from(value, "base64");
  return bytes2.length === SHA512_BYTES ? bytes2 : null;
}
async function sha512OfFile(path) {
  const hash2 = node_crypto.createHash("sha512");
  const handle2 = await promises.open(path, "r");
  try {
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    for (; ; ) {
      const { bytesRead } = await handle2.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      hash2.update(buffer.subarray(0, bytesRead));
    }
  } finally {
    await handle2.close();
  }
  return hash2.digest();
}
async function verifyArchive(path, expected) {
  const digest = decodeSha512(expected.sha512);
  if (!digest) {
    return {
      ok: false,
      reason: "checksum-mismatch",
      message: "The release feed carried a sha512 that is not a valid base64 sha512 digest."
    };
  }
  const actualSize = (await promises.stat(path)).size;
  if (actualSize !== expected.size) {
    return {
      ok: false,
      reason: "size-mismatch",
      message: `The download is ${actualSize} bytes but the release feed says ${expected.size}. The file was removed.`
    };
  }
  const actual = await sha512OfFile(path);
  if (actual.length !== digest.length || !node_crypto.timingSafeEqual(actual, digest)) {
    return {
      ok: false,
      reason: "checksum-mismatch",
      message: "The download is the right length but its sha512 does not match the release feed, so these are not the published bytes. The file was removed."
    };
  }
  return { ok: true };
}
const EXTRACT_TIMEOUT_MS = 15 * 6e4;
const PLIST_TIMEOUT_MS = 6e4;
const dittoExtract = async (archivePath, destDir) => {
  await run$7(DITTO, ["-x", "-k", "--", archivePath, destDir], { timeout: EXTRACT_TIMEOUT_MS });
};
const plutilReadPlist = async (path) => {
  const { stdout } = await run$7(PLUTIL, ["-convert", "json", "-o", "-", "--", path], {
    maxBuffer: 4 * 1024 * 1024,
    timeout: PLIST_TIMEOUT_MS
  });
  const parsed = JSON.parse(stdout);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("the plist did not convert to an object");
  }
  return parsed;
};
function stringField(plist, key) {
  const value = plist[key];
  return typeof value === "string" && value.trim() !== "" ? value : null;
}
async function inspectBundle(directory, readPlist = plutilReadPlist) {
  let entries2;
  try {
    entries2 = (await promises.readdir(directory, { withFileTypes: true })).filter((entry) => entry.isDirectory() && entry.name.endsWith(".app")).map((entry) => entry.name);
  } catch {
    return { ok: false, message: "The archive did not extract into a readable directory." };
  }
  if (entries2.length === 0) {
    return { ok: false, message: "The archive contains no .app bundle, so it is not an app." };
  }
  if (entries2.length > 1) {
    return {
      ok: false,
      message: `The archive contains ${entries2.length} .app bundles; a release contains one.`
    };
  }
  const bundlePath = node_path.join(directory, entries2[0]);
  const plistPath = node_path.join(bundlePath, "Contents", "Info.plist");
  let plist;
  try {
    plist = await readPlist(plistPath);
  } catch {
    return { ok: false, message: `${entries2[0]} has no readable Contents/Info.plist.` };
  }
  const executableName = stringField(plist, "CFBundleExecutable");
  const version2 = stringField(plist, "CFBundleShortVersionString");
  if (!executableName || !version2) {
    return {
      ok: false,
      message: `${entries2[0]} has an Info.plist with no CFBundleExecutable or no version.`
    };
  }
  if (executableName.includes("/") || executableName.includes("\\")) {
    return { ok: false, message: `${entries2[0]} names an executable outside its own bundle.` };
  }
  const executablePath = node_path.join(bundlePath, "Contents", "MacOS", executableName);
  let mode;
  try {
    const info = await promises.stat(executablePath);
    if (!info.isFile()) {
      return { ok: false, message: `${entries2[0]} has no binary at Contents/MacOS/${executableName}.` };
    }
    mode = info.mode;
  } catch {
    return { ok: false, message: `${entries2[0]} has no binary at Contents/MacOS/${executableName}.` };
  }
  if ((mode & 73) === 0) {
    return {
      ok: false,
      message: `${entries2[0]}'s binary is not executable, so the extraction lost its permissions.`
    };
  }
  return { ok: true, bundle: { path: bundlePath, executableName, executablePath, version: version2 } };
}
class Cancelled extends Error {
}
function progressReporter(version2, total, emit2, intervalMs, now) {
  let lastEmitAt = 0;
  let lastPercent = -1;
  const send2 = (transferred) => {
    if (!emit2) return;
    const percent = Math.min(100, Math.floor(transferred / total * 100));
    lastEmitAt = now();
    lastPercent = percent;
    emit2({ version: version2, transferred, total, percent });
  };
  return {
    tick: (transferred) => {
      if (!emit2) return;
      if (now() - lastEmitAt < intervalMs) return;
      send2(transferred);
    },
    // The last tick is unconditional: a throttle that swallows it leaves a bar
    // stopped at 97% next to a finished download.
    final: (transferred) => {
      if (!emit2) return;
      const percent = Math.min(100, Math.floor(transferred / total * 100));
      if (percent === lastPercent && lastPercent === 100) return;
      send2(transferred);
    }
  };
}
async function streamToFile(body, destination, report, signal) {
  const handle2 = await promises.open(destination, "wx");
  const reader = body.getReader();
  let transferred = 0;
  try {
    for (; ; ) {
      if (signal?.aborted) throw new Cancelled();
      const { done, value } = await reader.read();
      if (done) break;
      if (!value || value.length === 0) continue;
      await handle2.write(value);
      transferred += value.length;
      report.tick(transferred);
    }
    await handle2.sync();
  } finally {
    await reader.cancel().catch(() => {
    });
    await handle2.close();
  }
  report.final(transferred);
  return transferred;
}
class FeedTooLarge extends Error {
}
async function readTextBounded(body, max) {
  const reader = body.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (; ; ) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      size += value.length;
      if (size > max) throw new FeedTooLarge(`the feed exceeded ${max} bytes`);
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {
    });
  }
  return Buffer.concat(chunks).toString("utf8");
}
async function removeOtherVersions(root, keep) {
  let entries2;
  try {
    entries2 = (await promises.readdir(root, { withFileTypes: true })).filter((entry) => entry.isDirectory()).map((entry) => entry.name);
  } catch {
    return;
  }
  for (const name of entries2) {
    if (name === keep) continue;
    await promises.rm(node_path.join(root, name), { recursive: true, force: true }).catch(() => {
    });
  }
}
function failure$1(reason, message, detail = null) {
  return { ok: false, reason, message, detail };
}
function errorCode$2(error) {
  if (typeof error !== "object" || error === null || !("code" in error)) return "";
  const { code } = error;
  return typeof code === "string" ? code : "";
}
function detailOf(error) {
  if (error instanceof Error) {
    const stderr = error.stderr;
    if (typeof stderr === "string" && stderr.trim() !== "") return stderr.trim().slice(0, 400);
    return error.message.trim().slice(0, 400) || null;
  }
  const text2 = String(error).trim();
  return text2 === "" ? null : text2.slice(0, 400);
}
async function runFetchUpdate(options) {
  const {
    feedUrl,
    userDataPath,
    platform,
    fetch: fetchImpl,
    onProgress,
    signal,
    extract = dittoExtract,
    readPlist = plutilReadPlist,
    progressIntervalMs = PROGRESS_INTERVAL_MS,
    now = () => Date.now()
  } = options;
  if (platform !== "darwin") {
    return failure$1(
      "unsupported-platform",
      "Downloading an update this way is macOS-only; this build runs on " + platform + "."
    );
  }
  if (signal?.aborted) return failure$1("cancelled", "The update download was cancelled.");
  let feedText;
  try {
    const response = await fetchImpl(feedUrl, { signal });
    if (!response.ok) {
      return failure$1(
        "feed-unreachable",
        `The release feed could not be read (HTTP ${response.status}).`
      );
    }
    if (!response.body) return failure$1("feed-unreachable", "The release feed came back empty.");
    feedText = await readTextBounded(response.body, MAX_FEED_BYTES);
  } catch (error) {
    if (signal?.aborted) return failure$1("cancelled", "The update download was cancelled.");
    if (error instanceof FeedTooLarge) {
      return failure$1(
        "feed-unreadable",
        `The release feed is larger than ${MAX_FEED_BYTES} bytes, so it is not a release feed.`
      );
    }
    return failure$1("feed-unreachable", "The release feed could not be reached.", detailOf(error));
  }
  const feed = parseFeed(feedText);
  if (!feed) {
    return failure$1(
      "feed-unreadable",
      "The release feed did not contain a usable version, so there is nothing to download."
    );
  }
  const archive = chooseArchive(feed);
  if (!archive) {
    const listed = feed.files.map((file) => file.url).join(", ");
    return failure$1(
      "no-zip",
      `Release ${feed.version} publishes no .zip to download` + (listed === "" ? "." : `, only ${listed}. A .dmg cannot be unpacked without mounting it.`)
    );
  }
  const asset = resolveAsset(archive, feedUrl);
  if (!asset) {
    return failure$1(
      "feed-unreadable",
      `Release ${feed.version} names an archive this app will not fetch: it must be an https .zip.`
    );
  }
  const { version: version2 } = feed;
  const staging = stagingDir(version2, userDataPath);
  const archivePath = node_path.join(staging, asset.fileName);
  const partPath = `${archivePath}.part`;
  const bundleDir = extractDir(version2, userDataPath);
  try {
    await promises.mkdir(staging, { recursive: true });
  } catch (error) {
    return failure$1("download-failed", "The staging directory could not be created.", detailOf(error));
  }
  await removeOtherVersions(updatesRoot(userDataPath), version2);
  const expectedDigest = canonicalDigest(archive.sha512);
  const finish = async (reused) => {
    const marker = await readExtractionMarker(bundleDir);
    if (expectedDigest !== null && marker === expectedDigest) {
      const staged2 = await inspectBundle(bundleDir, readPlist);
      if (staged2.ok && staged2.bundle.version === version2) {
        return {
          ok: true,
          version: version2,
          archivePath,
          bundlePath: staged2.bundle.path,
          sizeBytes: archive.size,
          reused
        };
      }
    }
    await promises.rm(bundleDir, { recursive: true, force: true }).catch(() => {
    });
    try {
      await extract(archivePath, bundleDir);
    } catch (error) {
      return failure$1(
        "extract-failed",
        `The verified archive for ${version2} could not be unpacked.`,
        detailOf(error)
      );
    }
    const verdict = await inspectBundle(bundleDir, readPlist);
    if (!verdict.ok) {
      await promises.rm(bundleDir, { recursive: true, force: true }).catch(() => {
      });
      return failure$1("not-a-bundle", verdict.message);
    }
    if (verdict.bundle.version !== version2) {
      await promises.rm(bundleDir, { recursive: true, force: true }).catch(() => {
      });
      return failure$1(
        "version-mismatch",
        `The feed promised ${version2} but the downloaded app reports ${verdict.bundle.version}.`
      );
    }
    if (expectedDigest !== null) {
      try {
        await promises.writeFile(node_path.join(bundleDir, EXTRACTION_MARKER), `${expectedDigest}
`);
      } catch (error) {
        await promises.rm(bundleDir, { recursive: true, force: true }).catch(() => {
        });
        return failure$1(
          "extract-failed",
          `The update for ${version2} unpacked but could not be recorded as verified, so it was discarded rather than left looking finished.`,
          detailOf(error)
        );
      }
    }
    return {
      ok: true,
      version: version2,
      archivePath,
      bundlePath: verdict.bundle.path,
      sizeBytes: archive.size,
      reused
    };
  };
  let alreadyStaged = false;
  try {
    alreadyStaged = (await promises.stat(archivePath)).isFile();
  } catch {
    alreadyStaged = false;
  }
  if (alreadyStaged) {
    const verified2 = await verifyArchive(archivePath, archive).catch(
      () => ({
        ok: false,
        reason: "checksum-mismatch",
        message: "The staged archive could not be read."
      })
    );
    if (verified2.ok) return finish(true);
    await promises.rm(archivePath, { force: true }).catch(() => {
    });
    await promises.rm(bundleDir, { recursive: true, force: true }).catch(() => {
    });
  }
  await promises.rm(partPath, { force: true }).catch(() => {
  });
  const report = progressReporter(version2, archive.size, onProgress, progressIntervalMs, now);
  try {
    const response = await fetchImpl(asset.url, { signal });
    if (!response.ok) {
      return failure$1(
        "download-failed",
        `Downloading ${asset.fileName} failed (HTTP ${response.status}).`
      );
    }
    if (!response.body) {
      return failure$1("download-failed", `The server returned no body for ${asset.fileName}.`);
    }
    const declared = response.headers.get("content-length");
    const encoded = response.headers.get("content-encoding");
    if (declared !== null && !encoded) {
      const length = Number(declared);
      if (Number.isSafeInteger(length) && length > 0 && length !== archive.size) {
        return failure$1(
          "size-mismatch",
          `The server offers ${asset.fileName} as ${length} bytes but the release feed says ${archive.size}. Nothing was downloaded.`
        );
      }
    }
    await streamToFile(response.body, partPath, report, signal);
  } catch (error) {
    if (errorCode$2(error) === "EEXIST") {
      return failure$1(
        "download-failed",
        `Another copy of this app is already downloading ${asset.fileName}. Nothing was changed here; wait for that one to finish, or close it and try again.`
      );
    }
    await promises.rm(partPath, { force: true }).catch(() => {
    });
    if (error instanceof Cancelled || signal?.aborted) {
      return failure$1("cancelled", "The update download was cancelled.");
    }
    return failure$1(
      "download-failed",
      `Downloading ${asset.fileName} stopped before it finished.`,
      detailOf(error)
    );
  }
  let verified;
  try {
    verified = await verifyArchive(partPath, archive);
  } catch (error) {
    await promises.rm(partPath, { force: true }).catch(() => {
    });
    return failure$1(
      "download-failed",
      `The download of ${asset.fileName} could not be read back to verify it.`,
      detailOf(error)
    );
  }
  if (!verified.ok) {
    await promises.rm(partPath, { force: true }).catch(() => {
    });
    return failure$1(verified.reason, verified.message);
  }
  try {
    await promises.rename(partPath, archivePath);
  } catch (error) {
    await promises.rm(partPath, { force: true }).catch(() => {
    });
    return failure$1(
      "download-failed",
      "The verified download could not be moved into place.",
      detailOf(error)
    );
  }
  return finish(false);
}
const inFlight$2 = /* @__PURE__ */ new Map();
function fetchUpdate(options) {
  const key = updatesRoot(options.userDataPath);
  const previous = inFlight$2.get(key) ?? Promise.resolve();
  const result = previous.then(
    () => runFetchUpdate(options),
    () => runFetchUpdate(options)
  );
  const link = result.then(
    () => {
    },
    () => {
    }
  );
  void link.then(() => {
    if (inFlight$2.get(key) === link) inFlight$2.delete(key);
  });
  inFlight$2.set(key, link);
  return result;
}
function installedBundlePath(exePath) {
  if (!exePath.startsWith("/")) return null;
  const segments = exePath.split("/");
  if (segments.length < 4) return null;
  const binary = segments[segments.length - 1];
  const macos = segments[segments.length - 2];
  const contents = segments[segments.length - 3];
  const bundle = segments[segments.length - 4];
  if (binary === "") return null;
  if (macos !== "MacOS" || contents !== "Contents") return null;
  if (!bundle.endsWith(".app") || bundle === ".app") return null;
  for (let i = 0; i < segments.length - 4; i += 1) {
    if (segments[i].endsWith(".app")) return null;
  }
  return segments.slice(0, segments.length - 3).join("/");
}
function bundleParent(bundlePath) {
  const cut = bundlePath.lastIndexOf("/");
  return cut <= 0 ? "/" : bundlePath.slice(0, cut);
}
function bundleExecutableDir(bundlePath) {
  return `${bundlePath}/Contents/MacOS`;
}
function bundleInfoPlist(bundlePath) {
  return `${bundlePath}/Contents/Info.plist`;
}
function backupPathFor$1(bundlePath, at) {
  return `${bundlePath}.old-${at}`;
}
const SCRIPT_NAME = "install-swap.sh";
const LOG_NAME = "install-swap.log";
function readShortVersion(plistXml) {
  const match = /<key>\s*CFBundleShortVersionString\s*<\/key>\s*<string>([^<]*)<\/string>/.exec(
    plistXml
  );
  const value = match?.[1]?.trim();
  return value === void 0 || value === "" ? null : value;
}
function splitVersion(version2) {
  const withoutBuild = version2.trim().replace(/^v/, "").split("+")[0];
  const [releasePart, ...prereleaseParts] = withoutBuild.split("-");
  const release2 = releasePart.split(".").map((part) => {
    const n = Number.parseInt(part, 10);
    return Number.isFinite(n) ? n : 0;
  });
  const prerelease = prereleaseParts.join("-").split(".").filter((p) => p !== "");
  return { release: release2, prerelease };
}
function compareVersions(a, b) {
  const left = splitVersion(a);
  const right = splitVersion(b);
  const length = Math.max(left.release.length, right.release.length);
  for (let i = 0; i < length; i += 1) {
    const l = left.release[i] ?? 0;
    const r = right.release[i] ?? 0;
    if (l !== r) return l < r ? -1 : 1;
  }
  if (left.prerelease.length === 0 && right.prerelease.length === 0) return 0;
  if (left.prerelease.length === 0) return 1;
  if (right.prerelease.length === 0) return -1;
  const idents = Math.max(left.prerelease.length, right.prerelease.length);
  for (let i = 0; i < idents; i += 1) {
    const l = left.prerelease[i];
    const r = right.prerelease[i];
    if (l === void 0) return -1;
    if (r === void 0) return 1;
    if (l === r) continue;
    const ln = /^\d+$/.test(l) ? Number.parseInt(l, 10) : null;
    const rn = /^\d+$/.test(r) ? Number.parseInt(r, 10) : null;
    if (ln !== null && rn !== null) return ln < rn ? -1 : 1;
    if (ln !== null) return -1;
    if (rn !== null) return 1;
    return l < r ? -1 : 1;
  }
  return 0;
}
function shellQuote$1(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}
const SWAP_EXIT = {
  ok: 0,
  /** The app never exited. Nothing was moved. */
  timeout: 3,
  /** The staged bundle was gone or malformed. Nothing was moved. */
  stagedInvalid: 4,
  /** The current bundle could not be moved aside. It is untouched. */
  backupFailed: 5,
  /** Rolled back; the original app is back where it was. */
  rolledBack: 7,
  /** Rollback itself failed. The original is at the backup path. */
  rollbackFailed: 8
};
function swapScript(plan) {
  const q = shellQuote$1;
  const pollSeconds = Number.isFinite(plan.pollSeconds) && plan.pollSeconds > 0 ? plan.pollSeconds : DEFAULT_POLL_SECONDS;
  const pollCeiling = Math.ceil(MAX_WAIT_MS / (pollSeconds * 1e3));
  const requested = Math.trunc(plan.maxPolls);
  const maxPolls = Math.min(
    Number.isFinite(requested) && requested >= 1 ? requested : Math.ceil(DEFAULT_WAIT_TIMEOUT_MS / (pollSeconds * 1e3)),
    pollCeiling
  );
  if (!Number.isSafeInteger(plan.pid) || plan.pid < 1) {
    throw new RangeError(`swapScript needs a real process id to wait for, got ${plan.pid}`);
  }
  const quarantine2 = plan.clearQuarantine ? `
# Asked for explicitly by the caller. A bundle unzipped from a download carries
# com.apple.quarantine, and Gatekeeper refuses to open an unsigned quarantined
# app — which would leave the user with a "successful" update they cannot run.
if ! /usr/bin/xattr -d -r com.apple.quarantine "$INSTALL" >/dev/null 2>&1; then
  log 'swap: could not clear the quarantine flag; the app may need Open Anyway'
fi
` : "";
  return `#!/bin/sh
# Terminal Deck update swap. Generated by src/main/updates/install-update.ts.
#
# Every path is a single-quoted literal: the product name contains a space and
# the user chose the directory it sits in.
#
# No 'set -e' on purpose — the rollback below must run to the end even when the
# command before it failed. That is the whole point of it.
set -u

PID=${q(String(plan.pid))}
INSTALL=${q(plan.bundlePath)}
STAGED=${q(plan.stagedBundlePath)}
BACKUP=${q(plan.backupPath)}
PARTIAL=${q(`${plan.backupPath}.partial`)}
LOG=${q(plan.logPath)}
OPEN_BIN=${q(plan.openBinary)}
POLL=${q(String(pollSeconds))}
MAX_POLLS=${q(String(maxPolls))}

# Never hold a working directory inside a path that is about to be renamed.
cd / || exit 1

log() {
  printf '%s %s\\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$LOG" 2>/dev/null
}

log "swap: helper started, waiting for pid $PID"

# kill -0 asks "does this pid exist and may I signal it" without signalling.
# It is the app's own pid, same user, so a permission failure is not a case
# that arises. A recycled pid would only make us wait longer and then abort
# safely, which is why the loop is bounded rather than open-ended.
polls=0
while kill -0 "$PID" 2>/dev/null; do
  polls=$((polls + 1))
  if [ "$polls" -ge "$MAX_POLLS" ]; then
    log "swap: ABORT - pid $PID is still running; nothing was moved"
    exit ${SWAP_EXIT.timeout}
  fi
  sleep "$POLL"
done

log 'swap: the app has exited'

if [ "$STAGED" = "$INSTALL" ]; then
  log 'swap: ABORT - the staged bundle is the installed bundle; nothing was moved'
  exit ${SWAP_EXIT.stagedInvalid}
fi

# Re-checked here and not only before the quit: the app has been down for a
# moment, and macOS is free to purge a cache directory in that moment.
#
# This check sitting *before* the backup move is also what makes a second
# helper harmless. If two ever run — a retry after a spawn that reported
# failure but had already started — whichever loses the race finds the staged
# bundle already moved away and stops here, before it can move anything.
if [ ! -d "$STAGED/Contents/MacOS" ]; then
  log "swap: ABORT - no bundle at $STAGED; nothing was moved"
  exit ${SWAP_EXIT.stagedInvalid}
fi

# mv into an existing directory moves *inside* it. That would nest the app one
# level down and leave the install path empty, so both destinations are checked
# to be free before anything is renamed.
#
# -e follows symlinks and is therefore blind to a dangling one, which is a path
# that is very much not free: renaming a directory onto it fails with ENOTDIR.
# -L is what sees it. Better to stop here, with nothing moved, than at the mv.
if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
  log "swap: ABORT - something already exists at $BACKUP; nothing was moved"
  exit ${SWAP_EXIT.backupFailed}
fi

if ! mv -f "$INSTALL" "$BACKUP"; then
  log "swap: ABORT - could not move the current app aside; it is untouched at $INSTALL"
  exit ${SWAP_EXIT.backupFailed}
fi
log "swap: the current app is safe at $BACKUP"

# What "the new app landed" has to mean before the backup may be removed.
#
# -d on its own follows symlinks, so a Contents/MacOS that is a link pointing
# somewhere that still resolves after the move would satisfy it — and the
# backup would then be deleted on the strength of a link rather than an
# application. The directory has to be a real one, and the Info.plist every
# bundle carries has to be a real file, before the only copy of the user's old
# app is destroyed.
bundle_landed() {
  [ -d "$INSTALL/Contents/MacOS" ] &&
    [ ! -L "$INSTALL/Contents/MacOS" ] &&
    [ -f "$INSTALL/Contents/Info.plist" ]
}

# From here on the user has no application at $INSTALL, so every branch below
# ends either with the new bundle there or with the backup put back.
if mv -f "$STAGED" "$INSTALL" && bundle_landed; then
  log "swap: the new app is in place at $INSTALL"
${quarantine2}
  # The only destructive command in this file, and it runs only here: after the
  # new bundle is verified in place. The case guard re-checks that BACKUP is
  # the path this script named, so a mangled variable removes nothing.
  case "$BACKUP" in
    "$INSTALL".old-*)
      if rm -rf "$BACKUP"; then
        log 'swap: removed the backup'
      else
        log "swap: could not remove the backup; it is at $BACKUP"
      fi
      ;;
    *)
      log "swap: refusing to remove $BACKUP - it is not the backup path this script made"
      ;;
  esac

  if ! "$OPEN_BIN" -a "$INSTALL" >/dev/null 2>&1; then
    log 'swap: the new app is installed but could not be launched'
  fi
  log 'swap: done'
  exit ${SWAP_EXIT.ok}
fi

log 'swap: FAILED to put the new app in place; rolling back'

# Three ways something can be sitting on the install path here: the mv
# succeeded but what landed is not a bundle, a cross-volume mv degraded into
# copy-then-delete and left a partial one, or what the mv moved in was a
# symlink and it now dangles. Either way it is moved out of the way rather than
# deleted — the restore below needs the path free, and a bad bundle is still
# evidence of what went wrong.
#
# -L is not decoration. -e follows symlinks, so it answers "no" for a dangling
# one, this branch would be skipped with the link still in place, and the
# restore below would then fail with ENOTDIR — leaving the user no application
# at $INSTALL and their real one stranded under a name they never chose. That
# is the exact outcome this whole file exists to prevent, so the test for the
# path being occupied has to see links as well as things links point at.
if [ -e "$INSTALL" ] || [ -L "$INSTALL" ]; then
  if mv -f "$INSTALL" "$PARTIAL"; then
    log "swap: moved the unusable bundle to $PARTIAL"
  else
    log "swap: CRITICAL - $INSTALL is occupied and could not be cleared; your app is at $BACKUP"
    exit ${SWAP_EXIT.rollbackFailed}
  fi
fi

if mv -f "$BACKUP" "$INSTALL"; then
  log "swap: rolled back - the original app is back at $INSTALL"
  if ! "$OPEN_BIN" -a "$INSTALL" >/dev/null 2>&1; then
    log 'swap: the original app is restored but could not be relaunched'
  fi
  exit ${SWAP_EXIT.rolledBack}
fi

log "swap: CRITICAL - rollback failed; your app is at $BACKUP, move it back to $INSTALL"
exit ${SWAP_EXIT.rollbackFailed}
`;
}
const NOT_A_BUNDLE = "This build is not running from an application bundle, so there is nothing to replace. Download the new version from Releases instead.";
function errorCode$1(error) {
  if (typeof error !== "object" || error === null || !("code" in error)) return "";
  const { code } = error;
  return typeof code === "string" ? code : "";
}
async function isDirectory(fs, path) {
  try {
    return (await fs.stat(path)).isDirectory();
  } catch {
    return false;
  }
}
async function canInstallInPlace(options) {
  const { environment, fs } = options;
  if (environment.platform !== "darwin") {
    return {
      ok: false,
      block: "unsupported-platform",
      message: "In-place updates are only implemented for macOS on this build."
    };
  }
  const bundlePath = installedBundlePath(environment.exePath);
  if (bundlePath === null) {
    return { ok: false, block: "not-a-bundle", message: NOT_A_BUNDLE };
  }
  if (!await isDirectory(fs, bundleExecutableDir(bundlePath))) {
    return {
      ok: false,
      block: "bundle-incomplete",
      message: `The application at ${bundlePath} is missing Contents/MacOS, so it is not a bundle this can safely replace. Download the new version from Releases instead.`
    };
  }
  const parentPath = bundleParent(bundlePath);
  for (const [path, what] of [
    [bundlePath, "the application"],
    [parentPath, "the folder it is in"]
  ]) {
    try {
      await fs.access(path, node_fs.constants.W_OK);
    } catch (error) {
      const code = errorCode$1(error);
      const why = code === "EROFS" ? `${path} is on a read-only volume. If you are running the app from the disk image, drag it to your Applications folder first, then update.` : `${path} is not writable by this account, so ${what} cannot be replaced. Update from an account that owns it, or download the new version from Releases.`;
      return { ok: false, block: "not-writable", message: why };
    }
  }
  return { ok: true, bundlePath, parentPath };
}
const DEFAULT_OPEN_BINARY = "/usr/bin/open";
const DEFAULT_POLL_SECONDS = 0.25;
const DEFAULT_WAIT_TIMEOUT_MS = 6e4;
const MAX_WAIT_MS = 15 * 6e4;
async function appendLog(fs, logPath, line) {
  try {
    await fs.appendFile(logPath, `${(/* @__PURE__ */ new Date()).toISOString()} ${line}
`);
  } catch {
  }
}
async function installStagedUpdate(options) {
  const { fs, stagingDir: stagingDir2, stagedBundlePath, currentVersion } = options;
  const now = options.now ?? (() => Date.now());
  const logPath = node_path.join(stagingDir2, LOG_NAME);
  const capability = await canInstallInPlace({ environment: options.environment, fs });
  if (!capability.ok) {
    await appendLog(fs, logPath, `refused (${capability.block}): ${capability.message}`);
    return { started: false, block: capability.block, message: capability.message };
  }
  const { bundlePath } = capability;
  if (stagedBundlePath === bundlePath) {
    const message = "The staged update is the installed application. Nothing to do.";
    await appendLog(fs, logPath, `refused (staged-invalid): ${message}`);
    return { started: false, block: "staged-invalid", message };
  }
  if (!stagedBundlePath.endsWith(".app") || !await isDirectory(fs, bundleExecutableDir(stagedBundlePath))) {
    const message = `The downloaded update at ${stagedBundlePath} is not a complete application bundle. Download it again, or get the new version from Releases.`;
    await appendLog(fs, logPath, `refused (staged-invalid): ${message}`);
    return { started: false, block: "staged-invalid", message };
  }
  let stagedVersion = null;
  try {
    stagedVersion = readShortVersion(await fs.readFile(bundleInfoPlist(stagedBundlePath), "utf8"));
  } catch {
    stagedVersion = null;
  }
  if (options.reinstall !== true) {
    if (stagedVersion === null) {
      const message = "The downloaded update does not report a version, so there is no way to tell whether it is newer than the app you are running. It was not installed.";
      await appendLog(fs, logPath, `refused (staged-version-unreadable): ${message}`);
      return { started: false, block: "staged-version-unreadable", message };
    }
    if (compareVersions(stagedVersion, currentVersion) <= 0) {
      const message = `The downloaded version (${stagedVersion}) is not newer than the one you are running (${currentVersion}), so it was not installed.`;
      await appendLog(fs, logPath, `refused (not-newer): ${message}`);
      return { started: false, block: "not-newer", message };
    }
  }
  const pid = options.pid ?? process.pid;
  const pollSeconds = options.pollSeconds ?? DEFAULT_POLL_SECONDS;
  const waitTimeoutMs = options.waitTimeoutMs ?? DEFAULT_WAIT_TIMEOUT_MS;
  if (!Number.isSafeInteger(pid) || pid < 1 || !Number.isFinite(pollSeconds) || pollSeconds <= 0 || !Number.isFinite(waitTimeoutMs) || waitTimeoutMs <= 0) {
    const message = "The update helper was given a process id or a timeout it cannot use, so nothing was changed. This is a bug in the app rather than anything you did.";
    await appendLog(fs, logPath, `refused (helper-failed): ${message}`);
    return { started: false, block: "helper-failed", message };
  }
  const backupPath = backupPathFor$1(bundlePath, now());
  const scriptPath = node_path.join(stagingDir2, SCRIPT_NAME);
  const script = swapScript({
    pid,
    bundlePath,
    stagedBundlePath,
    backupPath,
    logPath,
    openBinary: options.openBinary ?? DEFAULT_OPEN_BINARY,
    pollSeconds,
    maxPolls: Math.max(1, Math.ceil(waitTimeoutMs / (pollSeconds * 1e3))),
    clearQuarantine: options.clearQuarantine === true
  });
  await appendLog(
    fs,
    logPath,
    `installing ${stagedVersion ?? "an unversioned build"} over ${currentVersion} at ${bundlePath}`
  );
  let helper;
  try {
    await fs.mkdir(stagingDir2, { recursive: true });
    await fs.writeFile(scriptPath, script, { mode: 448 });
    helper = options.spawn("/bin/sh", [scriptPath], {
      detached: true,
      stdio: "ignore",
      cwd: "/"
    });
    helper.unref();
  } catch (error) {
    const message = "The update helper could not be started, so nothing was changed: " + (error instanceof Error ? error.message : String(error));
    await appendLog(fs, logPath, `refused (helper-failed): ${message}`);
    return { started: false, block: "helper-failed", message };
  }
  if (helper.pid === void 0) {
    const message = "The update helper did not start, so nothing was changed and your app is untouched. Try again, or download the new version from Releases.";
    await appendLog(fs, logPath, `refused (helper-failed): ${message}`);
    return { started: false, block: "helper-failed", message };
  }
  await appendLog(fs, logPath, `helper running as pid ${helper.pid}; quitting`);
  options.quit();
  return {
    started: true,
    bundlePath,
    backupPath,
    scriptPath,
    logPath,
    helperPid: helper.pid
  };
}
function isNewer(candidate, running) {
  const parts = (v) => v.replace(/^v/, "").split("-")[0].split(".").map((n) => Number.parseInt(n, 10) || 0);
  const a = parts(candidate);
  const b = parts(running);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return false;
}
function createManualStrategy(options) {
  const doFetch = options.fetch ?? globalThis.fetch;
  return {
    async check() {
      const response = await doFetch(options.feedUrl, { redirect: "follow" });
      if (!response.ok) throw new Error(`the release feed answered ${response.status}`);
      const text2 = (await response.text()).slice(0, MAX_FEED_BYTES);
      const feed = parseFeed(text2);
      if (feed === null) throw new Error("the release feed could not be read");
      if (!isNewer(feed.version, options.currentVersion)) return null;
      const archive = chooseArchive(feed);
      return {
        version: feed.version,
        // The feed carries no release notes; the panel shows the version and
        // links to Releases rather than inventing a summary.
        notes: null,
        sizeBytes: archive?.size ?? null
      };
    },
    async download(version2, onProgress) {
      let lastAt = Date.now();
      let lastBytes = 0;
      const result = await fetchUpdate({
        feedUrl: options.feedUrl,
        userDataPath: options.userDataPath,
        platform: options.platform,
        fetch: doFetch,
        onProgress: (p) => {
          const at = Date.now();
          const seconds = Math.max((at - lastAt) / 1e3, 1e-3);
          const rate = Math.max(p.transferred - lastBytes, 0) / seconds;
          lastAt = at;
          lastBytes = p.transferred;
          onProgress(p.percent, Math.round(rate));
        }
      });
      if (!result.ok) return { ok: false, message: result.message };
      if (result.version !== version2) {
        return {
          ok: false,
          message: `The release changed while downloading — expected ${version2}, found ${result.version}. Check again.`
        };
      }
      staged.set(result.version, { bundlePath: result.bundlePath, stagingDir: node_path.dirname(result.bundlePath) });
      return { ok: true };
    },
    async install(version2) {
      const where = staged.get(version2);
      if (!where) {
        return { ok: false, message: "Nothing is staged for this version. Download it again." };
      }
      const started = await installStagedUpdate({
        environment: { platform: options.platform, exePath: options.exePath },
        stagingDir: where.stagingDir,
        stagedBundlePath: where.bundlePath,
        currentVersion: options.currentVersion,
        // Entitled, per that module's own rule: these bytes were verified
        // against the sha512 in the release feed before they were unpacked, so
        // the quarantine flag is recording a provenance we already proved. It
        // is also what the README tells people to clear by hand today.
        clearQuarantine: true,
        fs: { access: promises.access, stat: promises.stat, mkdir: promises.mkdir, writeFile: promises.writeFile, appendFile: promises.appendFile, readFile: promises.readFile },
        spawn: node_child_process.spawn,
        quit: () => electron.app.quit()
      });
      return started.started ? { ok: true } : { ok: false, message: started.message };
    }
  };
}
const staged = /* @__PURE__ */ new Map();
const UNIX_BINARIES = [
  "/opt/homebrew/bin/tailscale",
  "/usr/local/bin/tailscale",
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
  "/usr/bin/tailscale"
];
const PROGRAM_FILES_KEYS = ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"];
function tailscaleCandidates(platform, env) {
  if (!isWindows(platform)) return [...UNIX_BINARIES];
  const roots = [];
  for (const key of PROGRAM_FILES_KEYS) {
    const root = env[key];
    if (typeof root === "string" && root.trim() !== "") roots.push(root);
  }
  if (roots.length === 0) roots.push("C:\\Program Files");
  const seen = /* @__PURE__ */ new Set();
  const paths = [];
  for (const root of roots) {
    const candidate = node_path.win32.join(root, "Tailscale", "tailscale.exe");
    if (seen.has(candidate.toLowerCase())) continue;
    seen.add(candidate.toLowerCase());
    paths.push(candidate);
  }
  return paths;
}
const TAILSCALE_BIN = "tailscale";
const run$6 = node_util.promisify(node_child_process.execFile);
const MAC_REASONS = {
  "not-installed": "Tailscale is not installed on this Mac, so there is no tailnet address to listen on. Your phone can still reach this Mac through the relay; the tailnet is the faster, direct route. To use it, install Tailscale from https://tailscale.com/download, sign in, then try again.",
  "not-running": "Tailscale is installed but its background service is not answering. Open Tailscale from your Applications folder to start it, then try again.",
  "logged-out": "Tailscale is installed but signed out on this Mac. Click the Tailscale icon in the menu bar, choose Log in, then try again.",
  stopped: "Tailscale is signed in but switched off on this Mac. Click the Tailscale icon in the menu bar, choose Connect, then try again.",
  "needs-approval": "This Mac is signed in but still waiting to join the tailnet. Approve it at https://login.tailscale.com/admin/machines, then try again.",
  starting: "Tailscale is still starting up on this Mac. Give it a few seconds, watch the Tailscale icon in the menu bar, then try again.",
  "no-address": "Tailscale is running but has not given this Mac a tailnet address yet. Click the Tailscale icon in the menu bar, switch it off and on again, then try again.",
  unreadable: "Could not read Tailscale’s status on this Mac. Run `tailscale status` in a terminal to see what it says, then try again."
};
const WINDOWS_REASONS = {
  "not-installed": "Tailscale is not installed on this PC, so there is no tailnet address to listen on. Your phone can still reach this PC through the relay; the tailnet is the faster, direct route. To use it, install Tailscale from https://tailscale.com/download, sign in, then try again.",
  "not-running": "Tailscale is installed but its background service is not answering. Open Tailscale from the Start menu, or run `net start Tailscale` in an administrator terminal, then try again.",
  "logged-out": "Tailscale is installed but signed out on this PC. Click the Tailscale icon in the notification area and choose Log in, or run `tailscale login` in a terminal, then try again.",
  stopped: "Tailscale is signed in but switched off on this PC. Click the Tailscale icon in the notification area and choose Connect, or run `tailscale up` in a terminal, then try again.",
  "needs-approval": "This PC is signed in but still waiting to join the tailnet. Approve it at https://login.tailscale.com/admin/machines, then try again.",
  starting: "Tailscale is still starting up on this PC. Give it a few seconds, or run `tailscale status` in a terminal to watch it come up, then try again.",
  "no-address": "Tailscale is running but has not given this PC a tailnet address yet. Run `tailscale down` and then `tailscale up` in a terminal, or switch it off and on from the notification area, then try again.",
  unreadable: "Could not read Tailscale’s status on this PC. Run `tailscale status` in a terminal to see what it says, then try again."
};
function blockedReasons(platform) {
  return isWindows(platform) ? WINDOWS_REASONS : MAC_REASONS;
}
const BLOCKED_REASONS = blockedReasons(currentPlatform());
function notReady(state, detail) {
  const trimmed = detail?.trim();
  const base = { ready: false, state, reason: BLOCKED_REASONS[state] };
  return trimmed ? { ...base, detail: trimmed } : base;
}
function isRecord$7(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function isTailnetAddress(value) {
  if (!node_net.isIPv4(value)) return false;
  const octets = value.split(".").map(Number);
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}
const TAILNET_V6 = new node_net.BlockList();
TAILNET_V6.addSubnet("fd7a:115c:a1e0::", 48, "ipv6");
function isTailnetAddress6(value) {
  return node_net.isIPv6(value) && TAILNET_V6.check(value, "ipv6");
}
const BACKEND_STATES = {
  Running: "ready",
  NeedsLogin: "logged-out",
  NeedsMachineAuth: "needs-approval",
  Stopped: "stopped",
  Starting: "starting",
  NoState: "starting"
};
function parseTailnetStatus(raw, binary) {
  if (!isRecord$7(raw)) return notReady("unreadable", "Tailscale returned something that was not status JSON.");
  const backend = typeof raw.BackendState === "string" ? raw.BackendState : "";
  const mapped = BACKEND_STATES[backend];
  if (mapped === void 0) return notReady("unreadable", `Tailscale reported backend state ${backend || "(none)"}.`);
  if (mapped !== "ready") return notReady(mapped);
  const self = isRecord$7(raw.Self) ? raw.Self : null;
  const selfIps = Array.isArray(self?.TailscaleIPs) ? self.TailscaleIPs : raw.TailscaleIPs;
  const ips = Array.isArray(selfIps) ? selfIps.filter((ip) => typeof ip === "string") : [];
  const address = ips.find((candidate) => isTailnetAddress(candidate));
  if (address === void 0) return notReady("no-address");
  const fqdn = typeof self?.DNSName === "string" ? self.DNSName : "";
  const dnsName = fqdn.replace(/\.$/, "");
  const tailnet = isRecord$7(raw.CurrentTailnet) ? raw.CurrentTailnet : null;
  const magicDns = dnsName !== "" && tailnet?.MagicDNSEnabled !== false;
  const magicDnsSuffix = typeof raw.MagicDNSSuffix === "string" && raw.MagicDNSSuffix !== "" ? raw.MagicDNSSuffix : typeof tailnet?.MagicDNSSuffix === "string" ? tailnet.MagicDNSSuffix : "";
  return {
    ready: true,
    address,
    // Same rule as the v4 address, not a looser one: null when the node has no
    // tailnet v6, which costs a v6-preferring phone one Happy Eyeballs fallback
    // and never binds a listener outside the tailnet.
    address6: ips.find((candidate) => isTailnetAddress6(candidate)) ?? null,
    // Empty when MagicDNS is off: a name that does not resolve is worse on
    // screen than no name, because the failure lands on the phone instead.
    dnsName: magicDns ? dnsName : "",
    hostName: typeof self?.HostName === "string" ? self.HostName : dnsName.split(".")[0],
    tailnetName: typeof tailnet?.Name === "string" ? tailnet.Name : magicDnsSuffix,
    magicDnsSuffix,
    magicDns,
    // Populated only once HTTPS certificates are enabled for the tailnet, so the
    // cert story can be answered honestly before anything is requested.
    certsAvailable: Array.isArray(raw.CertDomains) && raw.CertDomains.length > 0,
    binary
  };
}
function toTailnetStatus(result, binary = "") {
  if (result.spawnError === "ENOENT") return notReady("not-installed");
  const text2 = result.stdout.trim();
  if (text2 === "") {
    const said = result.stderr.toLowerCase();
    const noDaemon = said.includes("failed to connect") || said.includes("is tailscale running");
    return notReady(noDaemon ? "not-running" : "unreadable", result.stderr);
  }
  try {
    return parseTailnetStatus(JSON.parse(text2), binary);
  } catch {
    return notReady("unreadable", result.stderr || redactSecrets(text2.slice(0, 200)));
  }
}
function redactSecrets(text2) {
  return text2.replace(/("AuthURL"\s*:\s*")[^"]+/g, "$1[redacted]").replace(/https:\/\/login\.tailscale\.com\/\S+/g, "https://login.tailscale.com/[redacted]");
}
function executable(path) {
  try {
    node_fs.accessSync(path, node_fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}
let cachedBin;
async function findTailscale(force = false, platform = currentPlatform()) {
  if (!force && cachedBin !== void 0) return cachedBin;
  try {
    const PATH = await loginPath(platform);
    const spec = lookupSpec(platform, TAILSCALE_BIN);
    const { stdout } = await run$6(spec.command, spec.args, {
      env: withPath(process.env, PATH, platform),
      timeout: 5e3,
      windowsHide: true
    });
    const found = firstLookupPath(stdout);
    if (found && executable(found)) {
      cachedBin = found;
      return cachedBin;
    }
  } catch {
  }
  cachedBin = tailscaleCandidates(platform, process.env).find(executable) ?? null;
  return cachedBin;
}
const STATUS_TIMEOUT_MS = 5e3;
async function runTailscale(args, timeout) {
  const bin = await findTailscale();
  if (bin === null) return { result: { stdout: "", stderr: "", code: -1, spawnError: "ENOENT" }, binary: "" };
  try {
    const { stdout, stderr } = await run$6(bin, args, { timeout, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
    return { result: { stdout, stderr, code: 0 }, binary: bin };
  } catch (error) {
    const failure2 = error;
    if (failure2.code === "ENOENT") cachedBin = void 0;
    return {
      result: {
        stdout: failure2.stdout ?? "",
        stderr: failure2.stderr ?? "",
        code: typeof failure2.code === "number" ? failure2.code : -1,
        ...failure2.code === "ENOENT" ? { spawnError: "ENOENT" } : {}
      },
      binary: bin
    };
  }
}
const CACHE_MS = 3e3;
let cached$1 = null;
let inFlight$1 = null;
async function tailnetStatus(force = false) {
  if (!force && cached$1 && Date.now() - cached$1.at < CACHE_MS) return cached$1.status;
  if (inFlight$1) return inFlight$1;
  inFlight$1 = runTailscale(["status", "--json"], STATUS_TIMEOUT_MS).then(({ result, binary }) => {
    const status = toTailnetStatus(result, binary);
    cached$1 = { at: Date.now(), status };
    return status;
  }).finally(() => {
    inFlight$1 = null;
  });
  return inFlight$1;
}
const SAFE_DNS_NAME = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/i;
const CERT_TIMEOUT_MS = 12e4;
const MIN_VALIDITY = "168h";
const HTTPS_DISABLED_HINTS = [
  "does not support getting tls certs",
  // observed on this machine, tailscaled 1.98.9
  "https must be enabled",
  "https is not enabled",
  "certificate not available"
];
function toCertResult(dnsName, certPath, keyPath, result) {
  if (result.spawnError === "ENOENT") {
    return { ok: false, reason: "not-installed", message: BLOCKED_REASONS["not-installed"] };
  }
  if (result.code === 0) return { ok: true, certPath, keyPath };
  const said = `${result.stdout}
${result.stderr}`.toLowerCase();
  const detail = result.stderr.trim() || result.stdout.trim() || void 0;
  if (HTTPS_DISABLED_HINTS.some((hint) => said.includes(hint))) {
    return {
      ok: false,
      reason: "https-disabled",
      // Names the page and the switch. The CLI's own answer is a bare `500
      // Internal Server Error`, which tells nobody this is a setting they own
      // and can change in about ten seconds.
      message: `Tailscale HTTPS certificates are turned off for this tailnet, so ${dnsName} cannot get one. Open https://login.tailscale.com/admin/dns, turn on HTTPS Certificates, then try again. Until then your phone can only reach the plain 100.x address, which browsers never treat as secure.`,
      ...detail ? { detail } : {}
    };
  }
  if (said.includes("failed to connect") || said.includes("is tailscale running")) {
    return { ok: false, reason: "not-running", message: BLOCKED_REASONS["not-running"], ...detail ? { detail } : {} };
  }
  if (result.code === -1) {
    return {
      ok: false,
      reason: "failed",
      message: `Tailscale did not finish issuing a certificate for ${dnsName} within two minutes. Check that https://login.tailscale.com/admin/dns shows HTTPS Certificates on, then try again.`,
      ...detail ? { detail } : {}
    };
  }
  return {
    ok: false,
    reason: "failed",
    message: `Tailscale could not issue a certificate for ${dnsName}. Run \`tailscale cert ${dnsName}\` in a terminal to see the full answer, then try again.`,
    ...detail ? { detail } : {}
  };
}
async function ensureCert(dnsName, dir) {
  if (!SAFE_DNS_NAME.test(dnsName)) {
    return {
      ok: false,
      reason: "bad-name",
      message: `“${dnsName}” is not a MagicDNS name, so no certificate can be requested for it. Expected something like your-mac.tailnet-name.ts.net, which the tailnet status reports.`
    };
  }
  const certPath = node_path.join(dir, `${dnsName}.crt`);
  const keyPath = node_path.join(dir, `${dnsName}.key`);
  try {
    node_fs.mkdirSync(dir, { recursive: true, mode: 448 });
    node_fs.chmodSync(dir, 448);
  } catch (error) {
    return {
      ok: false,
      reason: "failed",
      message: `Could not create ${dir} to keep the certificate in. Check that folder’s permissions, then try again.`,
      detail: String(error)
    };
  }
  const { result } = await runTailscale(
    ["cert", "--min-validity", MIN_VALIDITY, "--cert-file", certPath, "--key-file", keyPath, dnsName],
    CERT_TIMEOUT_MS
  );
  return toCertResult(dnsName, certPath, keyPath, result);
}
function registerTailnetIpc(ipcMain, deps) {
  ipcMain.handle("tailnet:status", (_event, force) => tailnetStatus(force === true));
  ipcMain.handle(
    "tailnet:cert",
    (_event, dnsName) => ensureCert(typeof dnsName === "string" ? dnsName : "", deps.certDir)
  );
}
function isBytes(a) {
  return a instanceof Uint8Array || ArrayBuffer.isView(a) && a.constructor.name === "Uint8Array" && "BYTES_PER_ELEMENT" in a && a.BYTES_PER_ELEMENT === 1;
}
const atitle = (title) => title ? `"${title}" ` : "";
function abool(value, title = "") {
  if (typeof value !== "boolean")
    throw new TypeError(atitle(title) + "expected boolean, got type=" + typeof value);
  return value;
}
function anumber(n, title = "") {
  if (typeof n !== "number")
    throw new TypeError(atitle(title) + "expected number, got " + typeof n);
  if (!Number.isSafeInteger(n) || n < 0)
    throw new RangeError(atitle(title) + "expected integer >= 0, got " + n);
  return n;
}
function abytes(value, length, title = "") {
  if (isBytes(value) && (length === void 0 || value.length === length))
    return value;
  if (length !== void 0)
    anumber(length, "length");
  const bytes2 = isBytes(value);
  const ofLen = length !== void 0 ? ` of length ${length}` : "";
  const got = bytes2 ? `length=${value.length}` : `type=${typeof value}`;
  const message = atitle(title) + "expected Uint8Array" + ofLen + ", got " + got;
  if (!bytes2)
    throw new TypeError(message);
  throw new RangeError(message);
}
const aobject = (value, label2) => {
  if (value === null || typeof value !== "object" || Array.isArray(value))
    throw new TypeError(label2 === "object" ? "expected valid options object" : `"${label2}" expected object, got type=${typeof value}`);
};
function aexists(instance2, checkFinished = true) {
  if (instance2.destroyed)
    throw new Error("hash was destroyed");
  if (checkFinished && instance2.finished)
    throw new Error("digest() was already called");
}
function aoutput(out, instance2) {
  abytes(out, void 0, "output");
  const min = instance2.outputLen;
  if (!(out.length >= min)) {
    throw new RangeError('"output" expected length >= ' + min);
  }
}
function u32(arr) {
  return new Uint32Array(arr.buffer, arr.byteOffset, Math.floor(arr.byteLength / 4));
}
function clean$1(...arrays) {
  for (let i = 0; i < arrays.length; i++) {
    arrays[i].fill(0);
  }
}
function createView(arr) {
  return new DataView(arr.buffer, arr.byteOffset, arr.byteLength);
}
const isLE = /* @__PURE__ */ (() => new Uint8Array(new Uint32Array([287454020]).buffer)[0] === 68)();
function byteSwap(word) {
  return word << 24 & 4278190080 | word << 8 & 16711680 | word >>> 8 & 65280 | word >>> 24 & 255;
}
function byteSwap32(arr) {
  for (let i = 0; i < arr.length; i++) {
    arr[i] = byteSwap(arr[i]);
  }
  return arr;
}
const swap32IfBE = isLE ? (u) => u : byteSwap32;
function checkOpts(defaults, opts) {
  aobject(defaults, "defaults");
  aobject(opts, "opts");
  const merged = Object.assign(defaults, opts);
  return merged;
}
function equalBytes(a, b) {
  a = abytes(a);
  b = abytes(b);
  if (a.length !== b.length)
    return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++)
    diff |= a[i] ^ b[i];
  return diff === 0;
}
function wrapMacConstructor(keyLen, macCons, fromMsg) {
  const mac = macCons;
  const getArgs = (() => []);
  const macC = (msg, key) => mac(key, ...getArgs(msg)).update(msg).digest();
  const tmp = mac(new Uint8Array(keyLen), ...getArgs(new Uint8Array(0)));
  macC.outputLen = tmp.outputLen;
  macC.blockLen = tmp.blockLen;
  macC.create = (key, ...args) => mac(key, ...args);
  return macC;
}
const wrapCipher = /* @__NO_SIDE_EFFECTS__ */ (params, constructor) => {
  function wrappedCipher(key, ...args) {
    abytes(key, void 0, "key");
    if (params.nonceLength !== void 0) {
      const nonce = args[0];
      abytes(nonce, params.varSizeNonce ? void 0 : params.nonceLength, "nonce");
    }
    const tagl = params.tagLength;
    const aadStart = params.nonceLength !== void 0 ? 1 : 0;
    if (!params.withAAD) {
      for (let i = aadStart; i < args.length; i++)
        if (isBytes(args[i]))
          throw new Error("AAD not supported");
    }
    if (params.withAAD && args[aadStart] !== void 0)
      abytes(args[aadStart], void 0, "AAD");
    const cipher = constructor(key, ...args);
    const checkOutput = (fnLength, output) => {
      if (output !== void 0) {
        if (fnLength !== 2)
          throw new Error("cipher output not supported");
        abytes(output, void 0, "output");
      }
    };
    let called = false;
    const wrCipher = {
      encrypt(data, output) {
        if (called)
          throw new Error("cannot encrypt() twice with same key + nonce");
        called = true;
        abytes(data, void 0, "data");
        checkOutput(cipher.encrypt.length, output);
        return cipher.encrypt(data, output);
      },
      decrypt(data, output) {
        abytes(data, void 0, "data");
        if (tagl && data.length < tagl)
          throw new Error('"ciphertext" expected length >= tagLength=' + tagl);
        checkOutput(cipher.decrypt.length, output);
        return cipher.decrypt(data, output);
      }
    };
    return wrCipher;
  }
  Object.assign(wrappedCipher, params);
  return wrappedCipher;
};
function getOutput(expectedLength, out, onlyAligned = true) {
  if (out === void 0)
    return new Uint8Array(expectedLength);
  abytes(out, expectedLength, "output");
  if (onlyAligned && !isAligned32(out))
    throw new Error("invalid output, must be aligned");
  return out;
}
function u64Lengths(dataLength, aadLength, isLE2) {
  anumber(dataLength);
  anumber(aadLength);
  abool(isLE2);
  const num2 = new Uint8Array(16);
  const view = createView(num2);
  view.setBigUint64(0, BigInt(aadLength), isLE2);
  view.setBigUint64(8, BigInt(dataLength), isLE2);
  return num2;
}
function isAligned32(bytes2) {
  return bytes2.byteOffset % 4 === 0;
}
function copyBytes(bytes2) {
  return Uint8Array.from(abytes(bytes2));
}
const encodeStr = (str2) => Uint8Array.from(str2.split(""), (c) => c.charCodeAt(0));
const sigma16_32 = /* @__PURE__ */ (() => swap32IfBE(u32(encodeStr("expand 16-byte k"))))();
const sigma32_32 = /* @__PURE__ */ (() => swap32IfBE(u32(encodeStr("expand 32-byte k"))))();
function rotl(a, b) {
  return a << b | a >>> 32 - b;
}
const BLOCK_LEN = 64;
const BLOCK_LEN32 = 16;
const MAX_COUNTER$1 = /* @__PURE__ */ (() => 2 ** 32 - 1)();
const U32_EMPTY = /* @__PURE__ */ Uint32Array.of();
function runCipher(core, sigma, key, nonce, data, output, counter, rounds) {
  const len = data.length;
  const block = new Uint8Array(BLOCK_LEN);
  const b32 = u32(block);
  const isAligned = isLE && isAligned32(data) && isAligned32(output);
  const d32 = isAligned ? u32(data) : U32_EMPTY;
  const o32 = isAligned ? u32(output) : U32_EMPTY;
  if (!isLE) {
    for (let pos = 0; pos < len; counter++) {
      core(sigma, key, nonce, b32, counter, rounds);
      swap32IfBE(b32);
      if (counter >= MAX_COUNTER$1)
        throw new Error("arx: counter overflow");
      const take = Math.min(BLOCK_LEN, len - pos);
      for (let j = 0, posj; j < take; j++) {
        posj = pos + j;
        output[posj] = data[posj] ^ block[j];
      }
      pos += take;
    }
    return;
  }
  for (let pos = 0; pos < len; counter++) {
    core(sigma, key, nonce, b32, counter, rounds);
    if (counter >= MAX_COUNTER$1)
      throw new Error("arx: counter overflow");
    const take = Math.min(BLOCK_LEN, len - pos);
    if (isAligned && take === BLOCK_LEN) {
      const pos32 = pos / 4;
      if (pos % 4 !== 0)
        throw new Error("arx: invalid block position");
      for (let j = 0, posj; j < BLOCK_LEN32; j++) {
        posj = pos32 + j;
        o32[posj] = d32[posj] ^ b32[j];
      }
      pos += BLOCK_LEN;
      continue;
    }
    for (let j = 0, posj; j < take; j++) {
      posj = pos + j;
      output[posj] = data[posj] ^ block[j];
    }
    pos += take;
  }
}
function createCipher(core, opts) {
  const { allowShortKeys, extendNonceFn, counterLength, counterRight, rounds } = checkOpts({ allowShortKeys: false, counterLength: 8, counterRight: false, rounds: 20 }, opts);
  if (typeof core !== "function")
    throw new Error("core must be a function");
  anumber(counterLength);
  anumber(rounds);
  abool(counterRight);
  abool(allowShortKeys);
  return (key, nonce, data, output, counter = 0) => {
    abytes(key, void 0, "key");
    abytes(nonce, void 0, "nonce");
    abytes(data, void 0, "data");
    const len = data.length;
    output = getOutput(len, output, false);
    anumber(counter);
    if (counter < 0 || counter >= MAX_COUNTER$1)
      throw new Error("arx: counter overflow");
    const toClean = [];
    let l = key.length;
    let k;
    let sigma;
    if (l === 32) {
      toClean.push(k = copyBytes(key));
      sigma = sigma32_32;
    } else if (l === 16 && allowShortKeys) {
      k = new Uint8Array(32);
      k.set(key);
      k.set(key, 16);
      sigma = sigma16_32;
      toClean.push(k);
    } else {
      abytes(key, 32, "arx key");
      throw new Error("invalid key size");
    }
    if (!isLE || !isAligned32(nonce))
      toClean.push(nonce = copyBytes(nonce));
    let k32 = u32(k);
    if (extendNonceFn) {
      if (nonce.length !== 24)
        throw new Error("arx: extended nonce must be 24 bytes");
      const n16 = nonce.subarray(0, 16);
      if (isLE)
        extendNonceFn(sigma, k32, u32(n16), k32);
      else {
        const sigmaRaw = swap32IfBE(Uint32Array.from(sigma));
        extendNonceFn(sigmaRaw, k32, u32(n16), k32);
        clean$1(sigmaRaw);
        swap32IfBE(k32);
      }
      nonce = nonce.subarray(16);
    } else if (!isLE)
      swap32IfBE(k32);
    const nonceNcLen = 16 - counterLength;
    if (nonceNcLen !== nonce.length)
      throw new Error(`arx: nonce must be ${nonceNcLen} or 16 bytes`);
    if (nonceNcLen !== 12) {
      const nc = new Uint8Array(12);
      nc.set(nonce, counterRight ? 0 : 12 - nonce.length);
      nonce = nc;
      toClean.push(nonce);
    }
    const n32 = swap32IfBE(u32(nonce));
    try {
      runCipher(core, sigma, k32, n32, data, output, counter, rounds);
      return output;
    } finally {
      clean$1(...toClean);
    }
  };
}
function u8to16(a, i) {
  return a[i++] & 255 | (a[i++] & 255) << 8;
}
class Poly1305 {
  blockLen = 16;
  outputLen = 16;
  buffer = new Uint8Array(16);
  r = new Uint16Array(10);
  // Allocating 1 array with .subarray() here is slower than 3
  h = new Uint16Array(10);
  pad = new Uint16Array(8);
  pos = 0;
  finished = false;
  destroyed = false;
  // Can be speed-up using BigUint64Array, at the cost of complexity
  constructor(key) {
    key = copyBytes(abytes(key, 32, "key"));
    const t0 = u8to16(key, 0);
    const t1 = u8to16(key, 2);
    const t2 = u8to16(key, 4);
    const t3 = u8to16(key, 6);
    const t4 = u8to16(key, 8);
    const t5 = u8to16(key, 10);
    const t6 = u8to16(key, 12);
    const t7 = u8to16(key, 14);
    this.r[0] = t0 & 8191;
    this.r[1] = (t0 >>> 13 | t1 << 3) & 8191;
    this.r[2] = (t1 >>> 10 | t2 << 6) & 7939;
    this.r[3] = (t2 >>> 7 | t3 << 9) & 8191;
    this.r[4] = (t3 >>> 4 | t4 << 12) & 255;
    this.r[5] = t4 >>> 1 & 8190;
    this.r[6] = (t4 >>> 14 | t5 << 2) & 8191;
    this.r[7] = (t5 >>> 11 | t6 << 5) & 8065;
    this.r[8] = (t6 >>> 8 | t7 << 8) & 8191;
    this.r[9] = t7 >>> 5 & 127;
    for (let i = 0; i < 8; i++)
      this.pad[i] = u8to16(key, 16 + 2 * i);
  }
  process(data, offset, isLast = false) {
    const hibit = isLast ? 0 : 1 << 11;
    const { h, r } = this;
    const r0 = r[0];
    const r1 = r[1];
    const r2 = r[2];
    const r3 = r[3];
    const r4 = r[4];
    const r5 = r[5];
    const r6 = r[6];
    const r7 = r[7];
    const r8 = r[8];
    const r9 = r[9];
    const t0 = u8to16(data, offset + 0);
    const t1 = u8to16(data, offset + 2);
    const t2 = u8to16(data, offset + 4);
    const t3 = u8to16(data, offset + 6);
    const t4 = u8to16(data, offset + 8);
    const t5 = u8to16(data, offset + 10);
    const t6 = u8to16(data, offset + 12);
    const t7 = u8to16(data, offset + 14);
    let h0 = h[0] + (t0 & 8191);
    let h1 = h[1] + ((t0 >>> 13 | t1 << 3) & 8191);
    let h2 = h[2] + ((t1 >>> 10 | t2 << 6) & 8191);
    let h3 = h[3] + ((t2 >>> 7 | t3 << 9) & 8191);
    let h4 = h[4] + ((t3 >>> 4 | t4 << 12) & 8191);
    let h5 = h[5] + (t4 >>> 1 & 8191);
    let h6 = h[6] + ((t4 >>> 14 | t5 << 2) & 8191);
    let h7 = h[7] + ((t5 >>> 11 | t6 << 5) & 8191);
    let h8 = h[8] + ((t6 >>> 8 | t7 << 8) & 8191);
    let h9 = h[9] + (t7 >>> 5 | hibit);
    let c = 0;
    let d0 = c + h0 * r0 + h1 * (5 * r9) + h2 * (5 * r8) + h3 * (5 * r7) + h4 * (5 * r6);
    c = d0 >>> 13;
    d0 &= 8191;
    d0 += h5 * (5 * r5) + h6 * (5 * r4) + h7 * (5 * r3) + h8 * (5 * r2) + h9 * (5 * r1);
    c += d0 >>> 13;
    d0 &= 8191;
    let d1 = c + h0 * r1 + h1 * r0 + h2 * (5 * r9) + h3 * (5 * r8) + h4 * (5 * r7);
    c = d1 >>> 13;
    d1 &= 8191;
    d1 += h5 * (5 * r6) + h6 * (5 * r5) + h7 * (5 * r4) + h8 * (5 * r3) + h9 * (5 * r2);
    c += d1 >>> 13;
    d1 &= 8191;
    let d2 = c + h0 * r2 + h1 * r1 + h2 * r0 + h3 * (5 * r9) + h4 * (5 * r8);
    c = d2 >>> 13;
    d2 &= 8191;
    d2 += h5 * (5 * r7) + h6 * (5 * r6) + h7 * (5 * r5) + h8 * (5 * r4) + h9 * (5 * r3);
    c += d2 >>> 13;
    d2 &= 8191;
    let d3 = c + h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * (5 * r9);
    c = d3 >>> 13;
    d3 &= 8191;
    d3 += h5 * (5 * r8) + h6 * (5 * r7) + h7 * (5 * r6) + h8 * (5 * r5) + h9 * (5 * r4);
    c += d3 >>> 13;
    d3 &= 8191;
    let d4 = c + h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
    c = d4 >>> 13;
    d4 &= 8191;
    d4 += h5 * (5 * r9) + h6 * (5 * r8) + h7 * (5 * r7) + h8 * (5 * r6) + h9 * (5 * r5);
    c += d4 >>> 13;
    d4 &= 8191;
    let d5 = c + h0 * r5 + h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1;
    c = d5 >>> 13;
    d5 &= 8191;
    d5 += h5 * r0 + h6 * (5 * r9) + h7 * (5 * r8) + h8 * (5 * r7) + h9 * (5 * r6);
    c += d5 >>> 13;
    d5 &= 8191;
    let d6 = c + h0 * r6 + h1 * r5 + h2 * r4 + h3 * r3 + h4 * r2;
    c = d6 >>> 13;
    d6 &= 8191;
    d6 += h5 * r1 + h6 * r0 + h7 * (5 * r9) + h8 * (5 * r8) + h9 * (5 * r7);
    c += d6 >>> 13;
    d6 &= 8191;
    let d7 = c + h0 * r7 + h1 * r6 + h2 * r5 + h3 * r4 + h4 * r3;
    c = d7 >>> 13;
    d7 &= 8191;
    d7 += h5 * r2 + h6 * r1 + h7 * r0 + h8 * (5 * r9) + h9 * (5 * r8);
    c += d7 >>> 13;
    d7 &= 8191;
    let d8 = c + h0 * r8 + h1 * r7 + h2 * r6 + h3 * r5 + h4 * r4;
    c = d8 >>> 13;
    d8 &= 8191;
    d8 += h5 * r3 + h6 * r2 + h7 * r1 + h8 * r0 + h9 * (5 * r9);
    c += d8 >>> 13;
    d8 &= 8191;
    let d9 = c + h0 * r9 + h1 * r8 + h2 * r7 + h3 * r6 + h4 * r5;
    c = d9 >>> 13;
    d9 &= 8191;
    d9 += h5 * r4 + h6 * r3 + h7 * r2 + h8 * r1 + h9 * r0;
    c += d9 >>> 13;
    d9 &= 8191;
    c = (c << 2) + c | 0;
    c = c + d0 | 0;
    d0 = c & 8191;
    c = c >>> 13;
    d1 += c;
    h[0] = d0;
    h[1] = d1;
    h[2] = d2;
    h[3] = d3;
    h[4] = d4;
    h[5] = d5;
    h[6] = d6;
    h[7] = d7;
    h[8] = d8;
    h[9] = d9;
  }
  finalize() {
    const { h, pad } = this;
    const g = new Uint16Array(10);
    let c = h[1] >>> 13;
    h[1] &= 8191;
    for (let i = 2; i < 10; i++) {
      h[i] += c;
      c = h[i] >>> 13;
      h[i] &= 8191;
    }
    h[0] += c * 5;
    c = h[0] >>> 13;
    h[0] &= 8191;
    h[1] += c;
    c = h[1] >>> 13;
    h[1] &= 8191;
    h[2] += c;
    g[0] = h[0] + 5;
    c = g[0] >>> 13;
    g[0] &= 8191;
    for (let i = 1; i < 10; i++) {
      g[i] = h[i] + c;
      c = g[i] >>> 13;
      g[i] &= 8191;
    }
    g[9] -= 1 << 13;
    let mask = (c ^ 1) - 1;
    for (let i = 0; i < 10; i++)
      g[i] &= mask;
    mask = ~mask;
    for (let i = 0; i < 10; i++)
      h[i] = h[i] & mask | g[i];
    h[0] = (h[0] | h[1] << 13) & 65535;
    h[1] = (h[1] >>> 3 | h[2] << 10) & 65535;
    h[2] = (h[2] >>> 6 | h[3] << 7) & 65535;
    h[3] = (h[3] >>> 9 | h[4] << 4) & 65535;
    h[4] = (h[4] >>> 12 | h[5] << 1 | h[6] << 14) & 65535;
    h[5] = (h[6] >>> 2 | h[7] << 11) & 65535;
    h[6] = (h[7] >>> 5 | h[8] << 8) & 65535;
    h[7] = (h[8] >>> 8 | h[9] << 5) & 65535;
    let f = h[0] + pad[0];
    h[0] = f & 65535;
    for (let i = 1; i < 8; i++) {
      f = (h[i] + pad[i] | 0) + (f >>> 16) | 0;
      h[i] = f & 65535;
    }
    clean$1(g);
  }
  update(data) {
    aexists(this);
    abytes(data);
    data = copyBytes(data);
    const { buffer, blockLen } = this;
    const len = data.length;
    for (let pos = 0; pos < len; ) {
      const take = Math.min(blockLen - this.pos, len - pos);
      if (take === blockLen) {
        for (; blockLen <= len - pos; pos += blockLen)
          this.process(data, pos);
        continue;
      }
      buffer.set(data.subarray(pos, pos + take), this.pos);
      this.pos += take;
      pos += take;
      if (this.pos === blockLen) {
        this.process(buffer, 0, false);
        this.pos = 0;
      }
    }
    return this;
  }
  destroy() {
    this.destroyed = true;
    clean$1(this.h, this.r, this.buffer, this.pad);
  }
  digestInto(out) {
    aexists(this);
    aoutput(out, this);
    this.finished = true;
    const { buffer, h } = this;
    let { pos } = this;
    if (pos) {
      buffer[pos++] = 1;
      for (; pos < 16; pos++)
        buffer[pos] = 0;
      this.process(buffer, 0, true);
    }
    this.finalize();
    let opos = 0;
    for (let i = 0; i < 8; i++) {
      out[opos++] = h[i] >>> 0;
      out[opos++] = h[i] >>> 8;
    }
  }
  digest() {
    const { buffer, outputLen } = this;
    this.digestInto(buffer);
    const res = buffer.slice(0, outputLen);
    this.destroy();
    return res;
  }
}
const poly1305 = /* @__PURE__ */ wrapMacConstructor(32, (key) => new Poly1305(key));
function chachaCore(s, k, n, out, cnt, rounds = 20) {
  let y00 = s[0], y01 = s[1], y02 = s[2], y03 = s[3], y04 = k[0], y05 = k[1], y06 = k[2], y07 = k[3], y08 = k[4], y09 = k[5], y10 = k[6], y11 = k[7], y12 = cnt, y13 = n[0], y14 = n[1], y15 = n[2];
  let x00 = y00, x01 = y01, x02 = y02, x03 = y03, x04 = y04, x05 = y05, x06 = y06, x07 = y07, x08 = y08, x09 = y09, x10 = y10, x11 = y11, x12 = y12, x13 = y13, x14 = y14, x15 = y15;
  for (let r = 0; r < rounds; r += 2) {
    x00 = x00 + x04 | 0;
    x12 = rotl(x12 ^ x00, 16);
    x08 = x08 + x12 | 0;
    x04 = rotl(x04 ^ x08, 12);
    x00 = x00 + x04 | 0;
    x12 = rotl(x12 ^ x00, 8);
    x08 = x08 + x12 | 0;
    x04 = rotl(x04 ^ x08, 7);
    x01 = x01 + x05 | 0;
    x13 = rotl(x13 ^ x01, 16);
    x09 = x09 + x13 | 0;
    x05 = rotl(x05 ^ x09, 12);
    x01 = x01 + x05 | 0;
    x13 = rotl(x13 ^ x01, 8);
    x09 = x09 + x13 | 0;
    x05 = rotl(x05 ^ x09, 7);
    x02 = x02 + x06 | 0;
    x14 = rotl(x14 ^ x02, 16);
    x10 = x10 + x14 | 0;
    x06 = rotl(x06 ^ x10, 12);
    x02 = x02 + x06 | 0;
    x14 = rotl(x14 ^ x02, 8);
    x10 = x10 + x14 | 0;
    x06 = rotl(x06 ^ x10, 7);
    x03 = x03 + x07 | 0;
    x15 = rotl(x15 ^ x03, 16);
    x11 = x11 + x15 | 0;
    x07 = rotl(x07 ^ x11, 12);
    x03 = x03 + x07 | 0;
    x15 = rotl(x15 ^ x03, 8);
    x11 = x11 + x15 | 0;
    x07 = rotl(x07 ^ x11, 7);
    x00 = x00 + x05 | 0;
    x15 = rotl(x15 ^ x00, 16);
    x10 = x10 + x15 | 0;
    x05 = rotl(x05 ^ x10, 12);
    x00 = x00 + x05 | 0;
    x15 = rotl(x15 ^ x00, 8);
    x10 = x10 + x15 | 0;
    x05 = rotl(x05 ^ x10, 7);
    x01 = x01 + x06 | 0;
    x12 = rotl(x12 ^ x01, 16);
    x11 = x11 + x12 | 0;
    x06 = rotl(x06 ^ x11, 12);
    x01 = x01 + x06 | 0;
    x12 = rotl(x12 ^ x01, 8);
    x11 = x11 + x12 | 0;
    x06 = rotl(x06 ^ x11, 7);
    x02 = x02 + x07 | 0;
    x13 = rotl(x13 ^ x02, 16);
    x08 = x08 + x13 | 0;
    x07 = rotl(x07 ^ x08, 12);
    x02 = x02 + x07 | 0;
    x13 = rotl(x13 ^ x02, 8);
    x08 = x08 + x13 | 0;
    x07 = rotl(x07 ^ x08, 7);
    x03 = x03 + x04 | 0;
    x14 = rotl(x14 ^ x03, 16);
    x09 = x09 + x14 | 0;
    x04 = rotl(x04 ^ x09, 12);
    x03 = x03 + x04 | 0;
    x14 = rotl(x14 ^ x03, 8);
    x09 = x09 + x14 | 0;
    x04 = rotl(x04 ^ x09, 7);
  }
  let oi = 0;
  out[oi++] = y00 + x00 | 0;
  out[oi++] = y01 + x01 | 0;
  out[oi++] = y02 + x02 | 0;
  out[oi++] = y03 + x03 | 0;
  out[oi++] = y04 + x04 | 0;
  out[oi++] = y05 + x05 | 0;
  out[oi++] = y06 + x06 | 0;
  out[oi++] = y07 + x07 | 0;
  out[oi++] = y08 + x08 | 0;
  out[oi++] = y09 + x09 | 0;
  out[oi++] = y10 + x10 | 0;
  out[oi++] = y11 + x11 | 0;
  out[oi++] = y12 + x12 | 0;
  out[oi++] = y13 + x13 | 0;
  out[oi++] = y14 + x14 | 0;
  out[oi++] = y15 + x15 | 0;
}
const chacha20 = /* @__PURE__ */ createCipher(chachaCore, {
  counterRight: false,
  counterLength: 4,
  allowShortKeys: false
});
const ZEROS16 = /* @__PURE__ */ new Uint8Array(16);
const updatePadded = (h, msg) => {
  h.update(msg);
  const leftover = msg.length % 16;
  if (leftover)
    h.update(ZEROS16.subarray(leftover));
};
const ZEROS32 = /* @__PURE__ */ new Uint8Array(32);
function computeTag(fn, key, nonce, ciphertext, AAD) {
  if (AAD !== void 0)
    abytes(AAD, void 0, "AAD");
  const authKey = fn(key, nonce, ZEROS32);
  const lengths = u64Lengths(ciphertext.length, AAD ? AAD.length : 0, true);
  const h = poly1305.create(authKey);
  if (AAD)
    updatePadded(h, AAD);
  updatePadded(h, ciphertext);
  h.update(lengths);
  const res = h.digest();
  clean$1(authKey, lengths);
  return res;
}
const _poly1305_aead = (xorStream) => (key, nonce, AAD) => {
  const tagLength = 16;
  return {
    encrypt(plaintext, output) {
      const plength = plaintext.length;
      output = getOutput(plength + tagLength, output, false);
      output.set(plaintext);
      const oPlain = output.subarray(0, -tagLength);
      xorStream(key, nonce, oPlain, oPlain, 1);
      const tag = computeTag(xorStream, key, nonce, oPlain, AAD);
      output.set(tag, plength);
      clean$1(tag);
      return output;
    },
    decrypt(ciphertext, output) {
      output = getOutput(ciphertext.length - tagLength, output, false);
      const data = ciphertext.subarray(0, -tagLength);
      const passedTag = ciphertext.subarray(-tagLength);
      const tag = computeTag(xorStream, key, nonce, data, AAD);
      if (!equalBytes(passedTag, tag)) {
        clean$1(tag);
        throw new Error("invalid tag");
      }
      output.set(ciphertext.subarray(0, -tagLength));
      xorStream(key, nonce, output, output, 1);
      clean$1(tag);
      return output;
    }
  };
};
const chacha20poly1305 = /* @__PURE__ */ wrapCipher(
  { blockSize: 64, nonceLength: 12, tagLength: 16, withAAD: true },
  /* @__PURE__ */ _poly1305_aead(chacha20)
);
const NOISE_NAME = "Noise_IK_25519_ChaChaPoly_SHA256";
const SEALED_VERSION = 1;
const KEY_BYTES$1 = 32;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const HASH_BYTES = 32;
const MAX_COUNTER = 2 ** 48;
class SealedRefusal extends Error {
  constructor(message) {
    super(message);
    this.name = "SealedRefusal";
  }
}
function generateStatic() {
  const { publicKey, privateKey } = node_crypto.generateKeyPairSync("x25519");
  return { publicKey: rawPublic(publicKey), privateKey: rawPrivate(privateKey) };
}
function rawPublic(key) {
  return key.export({ type: "spki", format: "der" }).subarray(-KEY_BYTES$1);
}
function rawPrivate(key) {
  return key.export({ type: "pkcs8", format: "der" }).subarray(-KEY_BYTES$1);
}
const SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
function publicKeyObject(raw) {
  if (raw.length !== KEY_BYTES$1) throw new SealedRefusal("x25519 public key must be 32 bytes");
  return node_crypto.createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, raw]),
    format: "der",
    type: "spki"
  });
}
function privateKeyObject(raw) {
  if (raw.length !== KEY_BYTES$1) throw new SealedRefusal("x25519 private key must be 32 bytes");
  return node_crypto.createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX, raw]),
    format: "der",
    type: "pkcs8"
  });
}
function dh(privateRaw, publicRaw) {
  let secret;
  try {
    secret = node_crypto.diffieHellman({
      privateKey: privateKeyObject(privateRaw),
      publicKey: publicKeyObject(publicRaw)
    });
  } catch {
    throw new SealedRefusal("handshake failed authentication");
  }
  if (node_crypto.timingSafeEqual(secret, Buffer.alloc(KEY_BYTES$1))) {
    throw new SealedRefusal("handshake failed authentication");
  }
  return secret;
}
function hash(...parts) {
  const h = node_crypto.createHash("sha256");
  for (const part of parts) h.update(part);
  return h.digest();
}
function mixKey(chainingKey, input) {
  const out = Buffer.from(node_crypto.hkdfSync("sha256", input, chainingKey, Buffer.alloc(0), KEY_BYTES$1 * 2));
  return { chainingKey: out.subarray(0, KEY_BYTES$1), temp: out.subarray(KEY_BYTES$1) };
}
function nonceBuffer(counter) {
  const nonce = Buffer.alloc(NONCE_BYTES);
  nonce.writeBigUInt64LE(BigInt(counter), 4);
  return nonce;
}
function seal(key, counter, plaintext, aad) {
  if (key.length !== KEY_BYTES$1) throw new Error(`sealing key was ${key.length} bytes, not ${KEY_BYTES$1}`);
  return Buffer.from(chacha20poly1305(key, nonceBuffer(counter), aad).encrypt(plaintext));
}
function open(key, counter, sealed, aad) {
  if (key.length !== KEY_BYTES$1) throw new Error(`opening key was ${key.length} bytes, not ${KEY_BYTES$1}`);
  if (sealed.length < TAG_BYTES) throw new SealedRefusal("ciphertext shorter than its tag");
  try {
    return Buffer.from(chacha20poly1305(key, nonceBuffer(counter), aad).decrypt(sealed));
  } catch {
    throw new SealedRefusal("sealed frame failed authentication");
  }
}
class SealedTransport {
  constructor(sendKey, receiveKey, channelBinding) {
    this.sendKey = sendKey;
    this.receiveKey = receiveKey;
    this.channelBinding = channelBinding;
  }
  sendKey;
  receiveKey;
  channelBinding;
  sendCounter = 0;
  receiveCounter = 0;
  send(plaintext) {
    if (this.sendCounter >= MAX_COUNTER) throw new SealedRefusal("sealed channel exhausted");
    const frame2 = seal(this.sendKey, this.sendCounter, plaintext, Buffer.alloc(0));
    this.sendCounter += 1;
    return frame2;
  }
  receive(sealed) {
    if (this.receiveCounter >= MAX_COUNTER) throw new SealedRefusal("sealed channel exhausted");
    let plaintext;
    try {
      plaintext = open(this.receiveKey, this.receiveCounter, sealed, Buffer.alloc(0));
    } catch (err) {
      if (!(err instanceof SealedRefusal)) throw err;
      throw new SealedRefusal("sealed frame failed authentication");
    }
    this.receiveCounter += 1;
    return plaintext;
  }
  sendText(value) {
    return this.send(Buffer.from(value, "utf8"));
  }
  receiveText(sealed) {
    return this.receive(sealed).toString("utf8");
  }
}
function initialState(responderStatic) {
  const h0 = hash(Buffer.from(NOISE_NAME, "utf8"));
  return { chainingKey: h0, h: hash(h0, responderStatic) };
}
function startHandshake(deviceStatic, responderStaticPublic) {
  let { chainingKey, h } = initialState(responderStaticPublic);
  const ephemeral = generateStatic();
  h = hash(h, ephemeral.publicKey);
  const es = mixKey(chainingKey, dh(ephemeral.privateKey, responderStaticPublic));
  chainingKey = es.chainingKey;
  const encryptedStatic = seal(es.temp, 0, deviceStatic.publicKey, h);
  h = hash(h, encryptedStatic);
  const ss = mixKey(chainingKey, dh(deviceStatic.privateKey, responderStaticPublic));
  chainingKey = ss.chainingKey;
  return {
    message: Buffer.concat([ephemeral.publicKey, encryptedStatic]),
    pending: {
      ephemeralPrivate: ephemeral.privateKey,
      chainingKey,
      h,
      staticPrivate: deviceStatic.privateKey
    }
  };
}
function respondToHandshake(responderStatic, message, isKnownDevice) {
  if (message.length !== KEY_BYTES$1 + KEY_BYTES$1 + TAG_BYTES) {
    throw new SealedRefusal("handshake message was the wrong length");
  }
  const initiatorEphemeral = message.subarray(0, KEY_BYTES$1);
  const encryptedStatic = message.subarray(KEY_BYTES$1);
  let { chainingKey, h } = initialState(responderStatic.publicKey);
  h = hash(h, initiatorEphemeral);
  const es = mixKey(chainingKey, dh(responderStatic.privateKey, initiatorEphemeral));
  chainingKey = es.chainingKey;
  let devicePublicKey;
  try {
    devicePublicKey = open(es.temp, 0, encryptedStatic, h);
  } catch (err) {
    if (!(err instanceof SealedRefusal)) throw err;
    throw new SealedRefusal("handshake failed authentication");
  }
  h = hash(h, encryptedStatic);
  const ss = mixKey(chainingKey, dh(responderStatic.privateKey, devicePublicKey));
  chainingKey = ss.chainingKey;
  if (!isKnownDevice(devicePublicKey)) {
    throw new SealedRefusal("handshake failed authentication");
  }
  const ephemeral = generateStatic();
  h = hash(h, ephemeral.publicKey);
  const ee = mixKey(chainingKey, dh(ephemeral.privateKey, initiatorEphemeral));
  chainingKey = ee.chainingKey;
  const se = mixKey(chainingKey, dh(ephemeral.privateKey, devicePublicKey));
  chainingKey = se.chainingKey;
  const confirmation = seal(se.temp, 0, Buffer.alloc(0), h);
  h = hash(h, confirmation);
  const { k1, k2, binding } = split(chainingKey, h);
  return {
    reply: Buffer.concat([ephemeral.publicKey, confirmation]),
    transport: new SealedTransport(k2, k1, binding),
    devicePublicKey
  };
}
function split(chainingKey, h) {
  const out = Buffer.from(
    node_crypto.hkdfSync("sha256", Buffer.alloc(0), chainingKey, Buffer.alloc(0), KEY_BYTES$1 * 2)
  );
  return {
    k1: out.subarray(0, KEY_BYTES$1),
    k2: out.subarray(KEY_BYTES$1),
    binding: Buffer.from(h.subarray(0, HASH_BYTES))
  };
}
const BASE32$1 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function fingerprint(publicKey) {
  const digest = hash(Buffer.from("terminaldeck-fingerprint", "utf8"), publicKey);
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of digest.subarray(0, 15)) {
    value = value << 8 | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += BASE32$1[value >> bits & 31];
    }
  }
  return (out.match(/.{1,4}/g) ?? []).join("-");
}
function secretBytes(count = KEY_BYTES$1) {
  return node_crypto.randomBytes(count);
}
function writeSecretFile(dir, file, contents) {
  node_fs.mkdirSync(dir, { recursive: true, mode: 448 });
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    try {
      node_fs.unlinkSync(tmp);
    } catch {
    }
    const fd = node_fs.openSync(tmp, "wx", 384);
    try {
      const bytes2 = Buffer.from(contents, "utf8");
      for (let written = 0; written < bytes2.length; ) {
        written += node_fs.writeSync(fd, bytes2, written, bytes2.length - written);
      }
      node_fs.fsyncSync(fd);
    } finally {
      node_fs.closeSync(fd);
    }
    node_fs.chmodSync(tmp, 384);
    node_fs.renameSync(tmp, file);
    node_fs.chmodSync(file, 384);
    try {
      const handle2 = node_fs.openSync(dir, "r");
      try {
        node_fs.fsyncSync(handle2);
      } finally {
        node_fs.closeSync(handle2);
      }
    } catch {
    }
  } catch (err) {
    try {
      node_fs.unlinkSync(tmp);
    } catch {
    }
    throw err;
  }
}
const PAIRING_TTL_MS = 6e4;
const MAX_FAILED_ATTEMPTS = 5;
const LOCKOUT_MS = 15 * 6e4;
const REMOTE_AUTH_FILE = "remote-auth.json";
const MAX_LIVE_TOKENS = 16;
const MAX_NAME_LENGTH$1 = 64;
const MAX_DEVICES = 64;
const MAX_FILE_BYTES$1 = 256 * 1024;
const MAX_TOKEN_LENGTH$1 = 512;
const MAX_CREDENTIAL_LENGTH = 512;
const BASE64URL = /^[A-Za-z0-9_-]+$/;
const MAX_TRACKED_KEYS = 1024;
const LAST_SEEN_WRITE_MS = 6e4;
const TOKEN_BYTES = 32;
const CREDENTIAL_BYTES = 32;
const DEVICE_ID_BYTES = 12;
const SALT_BYTES = 16;
const SCRYPT = { n: 16384, r: 8, p: 1, keylen: 32 };
const MAX_SCRYPT_N = 1 << 18;
const MAX_SCRYPT_R = 32;
const MAX_SCRYPT_P = 16;
const MAX_SCRYPT_KEYLEN = 128;
const MAX_STORED_FIELD_LENGTH = 256;
function sha256(value) {
  return node_crypto.createHash("sha256").update(value, "utf8").digest();
}
function scrypt(secret, salt, params) {
  return new Promise((resolve, reject) => {
    node_crypto.scrypt(
      secret,
      salt,
      params.keylen,
      // maxmem defaults to 32MB and scrypt throws — rather than degrade — the
      // moment 128*N*r crosses it. Deriving it from the parameters means
      // raising N later stays a one-line change instead of a runtime failure.
      { N: params.n, r: params.r, p: params.p, maxmem: 256 * params.n * params.r },
      (err, key) => err ? reject(err) : resolve(key)
    );
  });
}
function sameBytes(a, b) {
  return a.length === b.length && node_crypto.timingSafeEqual(a, b);
}
function isRecord$6(value) {
  return typeof value === "object" && value !== null;
}
function cleanName(value) {
  if (typeof value !== "string") return null;
  const cleaned = value.slice(0, MAX_NAME_LENGTH$1 * 8).replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, MAX_NAME_LENGTH$1);
  return cleaned === "" ? null : cleaned;
}
function addressKey(address) {
  const trimmed = typeof address === "string" ? address.trim().toLowerCase().slice(0, 64) : "";
  return `addr:${trimmed === "" ? "unknown" : trimmed}`;
}
function statusOf$1(device) {
  if (device.revoked) return "revoked";
  return device.approved ? "approved" : "pending";
}
function toPublic(device) {
  const key = publicKeyBytes(device.publicKey);
  return {
    id: device.id,
    name: device.name,
    addedAt: device.addedAt,
    lastSeenAt: device.lastSeenAt,
    approved: device.approved,
    revoked: device.revoked,
    status: statusOf$1(device),
    // The fingerprint rather than the key: the screen that reads this is asking
    // a person to compare six groups of characters with a phone, and 44
    // characters of base64 is a thing people tick rather than read.
    fingerprint: key === null ? null : fingerprint(key)
  };
}
const PUBLIC_KEY_BYTES = 32;
function publicKeyBytes(stored) {
  if (typeof stored !== "string" || stored === "") return null;
  const raw = Buffer.from(stored, "base64");
  return raw.length === PUBLIC_KEY_BYTES ? raw : null;
}
function asStoredCredential(value) {
  if (!isRecord$6(value)) return null;
  const { salt, hash: hash2, n, r, p, keylen } = value;
  if (typeof salt !== "string" || typeof hash2 !== "string") return null;
  if (salt.length > MAX_STORED_FIELD_LENGTH || hash2.length > MAX_STORED_FIELD_LENGTH) return null;
  if (typeof n !== "number" || typeof r !== "number" || typeof p !== "number") return null;
  if (typeof keylen !== "number") return null;
  if (!Number.isInteger(n) || n < 2 || n > MAX_SCRYPT_N || (n & n - 1) !== 0) return null;
  if (!Number.isInteger(r) || r < 1 || r > MAX_SCRYPT_R) return null;
  if (!Number.isInteger(p) || p < 1 || p > MAX_SCRYPT_P) return null;
  if (!Number.isInteger(keylen) || keylen < 16 || keylen > MAX_SCRYPT_KEYLEN) return null;
  return { salt, hash: hash2, n, r, p, keylen };
}
function asStoredDevice(value) {
  if (!isRecord$6(value)) return null;
  const credential = asStoredCredential(value.credential);
  if (!credential) return null;
  const name = cleanName(value.name);
  if (typeof value.id !== "string" || value.id === "" || name === null) return null;
  if (typeof value.addedAt !== "number") return null;
  const lastSeenAt = typeof value.lastSeenAt === "number" ? value.lastSeenAt : null;
  const publicKey = typeof value.publicKey === "string" && value.publicKey.length <= MAX_STORED_FIELD_LENGTH ? value.publicKey : void 0;
  return {
    id: value.id,
    name,
    addedAt: value.addedAt,
    lastSeenAt,
    ...publicKey === void 0 ? {} : { publicKey },
    // Anything that is not literally `true` reads as not approved, so a
    // corrupted or truncated flag fails closed rather than open.
    approved: value.approved === true,
    // The mirror image: anything that is not literally `false` reads as
    // revoked, so a damaged record cannot resurrect access.
    revoked: value.revoked !== false,
    credential
  };
}
function parseCredential(credential) {
  if (typeof credential !== "string") return null;
  if (credential.length === 0 || credential.length > MAX_CREDENTIAL_LENGTH) return null;
  const dot = credential.indexOf(".");
  if (dot <= 0 || dot === credential.length - 1) return null;
  const id2 = credential.slice(0, dot);
  const encoded = credential.slice(dot + 1);
  if (!BASE64URL.test(id2) || !BASE64URL.test(encoded)) return null;
  const secret = Buffer.from(encoded, "base64url");
  if (secret.length === 0) return null;
  return { id: id2, secret };
}
class RemoteAuth {
  /** Absolute path of the trust file. Exposed for diagnostics and tests. */
  file;
  dir;
  now;
  devices = [];
  tokens = /* @__PURE__ */ new Map();
  attempts = /* @__PURE__ */ new Map();
  /**
   * Salt for the decoy hash run when a device id is unknown. Per instance and
   * never stored: its only job is to make the wall time of a lookup say nothing
   * about whether the id exists.
   */
  decoySalt = node_crypto.randomBytes(SALT_BYTES);
  constructor(storageDir, options = {}) {
    this.dir = storageDir;
    this.file = node_path.join(storageDir, REMOTE_AUTH_FILE);
    this.now = options.now ?? Date.now;
    this.load();
  }
  /* ---------------------------------------------------------------- pairing */
  /**
   * Mint a single-use pairing token.
   *
   * Only the token's digest is kept, so nothing in this process holds a live
   * bearer secret after the call returns — the caller shows it and drops it.
   */
  createPairingToken() {
    const now = this.now();
    this.pruneTokens(now);
    const token2 = node_crypto.randomBytes(TOKEN_BYTES).toString("base64url");
    const hash2 = sha256(token2);
    const expiresAt = now + PAIRING_TTL_MS;
    this.tokens.set(hash2.toString("hex"), { hash: hash2, expiresAt, usedAt: null });
    return { token: token2, expiresAt };
  }
  /**
   * Trade a pairing token for a per-device credential, returned exactly once.
   *
   * The token is burned the instant it matches — before the name is checked,
   * before the file is written, before anything else can throw. A caller that
   * fails halfway gets no second attempt with the same token, which is the
   * difference between "one-shot" and "one-shot when it works".
   *
   * `address` is optional because the local UI may not have one, but any
   * transport that has it should pass it: without it, token guessing is capped
   * only by the token's own entropy.
   *
   * `devicePublicKey` is the device's X25519 static key, and it arrives
   * **already authenticated** — the relay transport only calls this after a
   * Noise handshake in which the far end proved it holds the matching private
   * key. It is stored so that every later connection from that device can be
   * tied to the same key, which is what makes a stolen credential useless
   * without the phone. Absent for a device on the tailnet, which has no
   * handshake to have proved anything with.
   */
  async redeemPairingToken(token2, deviceName, address, devicePublicKey) {
    const now = this.now();
    if (typeof token2 !== "string" || token2 === "" || token2.length > MAX_TOKEN_LENGTH$1) {
      return { ok: false, reason: "malformed" };
    }
    const keys = address === void 0 ? [] : [addressKey(address)];
    const blocked = this.blockedFor(keys, now);
    if (blocked > 0) return { ok: false, reason: "rate-limited", retryAfterMs: blocked };
    const record2 = this.matchToken(token2);
    if (!record2) {
      this.noteFailure(keys, now);
      return { ok: false, reason: "unknown" };
    }
    const alreadyUsed = record2.usedAt !== null;
    record2.usedAt = now;
    if (alreadyUsed) {
      this.noteFailure(keys, now);
      return { ok: false, reason: "used" };
    }
    if (now >= record2.expiresAt) return { ok: false, reason: "expired" };
    const name = cleanName(deviceName);
    if (name === null) return { ok: false, reason: "bad-name" };
    if (this.rosterWithRoom().length >= MAX_DEVICES) return { ok: false, reason: "too-many-devices" };
    const id2 = node_crypto.randomBytes(DEVICE_ID_BYTES).toString("base64url");
    const secret = node_crypto.randomBytes(CREDENTIAL_BYTES);
    const salt = node_crypto.randomBytes(SALT_BYTES);
    const hash2 = await scrypt(secret, salt, SCRYPT);
    const device = {
      id: id2,
      name,
      addedAt: now,
      lastSeenAt: null,
      // Pending, deliberately. The credential is real and still opens nothing
      // until a human at the Mac approves it.
      approved: false,
      revoked: false,
      credential: { ...SCRYPT, salt: salt.toString("base64"), hash: hash2.toString("base64") },
      // Refused rather than truncated or padded: a key of the wrong length is a
      // caller bug, and storing it would bind the device to something no
      // handshake can ever match.
      ...devicePublicKey !== void 0 && devicePublicKey.length === PUBLIC_KEY_BYTES ? { publicKey: devicePublicKey.toString("base64") } : {}
    };
    try {
      this.commit([...this.rosterWithRoom(), device]);
    } catch (err) {
      console.error("[remote-auth] could not persist a newly paired device:", err);
      return { ok: false, reason: "storage" };
    }
    this.clearFailures(keys);
    return { ok: true, credential: `${id2}.${secret.toString("base64url")}`, device: toPublic(device) };
  }
  /* ---------------------------------------------------------------- devices */
  listDevices() {
    return this.devices.map(toPublic).sort((a, b) => b.addedAt - a.addedAt);
  }
  /**
   * Approve a pending device. False when there is nothing to approve.
   *
   * A revoked device is never approved back into service. Revocation means the
   * credential is assumed to be in someone else's hands, and un-revoking would
   * hand it back to them — the device pairs again and gets a new one.
   */
  approveDevice(id2) {
    const next = structuredClone(this.devices);
    const device = next.find((candidate) => candidate.id === id2);
    if (!device || device.revoked || device.approved) return false;
    device.approved = true;
    this.commit(next);
    return true;
  }
  /**
   * Revoke a device. Throws if the write fails rather than reporting success: a
   * revocation the UI believes and the disk does not is exactly the failure
   * that puts a stolen device back on the shell after the next restart.
   */
  revokeDevice(id2) {
    const next = structuredClone(this.devices);
    const device = next.find((candidate) => candidate.id === id2);
    if (!device || device.revoked) return false;
    device.revoked = true;
    this.commit(next);
    this.clearFailures([`device:${id2}`]);
    return true;
  }
  /**
   * Decide whether a presented credential may attach, from `address`.
   *
   * The order here matters: the limiter is consulted before any hashing, so a
   * guessing loop cannot spend the Mac's CPU on scrypt, and the hash runs even
   * for an unknown device so the timing does not answer questions the reasons
   * refuse to.
   */
  async verifyCredential(credential, address) {
    const now = this.now();
    const parsed = parseCredential(credential);
    if (!parsed) return { ok: false, reason: "malformed" };
    const keys = [`device:${parsed.id}`, addressKey(address)];
    const blocked = this.blockedFor(keys, now);
    if (blocked > 0) return { ok: false, reason: "rate-limited", retryAfterMs: blocked };
    const device = this.devices.find((candidate) => candidate.id === parsed.id);
    const matched = device ? await this.matchesCredential(device.credential, parsed.secret) : await this.decoyHash(parsed.secret);
    if (!device || !matched) {
      this.noteFailure(keys, now);
      return { ok: false, reason: "denied" };
    }
    if (device.revoked) {
      this.noteFailure(keys, now);
      return { ok: false, reason: "revoked" };
    }
    if (!device.approved) return { ok: false, reason: "pending" };
    this.clearFailures(keys);
    this.touch(device, now);
    return { ok: true, device: toPublic(device) };
  }
  /* ------------------------------------------------------------ public keys */
  /**
   * Is this X25519 key one a device here holds?
   *
   * Asked by the relay transport in the middle of a Noise handshake, before any
   * reply exists, so that an unpaired device never gets a channel it could send
   * anything down. A revoked device is not one: revocation outranks everything,
   * and cutting it here costs the attacker the connection before the app layer
   * has spent a scrypt on it.
   *
   * Every stored key is compared, with no early exit, so the answer does not
   * depend on where in the list a match sat. There are at most 64 of them.
   */
  knowsDeviceKey(publicKey) {
    if (publicKey.length !== PUBLIC_KEY_BYTES) return false;
    let found = false;
    for (const device of this.devices) {
      if (device.revoked) continue;
      const stored = publicKeyBytes(device.publicKey);
      if (stored !== null && sameBytes(stored, publicKey)) found = true;
    }
    return found;
  }
  /**
   * Does *this* device hold that key?
   *
   * The question `knowsDeviceKey` cannot answer, and the one that closes the
   * hole between the two authentications a relayed connection carries: the
   * handshake proves possession of a private key, the credential proves
   * possession of a bearer secret, and without this they could belong to two
   * different devices. A credential copied off one phone onto another is then
   * refused, because the other phone cannot produce the first one's key.
   *
   * False when the device has no stored key: an unbindable device is not one
   * that binds to anything.
   */
  deviceHoldsKey(id2, publicKey) {
    if (publicKey.length !== PUBLIC_KEY_BYTES) return false;
    const device = this.devices.find((candidate) => candidate.id === id2);
    if (!device) return false;
    const stored = publicKeyBytes(device.publicKey);
    return stored !== null && sameBytes(stored, publicKey);
  }
  /* ------------------------------------------------------------- internals */
  /**
   * Constant-time lookup across every live token.
   *
   * No early exit: returning as soon as a digest matches would make the answer
   * depend on where in the map the match sat. There are at most MAX_LIVE_TOKENS
   * of them, so scanning them all costs nothing worth saving.
   */
  matchToken(token2) {
    const presented = sha256(token2);
    let found = null;
    for (const record2 of this.tokens.values()) {
      if (sameBytes(presented, record2.hash)) found = record2;
    }
    return found;
  }
  pruneTokens(now) {
    for (const [key, record2] of this.tokens) {
      if (now >= record2.expiresAt) this.tokens.delete(key);
    }
    while (this.tokens.size >= MAX_LIVE_TOKENS) {
      const oldest = [...this.tokens.entries()].sort((a, b) => a[1].expiresAt - b[1].expiresAt)[0];
      if (!oldest) break;
      this.tokens.delete(oldest[0]);
    }
  }
  /**
   * The device list with room for one more, if room can be made honestly.
   *
   * A revoked record refuses the same credential whether it is here (`revoked`)
   * or gone (`denied`), so it is not carrying any trust — it is carrying a
   * slot. Without this, sixty-four pair-and-revoke cycles fill MAX_DEVICES with
   * tombstones and pairing stops working for good, and there is no delete
   * anywhere in this API to undo it: the only cure is deleting the file by
   * hand, which is also how a user loses every device they still trust.
   *
   * Approved and pending rows are never dropped. Running out of room for real
   * devices is the user's problem to solve by revoking one, not this file's to
   * solve by guessing which one they meant.
   */
  rosterWithRoom() {
    if (this.devices.length < MAX_DEVICES) return this.devices;
    const surplus = this.devices.length - MAX_DEVICES + 1;
    const doomed = new Set(
      this.devices.filter((device) => device.revoked).sort((a, b) => a.addedAt - b.addedAt).slice(0, surplus)
    );
    if (doomed.size === 0) return this.devices;
    return this.devices.filter((device) => !doomed.has(device));
  }
  async matchesCredential(stored, secret) {
    try {
      const expected = Buffer.from(stored.hash, "base64");
      const actual = await scrypt(secret, Buffer.from(stored.salt, "base64"), {
        n: stored.n,
        r: stored.r,
        p: stored.p,
        keylen: stored.keylen
      });
      return sameBytes(expected, actual);
    } catch (err) {
      console.error("[remote-auth] a stored credential could not be checked:", err);
      return false;
    }
  }
  /** Always false. Exists only to spend the same time as a real check. */
  async decoyHash(secret) {
    await scrypt(secret, this.decoySalt, SCRYPT);
    return false;
  }
  touch(device, now) {
    const previous = device.lastSeenAt;
    device.lastSeenAt = now;
    if (previous !== null && now - previous < LAST_SEEN_WRITE_MS) return;
    try {
      this.commit(this.devices);
    } catch (err) {
      console.error("[remote-auth] could not record lastSeenAt:", err);
      device.lastSeenAt = previous;
    }
  }
  /* -------------------------------------------------------------- limiting */
  /** Milliseconds remaining on the longest active block across `keys`. */
  blockedFor(keys, now) {
    let longest = 0;
    for (const key of keys) {
      const entry = this.attempts.get(key);
      if (entry && entry.blockedUntil > now) longest = Math.max(longest, entry.blockedUntil - now);
    }
    return longest;
  }
  noteFailure(keys, now) {
    for (const key of keys) {
      const entry = this.attempts.get(key) ?? { failures: 0, blockedUntil: 0, updatedAt: now };
      if (now >= entry.blockedUntil && now - entry.updatedAt > LOCKOUT_MS) entry.failures = 0;
      if (entry.blockedUntil !== 0 && now >= entry.blockedUntil) {
        entry.failures = 0;
        entry.blockedUntil = 0;
      }
      entry.failures += 1;
      entry.updatedAt = now;
      if (entry.failures >= MAX_FAILED_ATTEMPTS) entry.blockedUntil = now + LOCKOUT_MS;
      this.attempts.set(key, entry);
    }
    this.pruneAttempts(now);
  }
  clearFailures(keys) {
    for (const key of keys) this.attempts.delete(key);
  }
  pruneAttempts(now) {
    if (this.attempts.size <= MAX_TRACKED_KEYS) return;
    const cold = [...this.attempts.entries()].filter(([, entry]) => entry.blockedUntil <= now).sort((a, b) => a[1].updatedAt - b[1].updatedAt);
    for (const [key] of cold) {
      if (this.attempts.size <= MAX_TRACKED_KEYS) break;
      this.attempts.delete(key);
    }
  }
  /* -------------------------------------------------------------- storage */
  /**
   * Swap in a new device list, on disk first.
   *
   * In-memory state is only replaced once the write lands, so a failed write
   * leaves this process and the file agreeing with each other rather than
   * drifting until the next restart reveals it.
   */
  commit(devices) {
    this.persist({ version: 1, devices });
    this.devices = devices;
  }
  persist(state) {
    writeSecretFile(this.dir, this.file, JSON.stringify(state, null, 2));
  }
  load() {
    let raw;
    try {
      const { size } = node_fs.statSync(this.file);
      if (size > MAX_FILE_BYTES$1) {
        this.quarantine(`oversized (${size} bytes)`);
        return;
      }
      raw = node_fs.readFileSync(this.file, "utf8");
    } catch (err) {
      if (err.code !== "ENOENT") {
        console.error("[remote-auth] trust file unreadable; no device will be trusted:", err);
      }
      return;
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      this.quarantine("not valid JSON");
      return;
    }
    if (!isRecord$6(parsed) || !Array.isArray(parsed.devices)) {
      this.quarantine("not a trust file");
      return;
    }
    const devices = [];
    for (const entry of parsed.devices.slice(0, MAX_DEVICES)) {
      const device = asStoredDevice(entry);
      if (device) devices.push(device);
      else console.error("[remote-auth] dropped an unreadable device record");
    }
    const byId = /* @__PURE__ */ new Map();
    for (const device of devices) {
      const existing = byId.get(device.id);
      if (!existing) {
        byId.set(device.id, device);
        continue;
      }
      existing.approved = false;
      existing.revoked = true;
      console.error("[remote-auth] duplicate device id in the trust file; treating it as revoked");
    }
    this.devices = [...byId.values()];
  }
  /**
   * Move a file we refuse to parse out of the way.
   *
   * Starting empty is the safe direction — nobody is trusted — but the next
   * write would overwrite whatever was there, and if the damage was something
   * recoverable that is the user's device list gone for good.
   */
  quarantine(reason) {
    const aside = `${this.file}.corrupt-${this.now()}-${node_crypto.randomBytes(4).toString("hex")}`;
    try {
      node_fs.renameSync(this.file, aside);
      console.error(`[remote-auth] trust file ${reason}; moved aside to ${aside}`);
    } catch (err) {
      console.error(`[remote-auth] trust file ${reason} and could not be moved aside:`, err);
    }
  }
}
const PROTOCOL_VERSION = 1;
const CAPABILITY = {
  localhost: "localhost",
  create: "create",
  upload: "upload"
};
const CAPABILITIES = [CAPABILITY.localhost, CAPABILITY.create, CAPABILITY.upload];
const MAX_NET_CHUNK_BYTES = 24 * 1024;
const MAX_NET_DATA_CHARS = Math.ceil(MAX_NET_CHUNK_BYTES / 3) * 4;
const NET_WINDOW_BYTES = 256 * 1024;
const MAX_UPLOAD_DATA_CHARS = MAX_NET_DATA_CHARS;
const MAX_UPLOAD_BYTES = 512 * 1024 * 1024;
const MAX_UPLOAD_NAME_BYTES = 255;
const SHA256_HEX_LENGTH = 64;
const MAX_MESSAGE_BYTES = 64 * 1024;
const MAX_INPUT_BYTES = 16 * 1024;
const OUTPUT_CHUNK_BYTES = 32 * 1024;
const MAX_CWD_BYTES = 1024;
const MIN_COLS = 20;
const MAX_COLS = 500;
const MIN_ROWS = 5;
const MAX_ROWS$1 = 200;
const MAX_TOKEN_LENGTH = 200;
const CLOSE = {
  normal: 1e3,
  goingAway: 1001,
  protocolError: 1002,
  unsupportedData: 1003,
  policyViolation: 1008,
  messageTooBig: 1009,
  internalError: 1011,
  tryAgainLater: 1013
};
const bad = (reason) => ({ ok: false, code: "bad-message", reason });
const tooLarge = (reason) => ({ ok: false, code: "too-large", reason });
function isRecord$5(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
function id(value) {
  return typeof value === "string" && ID_RE.test(value) ? value : null;
}
const BASE64_RE = /^[A-Za-z0-9+/]*={0,2}$/;
const HEX_RE = /^[0-9a-fA-F]+$/;
function portNumber(value) {
  return whole(value, 1, 65535);
}
function whole(value, min, max) {
  if (typeof value !== "number" || !Number.isInteger(value)) return null;
  return value >= min && value <= max ? value : null;
}
const CONTROL_CHARS$1 = /[\u0000-\u001f\u007f-\u009f]/;
const DISPLAY_STRIP = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g;
function token(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_TOKEN_LENGTH) return null;
  return CONTROL_CHARS$1.test(value) ? null : value;
}
function label(value, max) {
  const cleaned = value.replace(DISPLAY_STRIP, "").trim();
  if (cleaned.length <= max) return cleaned;
  const last = cleaned.charCodeAt(max - 1);
  return cleaned.slice(0, last >= 55296 && last <= 56319 ? max - 1 : max);
}
function descriptor(value) {
  if (!isRecord$5(value)) return null;
  const name = value.name;
  const platform = value.platform;
  if (typeof name !== "string" || typeof platform !== "string") return null;
  return {
    name: label(name, 60) || "Unnamed device",
    platform: label(platform, 40) || "unknown"
  };
}
function utf8Length(value) {
  let bytes2 = 0;
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    if (code < 128) bytes2 += 1;
    else if (code < 2048) bytes2 += 2;
    else if (code >= 55296 && code <= 56319 && i + 1 < value.length) {
      const low = value.charCodeAt(i + 1);
      if (low >= 56320 && low <= 57343) {
        bytes2 += 4;
        i += 1;
      } else bytes2 += 3;
    } else bytes2 += 3;
  }
  return bytes2;
}
function overBytes(value, cap) {
  if (value.length > cap) return true;
  return utf8Length(value) > cap;
}
function parseClientMessage(raw) {
  let parsed;
  if (typeof raw === "string") {
    if (overBytes(raw, MAX_MESSAGE_BYTES)) return tooLarge("frame over the message limit");
    try {
      parsed = JSON.parse(raw);
    } catch {
      return bad("not JSON");
    }
  } else if (ArrayBuffer.isView(raw) || raw instanceof ArrayBuffer) {
    return bad("binary frame");
  } else {
    parsed = raw;
  }
  if (!isRecord$5(parsed)) return bad("not an object");
  switch (parsed.t) {
    case "hello": {
      const protocol = whole(parsed.protocol, 0, 65535);
      if (protocol === null) return bad("hello without a protocol version");
      const supplied = token(parsed.token);
      if (supplied === null) return bad("hello without a usable token");
      const device = descriptor(parsed.device);
      if (device === null) return bad("hello without a device descriptor");
      return { ok: true, message: { t: "hello", protocol, token: supplied, device } };
    }
    case "list":
      return { ok: true, message: { t: "list" } };
    case "ping":
      return { ok: true, message: { t: "ping" } };
    case "attach": {
      const sessionId = id(parsed.id);
      if (!sessionId) return bad("attach without a session id");
      const rawCols = parsed.cols;
      const rawRows = parsed.rows;
      if (rawCols === void 0 && rawRows === void 0) {
        return { ok: true, message: { t: "attach", id: sessionId } };
      }
      const cols = whole(rawCols, MIN_COLS, MAX_COLS);
      const rows = whole(rawRows, MIN_ROWS, MAX_ROWS$1);
      if (cols === null || rows === null) return bad("attach with a size out of range");
      return { ok: true, message: { t: "attach", id: sessionId, cols, rows } };
    }
    case "detach": {
      const sessionId = id(parsed.id);
      return sessionId ? { ok: true, message: { t: "detach", id: sessionId } } : bad("detach without a session id");
    }
    case "input": {
      const sessionId = id(parsed.id);
      if (!sessionId) return bad("input without a session id");
      const data = parsed.data;
      if (typeof data !== "string") return bad("input without data");
      if (overBytes(data, MAX_INPUT_BYTES)) return tooLarge("input larger than the paste limit");
      return { ok: true, message: { t: "input", id: sessionId, data } };
    }
    case "resize": {
      const sessionId = id(parsed.id);
      if (!sessionId) return bad("resize without a session id");
      const cols = whole(parsed.cols, MIN_COLS, MAX_COLS);
      const rows = whole(parsed.rows, MIN_ROWS, MAX_ROWS$1);
      if (cols === null || rows === null) return bad("resize out of range");
      return { ok: true, message: { t: "resize", id: sessionId, cols, rows } };
    }
    /* ---- capability `create` -------------------------------------------- */
    case "create": {
      const message = { t: "create" };
      const rawCwd = parsed.cwd;
      if (rawCwd !== void 0) {
        if (typeof rawCwd !== "string" || rawCwd === "") return bad("create with an unusable folder");
        if (overBytes(rawCwd, MAX_CWD_BYTES)) return tooLarge("create with a folder over the path limit");
        if (CONTROL_CHARS$1.test(rawCwd)) return bad("create with an unusable folder");
        message.cwd = rawCwd;
      }
      const rawCols = parsed.cols;
      const rawRows = parsed.rows;
      if (rawCols === void 0 && rawRows === void 0) return { ok: true, message };
      const cols = whole(rawCols, MIN_COLS, MAX_COLS);
      const rows = whole(rawRows, MIN_ROWS, MAX_ROWS$1);
      if (cols === null || rows === null) return bad("create with a size out of range");
      message.cols = cols;
      message.rows = rows;
      return { ok: true, message };
    }
    /* ---- capability `localhost` ----------------------------------------- */
    // Shape-checked here and authorised nowhere near here. Whether this desktop
    // offers tunnelling at all, and whether the port named is one it is willing
    // to dial, are the server's questions — see the header.
    case "ports":
      return { ok: true, message: { t: "ports" } };
    case "tunnel.open": {
      const tunnelId = id(parsed.id);
      if (!tunnelId) return bad("tunnel.open without an id");
      const port = portNumber(parsed.port);
      if (port === null) return bad("tunnel.open without a port");
      return { ok: true, message: { t: "tunnel.open", id: tunnelId, port } };
    }
    case "tunnel.close": {
      const tunnelId = id(parsed.id);
      return tunnelId ? { ok: true, message: { t: "tunnel.close", id: tunnelId } } : bad("tunnel.close without an id");
    }
    case "net.open": {
      const channel = id(parsed.ch);
      if (!channel) return bad("net.open without a channel id");
      const tunnelId = id(parsed.tunnel);
      if (!tunnelId) return bad("net.open without a tunnel id");
      return { ok: true, message: { t: "net.open", ch: channel, tunnel: tunnelId } };
    }
    case "net.data": {
      const channel = id(parsed.ch);
      if (!channel) return bad("net.data without a channel id");
      const data = parsed.data;
      if (typeof data !== "string") return bad("net.data without data");
      if (data.length > MAX_NET_DATA_CHARS) return tooLarge("net.data over the chunk limit");
      if (!BASE64_RE.test(data)) return bad("net.data is not base64");
      if (data.length % 4 !== 0) return bad("net.data is not base64");
      return { ok: true, message: { t: "net.data", ch: channel, data } };
    }
    case "net.ack": {
      const channel = id(parsed.ch);
      if (!channel) return bad("net.ack without a channel id");
      const bytes2 = whole(parsed.bytes, 1, NET_WINDOW_BYTES);
      if (bytes2 === null) return bad("net.ack out of range");
      return { ok: true, message: { t: "net.ack", ch: channel, bytes: bytes2 } };
    }
    case "net.close": {
      const channel = id(parsed.ch);
      return channel ? { ok: true, message: { t: "net.close", ch: channel } } : bad("net.close without a channel id");
    }
    /* ---- capability `upload` -------------------------------------------- */
    // Shape-checked here and authorised nowhere near here. Whether this desktop
    // will write a file at all, and what the name becomes on disk, are answered
    // in `uploads.ts` against a real directory.
    case "upload.begin": {
      const uploadId = id(parsed.id);
      if (!uploadId) return bad("upload.begin without an id");
      const name = parsed.name;
      if (typeof name !== "string" || name === "") return bad("upload.begin without a name");
      if (overBytes(name, MAX_UPLOAD_NAME_BYTES)) return tooLarge("upload.begin with a name over the limit");
      if (CONTROL_CHARS$1.test(name)) return bad("upload.begin with an unusable name");
      const size = whole(parsed.size, 1, MAX_UPLOAD_BYTES);
      if (size === null) return bad("upload.begin with an unusable size");
      return { ok: true, message: { t: "upload.begin", id: uploadId, name, size } };
    }
    case "upload.data": {
      const uploadId = id(parsed.id);
      if (!uploadId) return bad("upload.data without an id");
      const data = parsed.data;
      if (typeof data !== "string") return bad("upload.data without data");
      if (data.length > MAX_UPLOAD_DATA_CHARS) return tooLarge("upload.data over the chunk limit");
      if (!BASE64_RE.test(data)) return bad("upload.data is not base64");
      if (data.length % 4 !== 0) return bad("upload.data is not base64");
      return { ok: true, message: { t: "upload.data", id: uploadId, data } };
    }
    case "upload.end": {
      const uploadId = id(parsed.id);
      if (!uploadId) return bad("upload.end without an id");
      const digest = parsed.sha256;
      if (typeof digest !== "string" || digest.length !== SHA256_HEX_LENGTH || !HEX_RE.test(digest)) {
        return bad("upload.end without a digest");
      }
      return { ok: true, message: { t: "upload.end", id: uploadId, sha256: digest.toLowerCase() } };
    }
    case "upload.cancel": {
      const uploadId = id(parsed.id);
      return uploadId ? { ok: true, message: { t: "upload.cancel", id: uploadId } } : bad("upload.cancel without an id");
    }
    default:
      return bad("unknown message type");
  }
}
function serialize(message) {
  return JSON.stringify(message);
}
function costOf(code) {
  if (code < 128) return 1;
  if (code < 2048) return 2;
  if (code < 65536) return 3;
  return 4;
}
function chunkOutput(data, size = OUTPUT_CHUNK_BYTES) {
  if (data === "") return [];
  if (!overBytes(data, size)) return [data];
  const out = [];
  let start = 0;
  let bytes2 = 0;
  let at = 0;
  while (at < data.length) {
    const code = data.codePointAt(at);
    const units = code > 65535 ? 2 : 1;
    const cost = costOf(code);
    if (bytes2 + cost > size && at > start) {
      out.push(data.slice(start, at));
      start = at;
      bytes2 = 0;
    }
    bytes2 += cost;
    at += units;
  }
  if (start < data.length) out.push(data.slice(start));
  return out;
}
const LOOPBACK = "127.0.0.1";
function streamBudget(ceiling) {
  let used = 0;
  return {
    take() {
      if (used >= ceiling) return false;
      used += 1;
      return true;
    },
    give() {
      if (used > 0) used -= 1;
    }
  };
}
const MAX_TUNNELS = 4;
const MAX_STREAMS_PER_CONNECTION = 64;
const MAX_STREAMS_TOTAL = 256;
const DIAL_TIMEOUT_MS = 5e3;
function createTunnelHub(deps) {
  const now = deps.now ?? Date.now;
  const connect = deps.connect ?? ((port) => node_net.createConnection({ host: LOOPBACK, port }));
  const budget = deps.budget ?? streamBudget(MAX_STREAMS_TOTAL);
  const reserved = new Set(deps.reserved ?? []);
  const tunnels = /* @__PURE__ */ new Map();
  const streams = /* @__PURE__ */ new Map();
  const opening = /* @__PURE__ */ new Map();
  function changed() {
    try {
      deps.onChange?.();
    } catch (error) {
      console.error("[tunnel] change listener threw:", error);
    }
  }
  function closeTunnel(id2, message) {
    const pending = opening.get(id2);
    if (pending) {
      pending.cancelled = true;
      opening.delete(id2);
      deps.send({ t: "tunnel.closed", id: id2, message });
      return true;
    }
    const tunnel = tunnels.get(id2);
    if (!tunnel) return false;
    tunnels.delete(id2);
    for (const streamId of [...tunnel.streams]) dropStream(streamId, false);
    deps.send({ t: "tunnel.closed", id: id2, message });
    changed();
    return true;
  }
  function dropStream(id2, tell) {
    const stream = streams.get(id2);
    if (!stream) return;
    streams.delete(id2);
    tunnels.get(stream.tunnel)?.streams.delete(id2);
    if (!stream.closed) {
      stream.closed = true;
      budget.give();
    }
    stream.socket.destroy();
    if (tell) deps.send({ t: "net.close", ch: id2 });
  }
  function forward(stream, chunk) {
    for (let at = 0; at < chunk.length; at += MAX_NET_CHUNK_BYTES) {
      const piece = chunk.subarray(at, at + MAX_NET_CHUNK_BYTES);
      stream.unacked += piece.length;
      deps.send({ t: "net.data", ch: stream.id, data: piece.toString("base64") });
    }
    if (!stream.paused && stream.unacked >= NET_WINDOW_BYTES) {
      stream.paused = true;
      stream.socket.pause();
    }
  }
  async function offerPorts() {
    let ports;
    try {
      ports = await deps.scan();
    } catch (error) {
      console.error("[tunnel] port scan failed:", error);
      ports = [];
    }
    deps.send({ t: "ports", ports: ports.filter((entry) => !reserved.has(entry.port)) });
  }
  async function listening(port) {
    if (reserved.has(port)) return false;
    try {
      return (await deps.scan()).some((entry) => entry.port === port);
    } catch {
      return false;
    }
  }
  async function openTunnel(id2, port) {
    if (tunnels.has(id2) || opening.has(id2)) {
      deps.send({ t: "tunnel.closed", id: id2, message: "A tunnel with that id is already open." });
      return;
    }
    if (tunnels.size + opening.size >= MAX_TUNNELS) {
      deps.send({
        t: "tunnel.closed",
        id: id2,
        message: `This phone already has ${MAX_TUNNELS} ports open. Close one first.`
      });
      return;
    }
    const pending = { cancelled: false };
    opening.set(id2, pending);
    let live;
    try {
      live = await listening(port);
    } finally {
      opening.delete(id2);
    }
    if (pending.cancelled) return;
    if (!live) {
      deps.send({
        t: "tunnel.closed",
        id: id2,
        message: `Nothing is listening on port ${port} on the Mac any more.`
      });
      return;
    }
    tunnels.set(id2, { id: id2, port, openedAt: now(), streams: /* @__PURE__ */ new Set() });
    deps.send({ t: "tunnel.opened", id: id2, port });
    changed();
  }
  function openStream(ch, tunnelId) {
    const tunnel = tunnels.get(tunnelId);
    if (!tunnel || streams.has(ch)) return deps.send({ t: "net.close", ch });
    if (streams.size >= MAX_STREAMS_PER_CONNECTION || !budget.take()) {
      return deps.send({ t: "net.close", ch });
    }
    const socket = connect(tunnel.port);
    const stream = { id: ch, tunnel: tunnelId, socket, unacked: 0, paused: false, closed: false };
    streams.set(ch, stream);
    tunnel.streams.add(ch);
    changed();
    socket.setNoDelay(true);
    socket.setTimeout(DIAL_TIMEOUT_MS, () => {
      if (!stream.closed) dropStream(ch, true);
    });
    socket.once("connect", () => socket.setTimeout(0));
    socket.on("data", (chunk) => forward(stream, chunk));
    socket.on("error", () => dropStream(ch, true));
    socket.on("end", () => dropStream(ch, true));
    socket.on("close", () => dropStream(ch, true));
  }
  function write(ch, data) {
    const stream = streams.get(ch);
    if (!stream || stream.closed) return;
    const bytes2 = Buffer.from(data, "base64");
    if (bytes2.length === 0) return;
    stream.socket.write(bytes2, () => {
      if (stream.closed) return;
      deps.send({ t: "net.ack", ch, bytes: bytes2.length });
    });
  }
  function acknowledge(ch, bytes2) {
    const stream = streams.get(ch);
    if (!stream || stream.closed) return;
    stream.unacked = Math.max(0, stream.unacked - bytes2);
    if (stream.paused && stream.unacked < NET_WINDOW_BYTES) {
      stream.paused = false;
      stream.socket.resume();
    }
  }
  return {
    handle(message) {
      switch (message.t) {
        case "ports":
          void offerPorts();
          return;
        case "tunnel.open":
          void openTunnel(message.id, message.port);
          return;
        case "tunnel.close":
          if (!closeTunnel(message.id, "Closed on the phone.")) {
            deps.send({ t: "tunnel.closed", id: message.id, message: "Closed on the phone." });
          }
          return;
        case "net.open":
          openStream(message.ch, message.tunnel);
          return;
        case "net.data":
          write(message.ch, message.data);
          return;
        case "net.ack":
          acknowledge(message.ch, message.bytes);
          return;
        case "net.close":
          dropStream(message.ch, false);
          return;
      }
    },
    list() {
      return [...tunnels.values()].map((tunnel) => ({
        id: tunnel.id,
        port: tunnel.port,
        streams: tunnel.streams.size,
        openedAt: tunnel.openedAt
      })).sort((a, b) => a.openedAt - b.openedAt);
    },
    stop(id2, message) {
      return closeTunnel(id2, message);
    },
    closeAll() {
      for (const id2 of [...streams.keys()]) dropStream(id2, false);
      for (const pending of opening.values()) pending.cancelled = true;
      opening.clear();
      const had = tunnels.size > 0;
      tunnels.clear();
      if (had) changed();
    }
  };
}
const MAX_UPLOADS_PER_CONNECTION = 1;
const MAX_NAME_ATTEMPTS = 99;
function createUploadDesk(deps) {
  const now = deps.now ?? Date.now;
  const live = /* @__PURE__ */ new Map();
  const opening = /* @__PURE__ */ new Map();
  function changed() {
    try {
      deps.onChange?.();
    } catch (error) {
      console.error("[upload] change listener threw:", error);
    }
  }
  function fail2(id2, message) {
    const upload = live.get(id2);
    if (!upload) {
      deps.send({ t: "upload.failed", id: id2, message });
      return;
    }
    live.delete(id2);
    upload.finished = true;
    void upload.sink.discard();
    deps.send({ t: "upload.failed", id: id2, message });
    changed();
  }
  async function begin(id2, name, size) {
    if (live.has(id2) || opening.has(id2)) {
      deps.send({ t: "upload.failed", id: id2, message: "That upload is already running." });
      return;
    }
    if (live.size + opening.size >= MAX_UPLOADS_PER_CONNECTION) {
      deps.send({
        t: "upload.failed",
        id: id2,
        message: "This phone is already sending a file. Wait for it to finish, or cancel it."
      });
      return;
    }
    const pending = { cancelled: false };
    opening.set(id2, pending);
    let opened;
    try {
      opened = await deps.store.open(safeName(name));
    } catch (error) {
      opening.delete(id2);
      console.error("[upload] could not open a file:", error);
      if (!pending.cancelled) {
        deps.send({
          t: "upload.failed",
          id: id2,
          // The folder is not named in this sentence: it is about to be shown on
          // the phone by `upload.ready` in the successful case, and a failure is
          // the wrong moment to be quoting a path from somebody's home directory
          // into a message that crosses a network.
          message: "This Mac could not create a file for that. Check that its downloads folder is writable."
        });
      }
      return;
    }
    opening.delete(id2);
    if (pending.cancelled) {
      void opened.sink.discard();
      return;
    }
    live.set(id2, {
      id: id2,
      name: basenameOf$1(opened.path),
      path: opened.path,
      size,
      taken: 0,
      acked: 0,
      sink: opened.sink,
      digest: node_crypto.createHash("sha256"),
      startedAt: now(),
      finished: false
    });
    deps.send({ t: "upload.ready", id: id2, path: opened.path });
    changed();
  }
  function data(id2, encoded) {
    const upload = live.get(id2);
    if (!upload || upload.finished) return;
    const bytes2 = Buffer.from(encoded, "base64");
    if (bytes2.length === 0) return;
    if (upload.taken + bytes2.length > upload.size) {
      fail2(id2, "That file sent more bytes than it said it would. Nothing was saved.");
      return;
    }
    upload.taken += bytes2.length;
    upload.digest.update(bytes2);
    upload.sink.write(bytes2, (error) => {
      if (upload.finished) return;
      if (error) {
        console.error("[upload] write failed:", error);
        fail2(id2, "This Mac stopped being able to write that file. Nothing was saved.");
        return;
      }
      upload.acked += bytes2.length;
      deps.send({ t: "upload.ack", id: id2, bytes: bytes2.length });
    });
  }
  async function end(id2, claimed) {
    const upload = live.get(id2);
    if (!upload || upload.finished) {
      deps.send({ t: "upload.failed", id: id2, message: "There is no upload with that id on this Mac." });
      return;
    }
    if (upload.taken !== upload.size) {
      fail2(id2, `That upload ended early — ${upload.taken} of ${upload.size} bytes arrived. Nothing was saved.`);
      return;
    }
    const actual = upload.digest.digest("hex");
    if (actual !== claimed) {
      fail2(id2, "That file arrived corrupted — the checksum does not match. Nothing was saved.");
      return;
    }
    live.delete(id2);
    upload.finished = true;
    try {
      await upload.sink.commit();
    } catch (error) {
      console.error("[upload] could not move the file into place:", error);
      void upload.sink.discard();
      deps.send({
        t: "upload.failed",
        id: id2,
        message: "This Mac could not put that file in its downloads folder. Nothing was saved."
      });
      changed();
      return;
    }
    deps.send({ t: "upload.done", id: id2, path: upload.path, bytes: upload.size, sha256: actual });
    changed();
  }
  return {
    handle(message) {
      switch (message.t) {
        case "upload.begin":
          void begin(message.id, message.name, message.size);
          return;
        case "upload.data":
          data(message.id, message.data);
          return;
        case "upload.end":
          void end(message.id, message.sha256);
          return;
        case "upload.cancel": {
          const pending = opening.get(message.id);
          if (pending) {
            pending.cancelled = true;
            opening.delete(message.id);
            deps.send({ t: "upload.failed", id: message.id, message: "Cancelled on the phone." });
            return;
          }
          fail2(message.id, "Cancelled on the phone.");
          return;
        }
      }
    },
    list() {
      return [...live.values()].map((upload) => ({
        id: upload.id,
        name: upload.name,
        path: upload.path,
        size: upload.size,
        received: upload.acked,
        startedAt: upload.startedAt
      })).sort((a, b) => a.startedAt - b.startedAt);
    },
    closeAll() {
      const had = live.size > 0;
      for (const upload of live.values()) {
        upload.finished = true;
        void upload.sink.discard();
      }
      live.clear();
      for (const pending of opening.values()) pending.cancelled = true;
      opening.clear();
      if (had) changed();
    }
  };
}
function diskUploadStore(dir) {
  return {
    async open(name) {
      await promises.mkdir(dir, { recursive: true });
      for (const candidate of nameVariants(name)) {
        const path = node_path.join(dir, candidate);
        const partial = `${path}.part`;
        let handle2;
        try {
          handle2 = await promises.open(partial, "wx");
        } catch (error) {
          if (error.code === "EEXIST") continue;
          throw error;
        }
        try {
          const existing = await promises.open(path, "r");
          await existing.close();
          await handle2.close();
          await promises.unlink(partial).catch(() => {
          });
          continue;
        } catch (error) {
          if (error.code !== "ENOENT") {
            await handle2.close();
            await promises.unlink(partial).catch(() => {
            });
            throw error;
          }
        }
        return { path, sink: streamSink(handle2.createWriteStream({ autoClose: true }), partial, path) };
      }
      throw new Error("every variant of that file name is taken");
    }
  };
}
function streamSink(stream, partial, path) {
  let closed = null;
  const shut = () => {
    closed ??= new Promise((settle) => {
      stream.once("close", () => settle());
      stream.once("error", () => settle());
      stream.end();
    });
    return closed;
  };
  return {
    write(chunk, done) {
      stream.write(chunk, done);
    },
    async commit() {
      await shut();
      await promises.rename(partial, path);
    },
    async discard() {
      try {
        await shut();
        await promises.unlink(partial);
      } catch (error) {
        if (error.code !== "ENOENT") {
          console.error("[upload] could not delete a partial file:", error);
        }
      }
    }
  };
}
const FORBIDDEN = /[<>:"|?*\\/\u0000-\u001f\u007f]/g;
const DEVICE_NAMES = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i;
function safeName(suggested) {
  const components = suggested.split(/[\\/]/);
  const last = components[components.length - 1] ?? "";
  let name = last.replace(FORBIDDEN, "_");
  name = name.replace(/^[.\s]+/, "").replace(/[.\s]+$/, "");
  if (name === "") return "file";
  const extension = node_path.extname(name);
  const stem = extension === "" ? name : name.slice(0, -extension.length);
  if (stem !== "" && DEVICE_NAMES.test(stem)) name = `_${name}`;
  return capBytes(name, MAX_UPLOAD_NAME_BYTES);
}
function capBytes(name, cap) {
  if (Buffer.byteLength(name, "utf8") <= cap) return name;
  const extension = node_path.extname(name);
  const keep = Math.max(0, cap - Buffer.byteLength(extension, "utf8"));
  const stem = extension === "" ? name : name.slice(0, -extension.length);
  let bytes2 = 0;
  let out = "";
  for (const point of stem) {
    const cost = Buffer.byteLength(point, "utf8");
    if (bytes2 + cost > keep) break;
    out += point;
    bytes2 += cost;
  }
  const capped = `${out}${extension}`;
  return capped === extension && extension.length > 0 ? extension.slice(0, cap) : capped || "file";
}
function* nameVariants(name) {
  yield name;
  const extension = node_path.extname(name);
  const stem = extension === "" ? name : name.slice(0, -extension.length);
  for (let n = 2; n <= MAX_NAME_ATTEMPTS; n += 1) {
    yield capBytes(`${stem} (${n})${extension}`, MAX_UPLOAD_NAME_BYTES);
  }
}
function basenameOf$1(path) {
  const parts = path.split(/[\\/]/);
  return parts[parts.length - 1] ?? path;
}
const RELAY_HOST_PATH = "/v1/host";
const RELAY_SECRET_HEADER = "x-deck-host-secret";
const DEFAULT_RELAY_URL = "wss://relay.terminaldeck.dev";
const ENVELOPE = { open: 1, data: 2, close: 3 };
const CHANNEL_BYTES = 16;
const ENVELOPE_HEADER = 1 + CHANNEL_BYTES;
const MAX_PAYLOAD_BYTES = 96 * 1024;
function encodeEnvelope(type, channel, payload) {
  if (channel.length !== CHANNEL_BYTES) throw new Error("channel id must be 16 bytes");
  const header = Buffer.alloc(ENVELOPE_HEADER);
  header[0] = type;
  channel.copy(header, 1);
  return Buffer.concat([header, payload]);
}
function decodeEnvelope(frame2) {
  if (frame2.length < ENVELOPE_HEADER) return null;
  const type = frame2[0];
  if (type !== ENVELOPE.open && type !== ENVELOPE.data && type !== ENVELOPE.close) return null;
  return {
    type,
    channel: Buffer.from(frame2.subarray(1, ENVELOPE_HEADER)),
    payload: Buffer.from(frame2.subarray(ENVELOPE_HEADER))
  };
}
const BASE32 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function base32(bytes2, length) {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes2) {
    value = value << 8 | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += BASE32[value >> bits & 31];
      if (out.length === length) return out;
    }
  }
  return out;
}
function hostIdFor(hostSecret) {
  return base32(node_crypto.createHash("sha256").update(hostSecret).digest(), 26);
}
const HOST_SECRET_BYTES = 32;
const RELAY_SEALED_VERSION = SEALED_VERSION;
const NOISE_MESSAGE_BYTES = 80;
const HANDSHAKE_OPEN_BYTES = 1 + NOISE_MESSAGE_BYTES;
function withSealedVersion(message) {
  return Buffer.concat([Buffer.from([RELAY_SEALED_VERSION]), message]);
}
function readSealedHandshake(payload, expected) {
  if (payload.length !== expected) return { ok: false, reason: "malformed" };
  if (payload[0] !== RELAY_SEALED_VERSION) return { ok: false, reason: "wrong-version" };
  return { ok: true, message: Buffer.from(payload.subarray(1)) };
}
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
function acceptKey(key) {
  return node_crypto.createHash("sha1").update(key + WS_GUID).digest("base64");
}
const OPCODE = {
  continuation: 0,
  text: 1,
  binary: 2,
  close: 8,
  ping: 9,
  pong: 10
};
function encodeFrame(opcode, payload) {
  return frame(opcode, payload, null);
}
function encodeMaskedFrame(opcode, payload) {
  return frame(opcode, payload, node_crypto.randomBytes(4));
}
function frame(opcode, payload, mask) {
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.alloc(2);
    header[1] = length;
  } else if (length < 65536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  header[0] = 128 | opcode;
  if (!mask) return Buffer.concat([header, payload]);
  header[1] |= 128;
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3];
  return Buffer.concat([header, mask, masked]);
}
class FrameReader {
  /**
   * @param side which end this reader is. `'server'` reads frames from clients
   *   and therefore requires them masked; `'client'` reads frames from a server
   *   and requires them unmasked. Defaults to `'server'`, which is what the
   *   app's own listener wants and what this class did before it had a choice.
   */
  constructor(maxFrameBytes, side = "server") {
    this.maxFrameBytes = maxFrameBytes;
    this.expectMask = side === "server";
  }
  maxFrameBytes;
  incoming = Buffer.alloc(0);
  expectMask;
  /** Drop buffered bytes. Called when a connection ends mid-frame. */
  reset() {
    this.incoming = Buffer.alloc(0);
  }
  push(chunk) {
    this.incoming = this.incoming.length === 0 ? chunk : Buffer.concat([this.incoming, chunk]);
    const frames = [];
    for (; ; ) {
      const buf = this.incoming;
      if (buf.length < 2) return { ok: true, frames };
      const first = buf[0];
      const second = buf[1];
      if ((first & 112) !== 0) {
        return { ok: false, frames, error: { reason: "reserved-bits", detail: "reserved bits set" } };
      }
      const fin = (first & 128) !== 0;
      const opcode = first & 15;
      const masked = (second & 128) !== 0;
      if (masked !== this.expectMask) {
        return this.expectMask ? { ok: false, frames, error: { reason: "unmasked", detail: "client frame was not masked" } } : { ok: false, frames, error: { reason: "masked", detail: "server frame was masked" } };
      }
      let length = second & 127;
      let offset = 2;
      if (length === 126) {
        if (buf.length < offset + 2) return { ok: true, frames };
        length = buf.readUInt16BE(offset);
        offset += 2;
      } else if (length === 127) {
        if (buf.length < offset + 8) return { ok: true, frames };
        const wide = buf.readBigUInt64BE(offset);
        offset += 8;
        if (wide > BigInt(this.maxFrameBytes)) {
          return { ok: false, frames, error: { reason: "too-large", detail: "frame too large" } };
        }
        length = Number(wide);
      }
      if (length > this.maxFrameBytes) {
        return { ok: false, frames, error: { reason: "too-large", detail: "frame too large" } };
      }
      const keyBytes = masked ? 4 : 0;
      const total = offset + keyBytes + length;
      if (buf.length < total) return { ok: true, frames };
      const payload = Buffer.from(buf.subarray(offset + keyBytes, total));
      if (masked) {
        const mask = buf.subarray(offset, offset + keyBytes);
        for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i & 3];
      }
      this.incoming = buf.subarray(total);
      frames.push({ fin, opcode, payload });
    }
  }
}
const BASE_BACKOFF_MS = 1e3;
const MAX_BACKOFF_MS = 6e4;
const STABLE_MS = 6e4;
const HEARTBEAT_MS = 2e4;
const CONNECT_TIMEOUT_MS = 15e3;
const WATCHDOG_MS = 5e3;
const SLEEP_SLACK_MS = 2e4;
const MAX_CHANNELS = 16;
const MAX_BUFFERED_BYTES$1 = 8 * 1024 * 1024;
const MAX_RESPONSE_HEAD_BYTES = 16 * 1024;
const REFUSAL_LOG_INTERVAL_MS = 6e4;
const CLOSE_LINGER_MS$1 = 1e3;
const RELAY_URL_ENV = "TERMINALDECK_RELAY_URL";
const RELAY_ENABLED_ENV = "TERMINALDECK_RELAY";
const OFF = /* @__PURE__ */ new Set(["off", "0", "false", "no"]);
function text(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}
function relayUrl(env, configured) {
  return text(env[RELAY_URL_ENV]) ?? text(configured) ?? DEFAULT_RELAY_URL;
}
function relayEnabled(env, configured) {
  const said = text(env[RELAY_ENABLED_ENV]);
  if (said !== null) return !OFF.has(said.toLowerCase());
  return configured !== false;
}
function isLoopback$2(host) {
  const bare = host.startsWith("[") && host.endsWith("]") ? host.slice(1, -1) : host;
  if (bare === "localhost") return true;
  if (node_net.isIP(bare) === 4) return bare.startsWith("127.");
  return bare === "::1";
}
function relayTarget(raw) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    return { ok: false, reason: `“${raw}” is not a URL, so there is no relay to dial.` };
  }
  if (url.protocol === "wss:") return { ok: true, url, secure: true };
  if (url.protocol !== "ws:") {
    return {
      ok: false,
      reason: `A relay URL has to start with wss://, and this one starts with ${url.protocol}//.`
    };
  }
  if (!isLoopback$2(url.hostname)) {
    return {
      ok: false,
      reason: "A ws:// relay would send this Mac’s host secret in clear text. Use wss:// — ws:// is only allowed for a relay running on this machine."
    };
  }
  return { ok: true, url, secure: false };
}
function addressFor(devicePublicKey) {
  const digest = node_crypto.createHash("sha256").update(devicePublicKey).digest("base64url");
  return `relay:${digest.slice(0, 16)}`;
}
function createRelayClient(options) {
  const now = options.now ?? Date.now;
  const baseBackoffMs = options.baseBackoffMs ?? BASE_BACKOFF_MS;
  const maxBackoffMs = options.maxBackoffMs ?? MAX_BACKOFF_MS;
  const heartbeatMs = options.heartbeatMs ?? HEARTBEAT_MS;
  const connectTimeoutMs = options.connectTimeoutMs ?? CONNECT_TIMEOUT_MS;
  const watchdogMs = options.watchdogMs ?? WATCHDOG_MS;
  const identity = options.identity;
  const channels = /* @__PURE__ */ new Map();
  let attach2 = null;
  let stopped = true;
  let socket = null;
  let reader = new FrameReader(MAX_PAYLOAD_BYTES + ENVELOPE_HEADER, "client");
  let dialling = false;
  let connectedAt = 0;
  let attempts = 0;
  let reason = null;
  let retryAt = null;
  let retry = null;
  let heartbeat = null;
  let watchdog = null;
  let awaitingPong = false;
  let lastTick = 0;
  let refusalsSinceLog = 0;
  let refusalLoggedAt = 0;
  function state() {
    return {
      url: options.url,
      hostId: identity.hostId,
      publicKey: identity.keys.publicKey.toString("base64url"),
      fingerprint: identity.fingerprint,
      connected: socket !== null,
      channels: channels.size,
      reason: socket === null ? reason : null,
      retryAt
    };
  }
  function write(opcode, payload) {
    const live = socket;
    if (!live) return;
    try {
      live.write(encodeMaskedFrame(opcode, payload));
    } catch {
      drop("The link to the relay failed while sending.");
    }
  }
  function sendEnvelope(type, channel, payload) {
    write(OPCODE.binary, encodeEnvelope(type, channel, payload));
  }
  function closeChannel(channel, why) {
    if (channel.closed) return;
    channel.closed = true;
    channels.delete(channel.key);
    sendEnvelope(ENVELOPE.close, channel.id, Buffer.alloc(0));
    const handlers = channel.handlers;
    channel.handlers = null;
    if (!handlers) return;
    try {
      handlers.closed();
    } catch (error) {
      console.error(`[relay] a channel closed badly (${why}):`, error);
    }
  }
  function wireFor(channel) {
    return {
      send(payload) {
        const live = socket;
        if (channel.closed || !channel.transport || !live) return;
        if (live.writableLength > MAX_BUFFERED_BYTES$1) {
          closeChannel(channel, "output backed up");
          return;
        }
        let sealed;
        try {
          sealed = channel.transport.send(Buffer.from(payload, "utf8"));
        } catch {
          closeChannel(channel, "the sealed channel is exhausted");
          return;
        }
        sendEnvelope(ENVELOPE.data, channel.id, sealed);
      },
      // The close code and reason do not cross a relay: there is no WebSocket
      // close frame to put them in, only an envelope that says "gone". The
      // protocol's own `error` message carries the words, and it is sent before
      // this by every path that refuses a connection.
      close: () => closeChannel(channel, "closed by the desktop")
    };
  }
  function openChannel(id2) {
    const key = id2.toString("hex");
    if (channels.has(key)) return;
    if (channels.size >= MAX_CHANNELS) {
      sendEnvelope(ENVELOPE.close, id2, Buffer.alloc(0));
      return;
    }
    channels.set(key, { id: id2, key, transport: null, handlers: null, closed: false });
  }
  function handshake(channel, payload) {
    const opened = readSealedHandshake(payload, HANDSHAKE_OPEN_BYTES);
    if (!opened.ok) {
      if (opened.reason === "wrong-version") {
        console.error(
          "[relay] a device asked for a sealed channel this build does not speak; one of the two needs updating."
        );
      }
      closeChannel(channel, `handshake ${opened.reason}`);
      return;
    }
    let result;
    try {
      result = respondToHandshake(identity.keys, opened.message, options.isKnownDevice);
    } catch (error) {
      if (error instanceof SealedRefusal) {
        refusalsSinceLog += 1;
        const now2 = Date.now();
        if (now2 - refusalLoggedAt >= REFUSAL_LOG_INTERVAL_MS) {
          const also = refusalsSinceLog > 1 ? ` (${refusalsSinceLog} refused since the last line)` : "";
          console.warn(
            `[relay] refused a sealed handshake${also}: the device is not paired with this Mac, or it is paired with a different one. Pair it again if it should have access.`
          );
          refusalLoggedAt = now2;
          refusalsSinceLog = 0;
        }
      } else {
        console.error(
          "[relay] the sealed handshake could not run on this machine — remote access is broken for every device, not just this one. This is a fault in the build, not a refusal:",
          error
        );
      }
      closeChannel(channel, "handshake failed authentication");
      return;
    }
    channel.transport = result.transport;
    const accepted = attach2?.(
      addressFor(result.devicePublicKey),
      (handlers) => {
        channel.handlers = handlers;
        return wireFor(channel);
      },
      result.devicePublicKey
    );
    if (accepted !== true) {
      closeChannel(channel, "too many connections");
      return;
    }
    sendEnvelope(ENVELOPE.data, channel.id, withSealedVersion(result.reply));
  }
  function onEnvelope(frame2) {
    const envelope = decodeEnvelope(frame2);
    if (!envelope) return;
    if (envelope.type === ENVELOPE.open) {
      openChannel(envelope.channel);
      return;
    }
    const channel = channels.get(envelope.channel.toString("hex"));
    if (!channel) return;
    if (envelope.type === ENVELOPE.close) {
      closeChannel(channel, "the phone disconnected");
      return;
    }
    if (!channel.transport) {
      handshake(channel, envelope.payload);
      return;
    }
    let message;
    try {
      message = channel.transport.receiveText(envelope.payload);
    } catch {
      closeChannel(channel, "sealed frame failed authentication");
      return;
    }
    const handlers = channel.handlers;
    if (!handlers) return;
    try {
      handlers.message(message);
    } catch (error) {
      console.error("[relay] message handler threw:", error);
      closeChannel(channel, "internal error");
    }
  }
  function receive(chunk) {
    if (!socket) return;
    const batch = reader.push(chunk);
    for (const frame2 of batch.frames) {
      if (!socket) return;
      if (frame2.opcode === OPCODE.close) return drop("The relay closed the connection.");
      if (frame2.opcode === OPCODE.ping) {
        write(OPCODE.pong, frame2.payload);
        continue;
      }
      if (frame2.opcode === OPCODE.pong) {
        awaitingPong = false;
        continue;
      }
      if (!frame2.fin) return drop("The relay sent a fragmented frame.");
      if (frame2.opcode === OPCODE.binary) onEnvelope(frame2.payload);
    }
    if (!batch.ok) drop(`The relay sent a frame this build cannot read: ${batch.error.detail}.`);
  }
  function drop(why) {
    const live = socket;
    socket = null;
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = null;
    awaitingPong = false;
    reader.reset();
    for (const channel of [...channels.values()]) closeChannel(channel, why);
    channels.clear();
    if (live) {
      live.removeAllListeners();
      try {
        if (!live.destroyed) {
          live.end();
          const linger = setTimeout(() => live.destroy(), CLOSE_LINGER_MS$1);
          linger.unref?.();
        }
      } catch {
      }
    }
    const wasStable = connectedAt !== 0 && now() - connectedAt >= STABLE_MS;
    connectedAt = 0;
    reason = why;
    if (stopped) {
      retryAt = null;
      return;
    }
    if (wasStable) attempts = 0;
    schedule();
  }
  function schedule() {
    if (retry || stopped || dialling || socket) return;
    const ceiling = Math.min(maxBackoffMs, baseBackoffMs * 2 ** Math.min(attempts, 6));
    const delay2 = Math.round(ceiling / 2 + Math.random() * (ceiling / 2));
    attempts += 1;
    retryAt = now() + delay2;
    retry = setTimeout(() => {
      retry = null;
      retryAt = null;
      void dial();
    }, delay2);
    retry.unref?.();
  }
  function headerOf(head, name) {
    for (const line of head.split("\r\n").slice(1)) {
      const at = line.indexOf(":");
      if (at === -1) continue;
      if (line.slice(0, at).trim().toLowerCase() !== name) continue;
      return line.slice(at + 1).trim();
    }
    return null;
  }
  async function dial() {
    if (stopped || dialling || socket) return;
    const target2 = relayTarget(options.url);
    if (!target2.ok) {
      reason = target2.reason;
      schedule();
      return;
    }
    dialling = true;
    const { url, secure } = target2;
    const port = url.port === "" ? secure ? 443 : 80 : Number(url.port);
    const prefix = url.pathname.replace(/\/+$/, "");
    const path = `${prefix}${RELAY_HOST_PATH}${url.search}`;
    const key = node_crypto.randomBytes(16).toString("base64");
    let live;
    try {
      live = secure ? (
        // Certificate verification is on, which is the default and is what
        // makes `wss:` mean anything: without it the header below would go to
        // whoever answered the DNS query.
        node_tls.connect({ host: url.hostname, port, servername: url.hostname, ALPNProtocols: ["http/1.1"] })
      ) : node_net.connect({ host: url.hostname, port });
    } catch (error) {
      dialling = false;
      reason = `Could not dial the relay: ${error instanceof Error ? error.message : String(error)}.`;
      schedule();
      return;
    }
    if ("setNoDelay" in live && typeof live.setNoDelay === "function") live.setNoDelay(true);
    const timer = setTimeout(() => live.destroy(new Error("timed out")), connectTimeoutMs);
    timer.unref?.();
    let upgraded = false;
    let pending = Buffer.alloc(0);
    let head = null;
    let onHead = null;
    let onHeadFailed = null;
    live.on("data", (chunk) => {
      if (upgraded) return receive(chunk);
      pending = Buffer.concat([pending, chunk]);
      if (head !== null) return;
      const end = pending.indexOf("\r\n\r\n");
      if (end === -1) {
        if (pending.length > MAX_RESPONSE_HEAD_BYTES) {
          onHeadFailed?.(new Error("the relay sent a response head with no end to it"));
        }
        return;
      }
      head = pending.subarray(0, end).toString("latin1");
      pending = Buffer.from(pending.subarray(end + 4));
      onHead?.();
    });
    const gone = (phrase) => {
      if (upgraded) return drop(`${phrase[0].toUpperCase()}${phrase.slice(1)}.`);
      onHeadFailed?.(new Error(phrase));
    };
    live.on("error", () => gone("the link to the relay failed"));
    live.on("close", () => gone("the relay closed the connection"));
    live.on("end", () => gone("the relay stopped answering"));
    try {
      await new Promise((settle, fail2) => {
        onHeadFailed = fail2;
        live.once(secure ? "secureConnect" : "connect", () => settle());
      });
      const host = url.port === "" ? url.hostname : `${url.hostname}:${url.port}`;
      live.write(
        [
          `GET ${path} HTTP/1.1`,
          `Host: ${host}`,
          "Upgrade: websocket",
          "Connection: Upgrade",
          `Sec-WebSocket-Key: ${key}`,
          "Sec-WebSocket-Version: 13",
          `${RELAY_SECRET_HEADER}: ${identity.hostSecret.toString("base64url")}`,
          "",
          ""
        ].join("\r\n")
      );
      await new Promise((settle, fail2) => {
        if (head !== null) return settle();
        onHead = settle;
        onHeadFailed = fail2;
      });
      const answered = head ?? "";
      const status = Number(/^HTTP\/1\.1 (\d+)/.exec(answered)?.[1] ?? 0);
      if (status !== 101) {
        throw new Error(
          status === 401 ? "the relay would not accept this Mac’s host secret" : `the relay answered ${status || "nothing"} instead of upgrading the connection`
        );
      }
      if (headerOf(answered, "sec-websocket-accept") !== acceptKey(key)) {
        throw new Error("the relay answered an upgrade that does not match the request");
      }
    } catch (error) {
      clearTimeout(timer);
      dialling = false;
      live.removeAllListeners();
      live.destroy();
      reason = `Could not reach the relay: ${error instanceof Error ? error.message : String(error)}.`;
      schedule();
      return;
    }
    clearTimeout(timer);
    onHead = null;
    onHeadFailed = null;
    dialling = false;
    if (stopped) {
      live.removeAllListeners();
      live.destroy();
      return;
    }
    connectedAt = now();
    reason = null;
    retryAt = null;
    reader = new FrameReader(MAX_PAYLOAD_BYTES + ENVELOPE_HEADER, "client");
    socket = live;
    upgraded = true;
    if (pending.length > 0) {
      const rest = pending;
      pending = Buffer.alloc(0);
      receive(rest);
    }
    if (heartbeat) clearInterval(heartbeat);
    if (heartbeatMs > 0) {
      heartbeat = setInterval(() => {
        if (!socket) return;
        if (awaitingPong) return drop("The relay stopped answering pings.");
        awaitingPong = true;
        write(OPCODE.ping, Buffer.alloc(0));
      }, heartbeatMs);
      heartbeat.unref?.();
    }
  }
  function wake() {
    attempts = 0;
    if (socket) {
      drop("The Mac woke up, so the link was replaced.");
      return;
    }
    if (retry) {
      clearTimeout(retry);
      retry = null;
      retryAt = null;
    }
    void dial();
  }
  return {
    start(next) {
      attach2 = next;
      if (!stopped) return;
      stopped = false;
      attempts = 0;
      lastTick = now();
      if (watchdogMs > 0) {
        watchdog = setInterval(() => {
          const at = now();
          const late = at - lastTick;
          lastTick = at;
          if (late > watchdogMs + SLEEP_SLACK_MS) wake();
        }, watchdogMs);
        watchdog.unref?.();
      }
      void dial();
    },
    wake() {
      if (stopped) return;
      lastTick = now();
      wake();
    },
    stop() {
      stopped = true;
      attach2 = null;
      if (retry) clearTimeout(retry);
      retry = null;
      retryAt = null;
      if (watchdog) clearInterval(watchdog);
      watchdog = null;
      if (socket) write(OPCODE.close, Buffer.alloc(0));
      drop("Remote access is switched off.");
      reason = null;
    },
    state
  };
}
const HOST_IDENTITY_FILE = "relay-identity.json";
const MAX_FILE_BYTES = 64 * 1024;
const KEY_BYTES = 32;
function isRecord$4(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function bytes(value, length) {
  if (typeof value !== "string" || value.length > 128) return null;
  const raw = Buffer.from(value, "base64");
  return raw.length === length ? raw : null;
}
function pairIsSound(keys) {
  try {
    const probe2 = generateStatic();
    const { message } = startHandshake(probe2, keys.publicKey);
    respondToHandshake(keys, message, () => true);
    return { verdict: "sound" };
  } catch (err) {
    if (err instanceof SealedRefusal) return { verdict: "corrupt", error: err };
    return { verdict: "runtime-broken", error: err };
  }
}
function decode(raw) {
  if (!isRecord$4(raw)) return { verdict: "corrupt" };
  const hostSecret = bytes(raw.hostSecret, HOST_SECRET_BYTES);
  const publicKey = bytes(raw.publicKey, KEY_BYTES);
  const privateKey = bytes(raw.privateKey, KEY_BYTES);
  if (!hostSecret || !publicKey || !privateKey) return { verdict: "corrupt" };
  const keys = { publicKey, privateKey };
  const identity = {
    hostSecret,
    hostId: hostIdFor(hostSecret),
    keys,
    fingerprint: fingerprint(publicKey)
  };
  const checked = pairIsSound(keys);
  if (checked.verdict === "sound") return { verdict: "sound", identity };
  if (checked.verdict === "corrupt") return { verdict: "corrupt" };
  return { verdict: "runtime-broken", identity, error: checked.error };
}
function fresh() {
  const hostSecret = secretBytes(HOST_SECRET_BYTES);
  const keys = generateStatic();
  return {
    identity: {
      hostSecret,
      hostId: hostIdFor(hostSecret),
      keys,
      fingerprint: fingerprint(keys.publicKey)
    },
    stored: {
      version: 1,
      hostSecret: hostSecret.toString("base64"),
      publicKey: keys.publicKey.toString("base64"),
      privateKey: keys.privateKey.toString("base64")
    }
  };
}
function quarantine(file, reason) {
  const aside = `${file}.corrupt-${Date.now()}-${secretBytes(4).toString("hex")}`;
  try {
    node_fs.renameSync(file, aside);
    console.error(
      `[relay] the relay identity was ${reason}; moved aside to ${aside}. This Mac has a new host id, so every paired phone has to be paired again.`
    );
  } catch (err) {
    console.error(`[relay] the relay identity was ${reason} and could not be moved aside:`, err);
  }
}
function loadHostIdentity(dir) {
  const file = node_path.join(dir, HOST_IDENTITY_FILE);
  let raw = null;
  try {
    const { size } = node_fs.statSync(file);
    raw = size > MAX_FILE_BYTES ? null : node_fs.readFileSync(file, "utf8");
    if (raw === null) quarantine(file, `oversized (${size} bytes)`);
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.error("[relay] the relay identity could not be read:", err);
    }
  }
  if (raw !== null) {
    let parsed = null;
    try {
      parsed = JSON.parse(raw);
    } catch {
      parsed = null;
    }
    const existing = decode(parsed);
    if (existing.verdict === "sound") return existing.identity;
    if (existing.verdict === "runtime-broken") {
      console.error(
        "[relay] this build cannot run the sealed handshake, so the stored identity could not be verified. It has been KEPT and is being used as-is — every paired device stays paired. Remote access will not work until the build is fixed:",
        existing.error
      );
      return existing.identity;
    }
    quarantine(file, "not a usable identity");
  }
  const { identity, stored } = fresh();
  writeSecretFile(dir, file, JSON.stringify(stored, null, 2));
  return identity;
}
const run$5 = node_util.promisify(node_child_process.execFile);
async function serveOn(httpsPort, localPort) {
  const binary = await findTailscale();
  if (!binary) {
    return { ok: false, message: "The tailscale command could not be found on this Mac." };
  }
  await serveOff(httpsPort).catch(() => {
  });
  try {
    const { stdout } = await run$5(binary, [
      "serve",
      "--bg",
      `--https=${httpsPort}`,
      `http://127.0.0.1:${localPort}`
    ]);
    const url = /https:\/\/\S+/.exec(stdout)?.[0] ?? null;
    if (!url) {
      return {
        ok: false,
        message: "Tailscale accepted the proxy but did not report a URL for it.",
        detail: stdout.trim().slice(0, 400)
      };
    }
    return { ok: true, url: url.replace(/\/+$/, "/") };
  } catch (error) {
    const said = error instanceof Error ? error.message : String(error);
    return { ok: false, message: describe$1(said), detail: said.slice(0, 400) };
  }
}
async function serveOff(httpsPort) {
  const binary = await findTailscale();
  if (!binary) return;
  await run$5(binary, ["serve", `--https=${httpsPort}`, "off"]).catch(() => {
  });
}
function describe$1(said) {
  const lower = said.toLowerCase();
  if (lower.includes("funnel") && lower.includes("not")) {
    return "Tailscale refused to serve this port. Check that HTTPS Certificates are enabled for this tailnet.";
  }
  if (lower.includes("tls") || lower.includes("cert")) {
    return "Tailscale cannot get a certificate for this Mac. Open https://login.tailscale.com/admin/dns and turn on HTTPS Certificates, then try again.";
  }
  if (lower.includes("failed to connect") || lower.includes("is tailscale running")) {
    return "Tailscale is not running on this Mac. Start it, then try again.";
  }
  if (lower.includes("permission") || lower.includes("access denied")) {
    return "Tailscale refused the request. Serving may be disabled for this tailnet in the admin console.";
  }
  return `Tailscale could not put a proxy in front of this app: ${said.split("\n")[0]}`;
}
const WS_PATH = "/ws";
const DEFAULT_PORT = 8443;
const HELLO_TIMEOUT_MS = 8e3;
const PING_INTERVAL_MS = 3e4;
const MAX_BUFFERED_BYTES = 8 * 1024 * 1024;
const CLOSE_LINGER_MS = 1e3;
const MAX_CONNECTIONS = 64;
const MAX_REPLAY_CHUNKS = 64;
const MAX_REPLAY_CHARS = 4 * 1024 * 1024;
const MAX_DROPPED_TRACKED = 256;
class WireSocket {
  constructor(socket, maxMessageBytes, handlers) {
    this.socket = socket;
    this.maxMessageBytes = maxMessageBytes;
    this.handlers = handlers;
    this.reader = new FrameReader(maxMessageBytes);
    if ("setNoDelay" in socket && typeof socket.setNoDelay === "function") socket.setNoDelay(true);
    socket.on("data", (chunk) => this.receive(chunk));
    socket.on("error", () => this.finish());
    socket.on("close", () => this.finish());
    socket.on("end", () => this.finish());
  }
  socket;
  maxMessageBytes;
  handlers;
  reader;
  fragments = [];
  fragmentBytes = 0;
  fragmented = false;
  finished = false;
  awaitingPong = false;
  heartbeat = null;
  startHeartbeat(intervalMs) {
    if (intervalMs <= 0) return;
    this.heartbeat = setInterval(() => {
      if (this.finished) return;
      if (this.awaitingPong) {
        this.close(CLOSE.goingAway, "no response to ping");
        return;
      }
      this.awaitingPong = true;
      this.write(OPCODE.ping, Buffer.alloc(0));
    }, intervalMs);
    this.heartbeat.unref?.();
  }
  send(text2) {
    if (this.finished) return;
    if (this.socket.writableLength > MAX_BUFFERED_BYTES) {
      this.close(CLOSE.tryAgainLater, "output backed up");
      return;
    }
    this.write(OPCODE.text, Buffer.from(text2, "utf8"));
  }
  close(code, reason = "") {
    if (this.finished) return;
    const body = Buffer.alloc(2 + Buffer.byteLength(reason, "utf8"));
    body.writeUInt16BE(code, 0);
    body.write(reason, 2, "utf8");
    try {
      this.socket.end(encodeFrame(OPCODE.close, body));
    } catch {
    }
    this.finish();
  }
  write(opcode, payload) {
    try {
      this.socket.write(encodeFrame(opcode, payload));
    } catch {
      this.finish();
    }
  }
  finish() {
    if (this.finished) return;
    this.finished = true;
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;
    this.reader.reset();
    this.fragments = [];
    if (!this.socket.destroyed) {
      this.socket.end();
      const linger = setTimeout(() => this.socket.destroy(), CLOSE_LINGER_MS);
      linger.unref?.();
    }
    this.handlers.closed();
  }
  fail(code, reason) {
    this.close(code, reason);
  }
  receive(chunk) {
    if (this.finished) return;
    const batch = this.reader.push(chunk);
    for (const { fin, opcode, payload } of batch.frames) {
      if (this.finished) return;
      this.frame(fin, opcode, payload);
    }
    if (batch.ok || this.finished) return;
    const { reason, detail } = batch.error;
    this.fail(reason === "too-large" ? CLOSE.messageTooBig : CLOSE.protocolError, detail);
  }
  frame(fin, opcode, payload) {
    if (opcode >= 8) {
      if (!fin || payload.length > 125) return this.fail(CLOSE.protocolError, "malformed control frame");
      if (opcode === OPCODE.close) return this.close(CLOSE.normal, "");
      if (opcode === OPCODE.ping) return this.write(OPCODE.pong, payload);
      if (opcode === OPCODE.pong) {
        this.awaitingPong = false;
        return;
      }
      return this.fail(CLOSE.protocolError, "unknown control frame");
    }
    if (opcode === OPCODE.binary) {
      return this.fail(CLOSE.unsupportedData, "binary frames are not accepted");
    }
    if (opcode === OPCODE.text) {
      if (this.fragmented) return this.fail(CLOSE.protocolError, "interleaved message");
      if (fin) return this.deliver(payload);
      this.fragmented = true;
      this.fragments = [payload];
      this.fragmentBytes = payload.length;
      return;
    }
    if (opcode === OPCODE.continuation) {
      if (!this.fragmented) return this.fail(CLOSE.protocolError, "continuation without a start");
      this.fragmentBytes += payload.length;
      if (this.fragmentBytes > this.maxMessageBytes) return this.fail(CLOSE.messageTooBig, "message too large");
      this.fragments.push(payload);
      if (!fin) return;
      const whole2 = Buffer.concat(this.fragments);
      this.fragments = [];
      this.fragmentBytes = 0;
      this.fragmented = false;
      return this.deliver(whole2);
    }
    return this.fail(CLOSE.protocolError, `unsupported opcode ${opcode}`);
  }
  deliver(payload) {
    try {
      this.handlers.message(payload.toString("utf8"));
    } catch (error) {
      console.error("[remote] message handler threw:", error);
      this.fail(CLOSE.internalError, "internal error");
    }
  }
}
const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8"
};
function resolveStaticPath(root, requestPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(requestPath);
  } catch {
    return null;
  }
  if (decoded.includes("\0")) return null;
  const rootPath = node_path.resolve(root);
  const trimmed = decoded === "/" || decoded === "" ? "/index.html" : decoded;
  const target2 = node_path.resolve(node_path.join(rootPath, node_path.normalize(trimmed)));
  if (target2 !== rootPath && !target2.startsWith(rootPath + node_path.sep)) return null;
  if (node_path.extname(target2) === "") return node_path.join(rootPath, "index.html");
  return target2;
}
function immutable(root, file) {
  return file.startsWith(node_path.join(node_path.resolve(root), "assets") + node_path.sep);
}
async function serveStatic(root, req, res) {
  const requestPath = (req.url ?? "/").split("?")[0];
  const file = resolveStaticPath(root, requestPath);
  if (!file) {
    res.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
    res.end("bad path");
    return;
  }
  let size;
  try {
    const info = await promises.stat(file);
    if (!info.isFile()) throw new Error("not a file");
    size = info.size;
  } catch {
    const missingShell = file === node_path.join(node_path.resolve(root), "index.html");
    res.writeHead(missingShell ? 503 : 404, { "content-type": "text/plain; charset=utf-8" });
    res.end(missingShell ? "The phone app has not been built into pwa/dist yet." : "not found");
    return;
  }
  res.writeHead(200, {
    "content-type": CONTENT_TYPES[node_path.extname(file).toLowerCase()] ?? "application/octet-stream",
    "content-length": String(size),
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    // This page is a live terminal. Nothing may frame it: a tap the user thinks
    // lands on someone else's page must not land on their shell.
    "content-security-policy": "frame-ancestors 'none'",
    "x-frame-options": "DENY",
    "cache-control": immutable(root, file) ? "public, max-age=31536000, immutable" : "no-cache"
  });
  if (req.method === "HEAD") {
    res.end();
    return;
  }
  const stream = node_fs.createReadStream(file);
  stream.on("error", () => res.destroy());
  stream.pipe(res);
}
function hostAllowed(host, hosts) {
  if (hosts.length === 0) return true;
  if (!host) return false;
  return hosts.includes(host.toLowerCase());
}
function originAllowed(origin, hosts) {
  if (hosts.length === 0) return true;
  if (origin === void 0 || origin === "") return true;
  if (origin === "null") return false;
  try {
    return hosts.includes(new URL(origin).host.toLowerCase());
  } catch {
    return false;
  }
}
function refuseUpgrade(socket, code, text2) {
  try {
    socket.end(`HTTP/1.1 ${code} ${text2}\r
Connection: close\r
Content-Length: 0\r
\r
`);
  } catch {
    socket.destroy();
  }
}
function createRemoteEndpoint(options) {
  const helloTimeoutMs = options.helloTimeoutMs ?? HELLO_TIMEOUT_MS;
  const pingIntervalMs = options.pingIntervalMs ?? PING_INTERVAL_MS;
  const maxMessageBytes = options.maxMessageBytes ?? MAX_MESSAGE_BYTES;
  const hosts = (options.hosts ?? []).map((host) => host.toLowerCase());
  const live = /* @__PURE__ */ new Map();
  const scanPorts = options.scanPorts ?? (() => scanDevPorts());
  const streams = streamBudget(MAX_STREAMS_TOTAL);
  const advertised = CAPABILITIES.filter((name) => {
    if (name === CAPABILITY.create) return typeof options.sessions.create === "function";
    if (name === CAPABILITY.upload) return typeof options.uploadsDir === "string" && options.uploadsDir !== "";
    return true;
  });
  let sweep = 0;
  const sweptAt = /* @__PURE__ */ new Map();
  function publicConnections() {
    const out = [];
    for (const connection of live.values()) {
      if (!connection.deviceId) continue;
      out.push({
        id: connection.id,
        deviceId: connection.deviceId,
        deviceName: connection.deviceName,
        platform: connection.platform,
        address: connection.address,
        connectedAt: connection.connectedAt,
        sessionIds: [...connection.handles.keys()],
        tunnels: connection.tunnels?.list() ?? []
      });
    }
    return out.sort((a, b) => a.connectedAt - b.connectedAt);
  }
  function announce() {
    try {
      options.onConnections?.(publicConnections());
    } catch (error) {
      console.error("[remote] connection listener threw:", error);
    }
  }
  function send2(connection, message) {
    connection.wire.send(serialize(message));
  }
  function refuse2(connection, code, message, closeCode) {
    send2(connection, { t: "error", code, message });
    connection.wire.close(closeCode, code);
  }
  function hubFor(connection) {
    if (connection.tunnels) return connection.tunnels;
    const hub = createTunnelHub({
      scan: scanPorts,
      send: (message) => send2(connection, message),
      reserved: options.reservedPorts,
      budget: streams,
      // The desktop's device list shows a phone's live tunnels next to its
      // sessions, so opening or closing one has to redraw it for the same
      // reason attaching does.
      onChange: announce
    });
    connection.tunnels = hub;
    return hub;
  }
  function deskFor(connection) {
    if (connection.uploads) return connection.uploads;
    const dir = options.uploadsDir;
    if (dir === void 0 || dir === "") return null;
    const desk = createUploadDesk({
      store: diskUploadStore(dir),
      send: (message) => send2(connection, message)
    });
    connection.uploads = desk;
    return desk;
  }
  function detachAll(connection) {
    connection.tunnels?.closeAll();
    connection.tunnels = null;
    connection.uploads?.closeAll();
    connection.uploads = null;
    for (const handle2 of connection.handles.values()) {
      try {
        options.sessions.detach(handle2);
      } catch (error) {
        console.error("[remote] detach failed:", error);
      }
    }
    connection.handles.clear();
  }
  function replayOf(replay) {
    let text2 = replay;
    if (text2.length > MAX_REPLAY_CHARS) {
      text2 = text2.slice(-MAX_REPLAY_CHARS);
      const first = text2.charCodeAt(0);
      if (first >= 56320 && first <= 57343) text2 = text2.slice(1);
    }
    const pieces = chunkOutput(text2);
    return pieces.length > MAX_REPLAY_CHUNKS ? pieces.slice(-MAX_REPLAY_CHUNKS) : pieces;
  }
  function attach2(connection, message) {
    const id2 = message.id;
    const existing = connection.handles.get(id2);
    if (existing) {
      options.sessions.detach(existing);
      connection.handles.delete(id2);
    }
    let flushed = false;
    const pending = [];
    const handle2 = options.sessions.attach(
      id2,
      (data) => {
        if (!flushed) {
          pending.push(data);
          return;
        }
        for (const piece of chunkOutput(data)) send2(connection, { t: "output", id: id2, data: piece });
      },
      (status) => send2(connection, { t: "status", id: id2, status }),
      (exitCode) => send2(connection, { t: "exit", id: id2, exitCode })
    );
    if (!handle2) {
      send2(connection, { t: "error", code: "unknown-session", message: `No session ${id2} is running.` });
      if (existing) announce();
      return;
    }
    connection.handles.set(id2, handle2);
    send2(connection, { t: "attached", id: id2 });
    for (const piece of replayOf(handle2.replay)) {
      send2(connection, { t: "output", id: id2, data: piece, replay: true });
    }
    flushed = true;
    for (const held of pending) {
      for (const piece of chunkOutput(held)) send2(connection, { t: "output", id: id2, data: piece });
    }
    if (message.cols !== void 0 && message.rows !== void 0) {
      options.sessions.resize(id2, message.cols, message.rows);
    }
    announce();
  }
  async function hello(connection, message) {
    if (message.protocol !== PROTOCOL_VERSION) {
      refuse2(
        connection,
        "version",
        `This phone app speaks protocol ${message.protocol}; the desktop speaks ${PROTOCOL_VERSION}. Update whichever is older.`,
        CLOSE.policyViolation
      );
      return;
    }
    const startedAt = sweep;
    const outcome = await options.auth.authenticate(
      message.token,
      message.device,
      connection.address,
      connection.peerPublicKey
    );
    if (!live.has(connection.id)) return;
    if (outcome.ok && (sweptAt.get(outcome.deviceId) ?? 0) > startedAt) {
      refuse2(
        connection,
        "unauthorized",
        "This device is not allowed in. Pair it again from the Mac.",
        CLOSE.policyViolation
      );
      return;
    }
    if (!outcome.ok) {
      if (outcome.credential) {
        send2(connection, {
          t: "welcome",
          protocol: PROTOCOL_VERSION,
          deviceId: outcome.deviceId ?? "",
          deviceName: outcome.deviceName ?? message.device.name,
          token: outcome.credential,
          sessions: [],
          // Nothing is advertised to a device that is not in yet. What this
          // desktop can do is not a secret, but this connection is about to be
          // closed and a capability list would only invite it to try one.
          capabilities: []
        });
      }
      refuse2(connection, "unauthorized", outcome.message, CLOSE.policyViolation);
      return;
    }
    connection.deviceId = outcome.deviceId;
    connection.deviceName = outcome.deviceName;
    connection.platform = message.device.platform;
    if (connection.helloTimer) clearTimeout(connection.helloTimer);
    connection.helloTimer = null;
    connection.wire.startHeartbeat?.(pingIntervalMs);
    send2(connection, {
      t: "welcome",
      protocol: PROTOCOL_VERSION,
      deviceId: outcome.deviceId,
      deviceName: outcome.deviceName,
      // Present exactly once, on the connection that paired.
      token: outcome.credential,
      sessions: options.sessions.list(),
      capabilities: advertised
    });
    announce();
  }
  async function create(connection, message) {
    const start = options.sessions.create;
    if (!start) {
      send2(connection, {
        t: "error",
        code: "unauthorized",
        message: "This Mac cannot start sessions from a phone."
      });
      return;
    }
    if (connection.creating) {
      send2(connection, {
        t: "error",
        code: "unavailable",
        message: "A session is already starting. Wait for it to appear."
      });
      return;
    }
    connection.creating = true;
    let outcome;
    try {
      outcome = await start({ cwd: message.cwd, cols: message.cols, rows: message.rows });
    } finally {
      connection.creating = false;
    }
    if (!live.has(connection.id)) return;
    if (!outcome.ok) {
      send2(connection, { t: "error", code: outcome.code, message: outcome.message });
      return;
    }
    send2(connection, { t: "created", session: outcome.session });
    const sessions2 = options.sessions.list();
    for (const other of live.values()) {
      if (other.id === connection.id || !other.deviceId) continue;
      send2(other, { t: "sessions", sessions: sessions2 });
    }
  }
  function onMessage(connection, raw) {
    const parsed = parseClientMessage(raw);
    if (!parsed.ok) {
      refuse2(connection, parsed.code, parsed.reason, CLOSE.protocolError);
      return;
    }
    const message = parsed.message;
    if (!connection.deviceId) {
      if (message.t !== "hello") {
        refuse2(connection, "unauthenticated", "Say hello first.", CLOSE.policyViolation);
        return;
      }
      if (connection.greeting) {
        refuse2(connection, "bad-message", "One hello at a time.", CLOSE.protocolError);
        return;
      }
      connection.greeting = true;
      void hello(connection, message).catch((error) => {
        console.error("[remote] hello failed:", error);
        refuse2(connection, "unauthorized", "Could not check this device.", CLOSE.internalError);
      }).finally(() => {
        connection.greeting = false;
      });
      return;
    }
    switch (message.t) {
      case "hello":
        refuse2(connection, "bad-message", "Already said hello.", CLOSE.protocolError);
        return;
      case "list":
        send2(connection, { t: "sessions", sessions: options.sessions.list() });
        return;
      case "attach":
        attach2(connection, message);
        return;
      case "detach": {
        const handle2 = connection.handles.get(message.id);
        if (handle2) {
          options.sessions.detach(handle2);
          connection.handles.delete(message.id);
          announce();
        }
        send2(connection, { t: "detached", id: message.id });
        return;
      }
      case "input":
        if (!connection.handles.has(message.id)) {
          send2(connection, {
            t: "error",
            code: "unauthorized",
            message: "Attach to that session before typing into it."
          });
          return;
        }
        options.sessions.write(message.id, message.data);
        return;
      case "resize":
        if (!connection.handles.has(message.id)) {
          send2(connection, {
            t: "error",
            code: "unauthorized",
            message: "Attach to that session before resizing it."
          });
          return;
        }
        options.sessions.resize(message.id, message.cols, message.rows);
        return;
      case "ping":
        send2(connection, { t: "pong" });
        return;
      case "create":
        void create(connection, message).catch((error) => {
          console.error("[remote] create failed:", error);
          if (!live.has(connection.id)) return;
          send2(connection, {
            t: "error",
            code: "unavailable",
            message: "This Mac could not start that session."
          });
        });
        return;
      case "ports":
      case "tunnel.open":
      case "tunnel.close":
      case "net.open":
      case "net.data":
      case "net.ack":
      case "net.close":
        hubFor(connection).handle(message);
        return;
      case "upload.begin":
      case "upload.data":
      case "upload.end":
      case "upload.cancel": {
        const desk = deskFor(connection);
        if (!desk) {
          send2(connection, {
            t: "upload.failed",
            id: message.id,
            message: "This Mac cannot receive files from a phone."
          });
          return;
        }
        desk.handle(message);
        return;
      }
    }
  }
  function attachTransport(address, connect, peerPublicKey) {
    if (live.size >= MAX_CONNECTIONS) return false;
    const connection = {
      id: node_crypto.randomUUID(),
      wire: void 0,
      address,
      connectedAt: Date.now(),
      deviceId: null,
      deviceName: "",
      platform: "",
      peerPublicKey: peerPublicKey ?? null,
      handles: /* @__PURE__ */ new Map(),
      tunnels: null,
      uploads: null,
      helloTimer: null,
      greeting: false,
      creating: false
    };
    connection.wire = connect({
      message: (text2) => onMessage(connection, text2),
      closed: () => {
        if (!live.delete(connection.id)) return;
        if (connection.helloTimer) clearTimeout(connection.helloTimer);
        connection.helloTimer = null;
        const wasAuthenticated = connection.deviceId !== null;
        detachAll(connection);
        if (wasAuthenticated) announce();
      }
    });
    connection.helloTimer = setTimeout(() => {
      if (connection.deviceId) return;
      connection.wire.close(CLOSE.policyViolation, "no hello");
    }, helloTimeoutMs);
    connection.helloTimer.unref?.();
    live.set(connection.id, connection);
    return true;
  }
  function handleUpgrade(req, socket, head) {
    const path = (req.url ?? "/").split("?")[0];
    if (path !== WS_PATH) return refuseUpgrade(socket, 404, "Not Found");
    if (!hostAllowed(req.headers.host, hosts)) return refuseUpgrade(socket, 403, "Forbidden");
    if (!originAllowed(req.headers.origin, hosts)) return refuseUpgrade(socket, 403, "Forbidden");
    if (live.size >= MAX_CONNECTIONS) return refuseUpgrade(socket, 503, "Service Unavailable");
    const upgrade = String(req.headers.upgrade ?? "").toLowerCase();
    const key = req.headers["sec-websocket-key"];
    const version2 = String(req.headers["sec-websocket-version"] ?? "");
    if (upgrade !== "websocket" || typeof key !== "string" || version2 !== "13") {
      return refuseUpgrade(socket, 400, "Bad Request");
    }
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r
Upgrade: websocket\r
Connection: Upgrade\r
Sec-WebSocket-Accept: ${acceptKey(key)}\r
\r
`
    );
    attachTransport(
      req.socket.remoteAddress ?? "unknown",
      (handlers) => new WireSocket(socket, maxMessageBytes, handlers)
    );
    if (head.length > 0) socket.unshift(head);
  }
  function handleRequest(req, res) {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { allow: "GET, HEAD" });
      res.end();
      return;
    }
    if (!hostAllowed(req.headers.host, hosts)) {
      res.writeHead(403, { "content-type": "text/plain; charset=utf-8" });
      res.end("forbidden");
      return;
    }
    void serveStatic(options.webRoot, req, res).catch(() => {
      if (!res.headersSent) res.writeHead(500);
      res.end();
    });
  }
  return {
    handleRequest,
    handleUpgrade,
    attachTransport,
    connections: publicConnections,
    dropDevice(deviceId) {
      sweep += 1;
      sweptAt.set(deviceId, sweep);
      while (sweptAt.size > MAX_DROPPED_TRACKED) {
        const oldest = [...sweptAt.entries()].sort((a, b) => a[1] - b[1])[0];
        if (!oldest) break;
        sweptAt.delete(oldest[0]);
      }
      let dropped = 0;
      for (const connection of [...live.values()]) {
        if (connection.deviceId !== deviceId) continue;
        connection.wire.close(CLOSE.policyViolation, "access revoked");
        dropped += 1;
      }
      return dropped;
    },
    dropConnection(connectionId) {
      const connection = live.get(connectionId);
      if (!connection) return false;
      connection.wire.close(CLOSE.goingAway, "disconnected from the desktop");
      return true;
    },
    stopTunnel(connectionId, tunnelId) {
      return live.get(connectionId)?.tunnels?.stop(tunnelId, "Stopped from the Mac.") ?? false;
    },
    closeAll() {
      for (const connection of [...live.values()]) connection.wire.close(CLOSE.goingAway, "server stopping");
    }
  };
}
function pairingDesk(auth, now = Date.now) {
  let live = null;
  const digestOf = (value) => node_crypto.createHash("sha256").update(value).digest();
  const expired = () => {
    if (!live) return true;
    if (now() < live.expiresAt) return false;
    live = null;
    return true;
  };
  return {
    create() {
      const minted = auth.createPairingToken();
      live = { digest: digestOf(minted.token), expiresAt: minted.expiresAt };
      return minted;
    },
    cancel() {
      live = null;
    },
    offers(token2) {
      if (expired() || !live) return false;
      return node_crypto.timingSafeEqual(digestOf(token2), live.digest);
    },
    open() {
      return !expired();
    }
  };
}
function authenticatorFor(auth, desk) {
  return {
    async authenticate(token2, device, address, peerPublicKey) {
      if (token2.includes(".")) {
        const verified = await auth.verifyCredential(token2, address);
        if (verified.ok) {
          if (peerPublicKey && !auth.deviceHoldsKey(verified.device.id, peerPublicKey)) {
            return { ok: false, message: "This device is not allowed in. Pair it again from the Mac." };
          }
          return { ok: true, deviceId: verified.device.id, deviceName: verified.device.name, credential: null };
        }
        return {
          ok: false,
          message: verified.reason === "pending" ? "This device is waiting to be approved. Approve it on the Mac, then reconnect." : verified.reason === "rate-limited" ? "Too many failed attempts. Try again later." : "This device is not allowed in. Pair it again from the Mac."
        };
      }
      if (!desk.offers(token2)) {
        return { ok: false, message: "That pairing code is not right." };
      }
      const redeemed = await auth.redeemPairingToken(
        token2,
        device.name,
        address,
        peerPublicKey ?? void 0
      );
      if (!redeemed.ok) {
        return {
          ok: false,
          message: redeemed.reason === "expired" || redeemed.reason === "used" ? "That pairing code has already been used or has expired. Create a new one on the Mac." : redeemed.reason === "rate-limited" ? "Too many failed attempts. Try again later." : "That pairing code is not right."
        };
      }
      desk.cancel();
      return {
        ok: false,
        message: "Paired. Approve this device on the Mac, then reconnect.",
        credential: redeemed.credential,
        deviceId: redeemed.device.id,
        deviceName: redeemed.device.name
      };
    }
  };
}
function createRemoteServer(options) {
  const port = options.port ?? DEFAULT_PORT;
  const readTailnet = options.readTailnet ?? (() => tailnetStatus());
  const serve = options.serve ?? { on: serveOn, off: serveOff };
  const relay = options.relay ?? null;
  let servers = [];
  let endpoint2 = null;
  let current = null;
  let reason = null;
  let directReason = null;
  let relaying = false;
  let starting2 = null;
  function snapshot2() {
    const link = relaying ? relay?.state() ?? null : null;
    return {
      running: servers.length > 0 || relaying,
      url: current?.url ?? null,
      address: current?.address ?? null,
      port,
      // Read live rather than remembered. With no listener, the honest answer to
      // "why can my phone not see this Mac" is whatever the relay is saying at
      // the moment somebody asks — a sentence recorded at `start()` would still
      // be describing a DNS failure long after the wifi came back.
      reason: servers.length > 0 ? null : link ? link.reason : reason,
      directReason,
      relay: link,
      connections: endpoint2?.connections() ?? []
    };
  }
  function failure2(message) {
    reason = message;
    directReason = message;
    current = null;
    return snapshot2();
  }
  async function listenOn(server2, address) {
    await new Promise((settle, fail2) => {
      const onError = (error) => {
        server2.close();
        fail2(error);
      };
      server2.once("error", onError);
      server2.listen(port, address, () => {
        server2.removeListener("error", onError);
        server2.on("error", (error) => console.error("[remote] server error:", error));
        settle();
      });
    });
  }
  function directPlan(tailnet) {
    if (!tailnet.ready) return { ok: false, reason: tailnet.reason };
    if (!tailnet.magicDns || tailnet.dnsName === "") {
      return {
        ok: false,
        reason: "MagicDNS is off for this tailnet, so this Mac has no name a phone can trust a certificate for. Turn MagicDNS on in the Tailscale admin console, then try again."
      };
    }
    return {
      ok: true,
      hosts: [
        tailnet.dnsName,
        `${tailnet.dnsName}:${port}`,
        `${tailnet.address}:${port}`,
        ...tailnet.address6 ? [`[${tailnet.address6}]:${port}`] : []
      ],
      url: `https://${tailnet.dnsName}:${port}/`,
      address: tailnet.address
    };
  }
  async function open2() {
    const direct = directPlan(await readTailnet());
    if (!direct.ok && relay === null) return failure2(direct.reason);
    const hosts = options.hosts ?? (direct.ok ? direct.hosts : []);
    const live = createRemoteEndpoint({
      ...options,
      hosts,
      // This app's own listener is never a tunnel target. Only this function
      // knows which port that is, which is why the endpoint is told rather than
      // left to work it out.
      reservedPorts: [port, ...options.reservedPorts ?? []]
    });
    const opened = [];
    let blocked = direct.ok ? null : direct.reason;
    if (direct.ok) {
      try {
        const server2 = node_http.createServer(live.handleRequest);
        server2.on("upgrade", live.handleUpgrade);
        server2.on("clientError", (_error, socket) => socket.destroy());
        await listenOn(server2, "127.0.0.1");
        opened.push(server2);
        const proxied = await serve.on(port, port);
        if (!proxied.ok) {
          blocked = proxied.message ?? "Tailscale could not put a proxy in front of this app.";
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        blocked = /EADDRINUSE/.test(message) ? `Port ${port} on the tailnet address is already in use by something else on this Mac.` : `Could not listen on the tailnet address: ${message}`;
      }
      if (blocked !== null) {
        for (const server2 of opened) server2.close();
        opened.length = 0;
      }
    }
    if (opened.length === 0 && relay === null) return failure2(blocked ?? "Remote access could not start.");
    if (relay !== null) {
      relay.start(live.attachTransport);
      relaying = true;
    }
    servers = opened;
    endpoint2 = live;
    directReason = blocked;
    reason = opened.length === 0 && !relaying ? blocked : null;
    current = opened.length > 0 && direct.ok ? { url: direct.url, address: direct.address } : null;
    return snapshot2();
  }
  return {
    async start() {
      if (servers.length > 0 || relaying) return snapshot2();
      if (starting2) return starting2;
      starting2 = open2().finally(() => {
        starting2 = null;
      });
      return starting2;
    },
    async stop() {
      if (starting2) {
        try {
          await starting2;
        } catch {
        }
      }
      endpoint2?.closeAll();
      if (relaying) relay?.stop();
      relaying = false;
      const closing = servers;
      servers = [];
      current = null;
      directReason = null;
      await serve.off(port).catch(() => {
      });
      await Promise.all(
        closing.map(
          (server2) => new Promise((settle) => {
            server2.close(() => settle());
            server2.closeAllConnections?.();
          })
        )
      );
      endpoint2 = null;
      return snapshot2();
    },
    url: () => current?.url ?? null,
    connections: () => endpoint2?.connections() ?? [],
    dropDevice: (deviceId) => endpoint2?.dropDevice(deviceId) ?? 0,
    dropConnection: (connectionId) => endpoint2?.dropConnection(connectionId) ?? false,
    stopTunnel: (connectionId, tunnelId) => endpoint2?.stopTunnel(connectionId, tunnelId) ?? false,
    status: snapshot2,
    // No relay configured (`TERMINALDECK_RELAY=off`) means nothing to re-dial.
    wake: () => relay?.wake()
  };
}
const REMOTE_CONNECTIONS_CHANNEL = "remote:connections";
function relayFor(storageDir, url, auth, desk) {
  let link = null;
  let broken = null;
  return {
    start(attachTransport) {
      if (link === null && broken === null) {
        try {
          link = createRelayClient({
            url,
            identity: loadHostIdentity(storageDir),
            // Two ways in, and both are narrow. A device this Mac already knows,
            // by a key it stored when that device paired — or any device at all,
            // but only while a pairing code is on screen, because a phone
            // pairing for the first time has no key here to be known by. Neither
            // grants access: the hello that follows still needs a credential,
            // and a human still has to approve.
            isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open()
          });
        } catch (error) {
          console.error("[relay] could not keep this Mac’s relay identity:", error);
          broken = "This Mac could not save the key it needs to be reachable through the relay. Check that its application-support folder is writable, then turn remote access off and on again.";
        }
      }
      link?.start(attachTransport);
    },
    stop: () => link?.stop(),
    // Harmless before the link exists: a Mac that has never started the relay
    // has nothing to reconnect on waking.
    wake: () => link?.wake(),
    state: () => link?.state() ?? {
      url,
      hostId: "",
      publicKey: "",
      fingerprint: "",
      connected: false,
      channels: 0,
      reason: broken ?? "The relay has not been started yet.",
      retryAt: null
    }
  };
}
function registerRemoteIpc(ipcMain, deps) {
  const auth = new RemoteAuth(deps.storageDir);
  const desk = pairingDesk(auth);
  const env = deps.env ?? process.env;
  const relay = relayEnabled(env, deps.relayEnabled) ? relayFor(deps.storageDir, relayUrl(env, deps.relayUrl), auth, desk) : null;
  const server2 = createRemoteServer({
    sessions: deps.sessions,
    auth: authenticatorFor(auth, desk),
    webRoot: deps.webRoot,
    certDir: deps.storageDir,
    ...deps.uploadsDir ? { uploadsDir: deps.uploadsDir } : {},
    port: deps.port,
    onConnections: (connections) => deps.broadcast(REMOTE_CONNECTIONS_CHANNEL, connections),
    ...relay ? { relay } : {}
  });
  ipcMain.handle("remote:status", () => server2.status());
  ipcMain.handle("remote:start", () => server2.start());
  ipcMain.handle("remote:stop", () => server2.stop());
  ipcMain.handle("remote:pair", () => desk.create());
  ipcMain.handle("remote:pair:cancel", () => {
    desk.cancel();
    return { cancelled: true };
  });
  ipcMain.handle("remote:connection:disconnect", (_event, id2) => {
    if (typeof id2 === "string") server2.dropConnection(id2);
    return server2.connections();
  });
  ipcMain.handle(
    "remote:tunnel:stop",
    (_event, connectionId, tunnelId) => {
      if (typeof connectionId === "string" && typeof tunnelId === "string") {
        server2.stopTunnel(connectionId, tunnelId);
      }
      return server2.connections();
    }
  );
  ipcMain.handle("remote:devices", () => auth.listDevices());
  ipcMain.handle("remote:device:approve", (_event, id2) => {
    if (typeof id2 === "string") auth.approveDevice(id2);
    return auth.listDevices();
  });
  ipcMain.handle("remote:device:revoke", (_event, id2) => {
    if (typeof id2 === "string" && auth.revokeDevice(id2)) {
      server2.dropDevice(id2);
    }
    return auth.listDevices();
  });
  return { server: server2, auth };
}
class SessionFanout {
  constructor(ptys2) {
    this.ptys = ptys2;
    const start = ptys2.create;
    if (start) this.create = (request) => start(request);
  }
  ptys;
  listeners = /* @__PURE__ */ new Map();
  /** Last status seen per session, so a late attach knows the state. */
  status = /* @__PURE__ */ new Map();
  /**
   * Present only when the source can start a session, and that is deliberate.
   *
   * `server.ts` decides whether to advertise the `create` capability by asking
   * whether this method exists. A class method always exists, so declaring it
   * on the prototype and having it refuse would advertise a button on every
   * host — including the ones with no terminals at all. Assigned here instead,
   * so the answer to "can this desktop start a session" is one fact rather than
   * two that have to be kept in step.
   */
  create;
  /* ----------------------------------------------------- from PtyManager -- */
  /** Call from the PtyManager data callback, alongside the window broadcast. */
  noteData(id2, data) {
    for (const l of this.listeners.get(id2) ?? []) l.onData(data);
  }
  noteStatus(id2, status) {
    this.status.set(id2, status);
    for (const l of this.listeners.get(id2) ?? []) l.onStatus(status);
  }
  noteExit(id2, exitCode) {
    for (const l of this.listeners.get(id2) ?? []) l.onExit(exitCode);
    this.listeners.delete(id2);
    this.status.delete(id2);
  }
  /* ---------------------------------------------------- SessionAccess -- */
  list() {
    return this.ptys.list().map((s) => ({
      id: s.id,
      title: s.title,
      cwd: s.cwd,
      provider: s.provider ?? "shell",
      status: this.status.get(s.id) ?? "idle",
      exitCode: s.exitCode
    }));
  }
  attach(id2, onData, onStatus, onExit) {
    if (!this.ptys.list().some((s) => s.id === id2)) return null;
    const replay = this.ptys.scrollback(id2);
    const handle2 = { sessionId: id2, replay };
    const set = this.listeners.get(id2) ?? /* @__PURE__ */ new Set();
    set.add({ handle: handle2, onData, onStatus, onExit });
    this.listeners.set(id2, set);
    return handle2;
  }
  detach(handle2) {
    const set = this.listeners.get(handle2.sessionId);
    if (!set) return;
    for (const l of set) {
      if (l.handle === handle2) set.delete(l);
    }
    if (set.size === 0) this.listeners.delete(handle2.sessionId);
  }
  write(id2, data) {
    this.ptys.write(id2, data);
  }
  resize(id2, cols, rows) {
    this.ptys.resize(id2, cols, rows);
  }
  /** For the desktop UI: how many remote watchers a session has. */
  watcherCount(id2) {
    return this.listeners.get(id2)?.size ?? 0;
  }
}
const DEFAULT_COLS$1 = 80;
const DEFAULT_ROWS$1 = 24;
function samePath(a, b) {
  return trimEnd(node_path.normalize(a)) === trimEnd(node_path.normalize(b));
}
function trimEnd(path) {
  let end = path.length;
  while (end > 1 && (path[end - 1] === node_path.sep || path[end - 1] === "/")) end -= 1;
  return path.slice(0, end);
}
function remoteSessionCreator(starter) {
  return async (request) => {
    const offered = starter.folders();
    let cwd;
    if (request.cwd === void 0) {
      cwd = offered[0] ?? starter.home();
    } else {
      if (!node_path.isAbsolute(request.cwd) || !offered.some((folder) => samePath(folder, request.cwd))) {
        return {
          ok: false,
          code: "unauthorized",
          // The folder is not echoed back. It came from the network and this
          // sentence is both sent over the wire and shown on a phone; quoting
          // attacker-chosen text into it buys nothing and costs an output
          // channel.
          message: "This Mac will not start a session in that folder. Open it on the Mac first."
        };
      }
      cwd = request.cwd;
    }
    try {
      const meta = await starter.spawn({
        cwd,
        cols: request.cols ?? DEFAULT_COLS$1,
        rows: request.rows ?? DEFAULT_ROWS$1
      });
      return {
        ok: true,
        session: {
          id: meta.id,
          title: meta.title,
          cwd: meta.cwd,
          provider: meta.provider,
          // Nothing has been printed yet, so there is nothing to read a status
          // off. `session-activity.ts` will say otherwise within a frame or two
          // and the phone is already listening for it.
          status: "idle",
          exitCode: meta.exitCode
        }
      };
    } catch (error) {
      console.error("[remote] could not start a session:", error);
      return {
        ok: false,
        code: "unavailable",
        message: "This Mac could not start a session there. The folder may have moved."
      };
    }
  };
}
function emptySnapshot(sessionId, reason) {
  return {
    sessionId,
    available: false,
    limits: [],
    source: null,
    message: null,
    capturedAt: 0,
    reason
  };
}
const PANEL_HEADING = /^Current\s+(session|week)\b(?:\s*\(([^)]*)\))?\s*$/i;
const PERCENT_USED = /(\d{1,3})%\s+used\b/i;
const RESETS_LINE = /^Resets\b\s*(.*)$/i;
const WARN_USED = /you['’]ve used\s+(\d{1,3})%\s+of your\s+(.+)$/i;
const WARN_RESETS = /^\W*your\s+(.+?)\s+resets\s+(.+)$/i;
const WARN_NAMED = /(?:approaching|you['’]re close to your|you['’]ve hit your)\s+(.+)$/i;
const LOOKAHEAD_LINES = 4;
function identifyLimit(label2) {
  const text2 = label2.toLowerCase();
  const isWeek = /week/.test(text2);
  const isSession = /session|5[- ]hour|five[- ]hour/.test(text2);
  const model = /\b(opus|sonnet|haiku|fable|mythos)\b/.exec(text2)?.[1];
  if (model && (isWeek || /limit/.test(text2))) return { id: `week:${model}`, scope: "week" };
  if (isWeek) return { id: "week", scope: "week" };
  if (isSession) return { id: "session", scope: "session" };
  if (/credit/.test(text2)) return { id: "other:usage-credit", scope: "other" };
  return { id: `other:${slug(text2)}`, scope: "other" };
}
const LIMIT_SCOPE_WORD = /\b(session|weekly|week|5-hour|five-hour|opus|sonnet|haiku|fable|mythos|credits?)\b/i;
function isLimitLabel(label2) {
  return /\blimits?\b/i.test(label2) && LIMIT_SCOPE_WORD.test(label2);
}
function slug(text2) {
  return text2.replace(/[^a-z0-9]+/gi, "-").replace(/^-+|-+$/g, "").toLowerCase() || "limit";
}
function percentOf(raw) {
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 && value <= 999 ? value : null;
}
function tidy(text2) {
  return text2.replace(/[·•,;:\s]+$/g, "").trim();
}
function parsePlanLimits(screen) {
  const lines2 = stripAnsi(screen).split("\n").map((line) => line.trimEnd());
  const panel = parseUsagePanel(lines2);
  if (panel.length > 0) return { limits: panel, source: "usage-panel", message: null };
  const warning = parseWarning(lines2);
  return warning;
}
function parseUsagePanel(lines2) {
  const limits = [];
  const seen = /* @__PURE__ */ new Set();
  for (let i = 0; i < lines2.length; i += 1) {
    const heading = PANEL_HEADING.exec(lines2[i].trim());
    if (!heading) continue;
    const qualifier = heading[2]?.trim() ?? "";
    const label2 = qualifier ? `Current ${heading[1]} (${qualifier})` : `Current ${heading[1]}`;
    const key = qualifier && !/^all models$/i.test(qualifier) ? identifyLimit(`${heading[1]} ${qualifier}`) : identifyLimit(heading[1]);
    let percent = null;
    let resetsAt = null;
    let cursor = i + 1;
    for (; cursor <= i + LOOKAHEAD_LINES && cursor < lines2.length; cursor += 1) {
      const found = PERCENT_USED.exec(lines2[cursor]);
      if (found) {
        percent = percentOf(found[1]);
        break;
      }
      if (PANEL_HEADING.test(lines2[cursor].trim())) break;
    }
    if (percent === null) continue;
    for (let j = cursor + 1; j <= cursor + LOOKAHEAD_LINES && j < lines2.length; j += 1) {
      const reset = RESETS_LINE.exec(lines2[j].trim());
      if (reset) {
        resetsAt = tidy(reset[1]) || null;
        break;
      }
      if (PANEL_HEADING.test(lines2[j].trim())) break;
    }
    if (seen.has(key.id)) continue;
    seen.add(key.id);
    limits.push({ id: key.id, label: label2, scope: key.scope, percent, resetsAt });
  }
  return limits;
}
function parseWarning(lines2) {
  for (let i = lines2.length - 1; i >= 0; i -= 1) {
    const line = lines2[i].trim();
    if (line.length === 0) continue;
    const used = WARN_USED.exec(line);
    if (used) {
      const rest = used[2];
      const cut = /\bresets\b/i.exec(rest);
      const label2 = tidy(cut ? rest.slice(0, cut.index) : rest);
      const resetsAt = cut ? tidy(rest.slice(cut.index + cut[0].length)) || null : null;
      if (isLimitLabel(label2)) {
        return {
          limits: [{ ...identifyLimit(label2), label: label2, percent: percentOf(used[1]), resetsAt }],
          source: "warning",
          message: line
        };
      }
    }
    const resets = WARN_RESETS.exec(line);
    if (resets && isLimitLabel(resets[1])) {
      const label2 = tidy(resets[1]);
      return {
        limits: [{ ...identifyLimit(label2), label: label2, percent: null, resetsAt: tidy(resets[2]) || null }],
        source: "warning",
        message: line
      };
    }
    const named = WARN_NAMED.exec(line);
    if (named && isLimitLabel(named[1])) {
      const label2 = tidy(named[1]);
      return {
        limits: [{ ...identifyLimit(label2), label: label2, percent: null, resetsAt: null }],
        source: "warning",
        message: line
      };
    }
  }
  return null;
}
const SETTLE_MS = 600;
const DEFAULT_COLS = 120;
const DEFAULT_ROWS = 40;
const EMPTY_PROMPT = /^\s*❯\s*$/m;
class PlanLimitTracker {
  constructor(sessionId, onChange, cols = DEFAULT_COLS, rows = DEFAULT_ROWS) {
    this.sessionId = sessionId;
    this.onChange = onChange;
    this.term = new headless.Terminal({ cols, rows, allowProposedApi: true, scrollback: 100 });
    this.snapshot = emptySnapshot(sessionId, NOT_SEEN);
  }
  sessionId;
  onChange;
  term;
  timer;
  lastOutputAt = 0;
  snapshot;
  get current() {
    return this.snapshot;
  }
  push(chunk) {
    this.term.write(chunk);
    this.lastOutputAt = Date.now();
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.term.write("", () => this.capture());
    }, SETTLE_MS);
  }
  resize(cols, rows) {
    try {
      this.term.resize(Math.max(cols, 1), Math.max(rows, 1));
    } catch {
    }
  }
  /** The visible viewport, as the user sees it. */
  screen() {
    const buffer = this.term.buffer.active;
    const lines2 = [];
    for (let y = 0; y < this.term.rows; y += 1) {
      const line = buffer.getLine(buffer.viewportY + y);
      if (line) lines2.push(line.translateToString(true));
    }
    return lines2.join("\n");
  }
  /**
   * Read the screen. Returns true when the stored snapshot changed.
   *
   * A screen with no limits on it leaves the last reading alone: the `/usage`
   * panel is closed most of the time, and treating its absence as "the limits
   * are unknown again" would make the strip flicker between a number and a
   * shrug every time the user pressed a key.
   */
  capture(at = Date.now()) {
    const parsed = parsePlanLimits(this.screen());
    if (!parsed) return false;
    const same = this.snapshot.available && this.snapshot.source === parsed.source && this.snapshot.message === parsed.message && JSON.stringify(this.snapshot.limits) === JSON.stringify(parsed.limits);
    this.snapshot = {
      sessionId: this.sessionId,
      available: true,
      limits: parsed.limits,
      source: parsed.source,
      message: parsed.message,
      capturedAt: at,
      reason: null
    };
    if (!same) this.onChange(this.snapshot);
    return !same;
  }
  /** True when nothing has been drawn for `ms` — the session is not mid-answer. */
  settled(ms, now = Date.now()) {
    return this.lastOutputAt === 0 || now - this.lastOutputAt >= ms;
  }
  /**
   * True when the prompt box is empty.
   *
   * The gate for typing anything into someone's session: with half-typed text
   * in the box, `/usage` would be appended to it and submitted as a prompt.
   */
  promptIsEmpty() {
    return EMPTY_PROMPT.test(stripAnsi(this.screen()));
  }
  dispose() {
    clearTimeout(this.timer);
    this.term.dispose();
  }
}
const NOT_SEEN = "Claude Code has not printed a plan-limit line in this session yet — it only does so near a limit, or when /usage is run.";
const NOT_WATCHED = "No live session is being watched for plan limits.";
const EVICTED = "Plan limits are tracked for the most recently watched sessions only, and this one was released to make room. Reopen it to read them again.";
const PLAN_LIMIT_CHANNEL = "plan:update";
const MAX_TRACKERS = 8;
const entries = /* @__PURE__ */ new Map();
function broadcast$1(entry, snapshot2) {
  for (const contents of entry.subscribers) {
    if (contents.isDestroyed()) {
      entry.subscribers.delete(contents);
      continue;
    }
    try {
      contents.send(PLAN_LIMIT_CHANNEL, snapshot2.sessionId, snapshot2);
    } catch (err) {
      entry.subscribers.delete(contents);
      console.error("[plan-limit] dropping a dead subscriber:", err);
    }
  }
}
function evict(sessionId) {
  const entry = entries.get(sessionId);
  if (!entry) return;
  broadcast$1(entry, emptySnapshot(sessionId, EVICTED));
  dropPlanSession(sessionId);
}
function ensureEntry(sessionId) {
  const existing = entries.get(sessionId);
  if (existing) return existing;
  if (entries.size >= MAX_TRACKERS) {
    const oldest = entries.keys().next().value;
    if (typeof oldest === "string") evict(oldest);
  }
  const entry = {
    tracker: new PlanLimitTracker(sessionId, (snapshot2) => broadcast$1(entry, snapshot2)),
    subscribers: /* @__PURE__ */ new Set(),
    refreshing: false
  };
  entries.set(sessionId, entry);
  return entry;
}
function notePlanOutput(sessionId, chunk) {
  entries.get(sessionId)?.tracker.push(chunk);
}
function notePlanResize(sessionId, cols, rows) {
  entries.get(sessionId)?.tracker.resize(cols, rows);
}
function dropPlanSession(sessionId) {
  const entry = entries.get(sessionId);
  if (!entry) return;
  entry.tracker.dispose();
  entries.delete(sessionId);
}
function releaseAll(contents) {
  for (const [sessionId, entry] of [...entries]) {
    entry.subscribers.delete(contents);
    if (entry.subscribers.size === 0) dropPlanSession(sessionId);
  }
}
function sessionKey(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error("plan-limit: a session id is required");
  }
  return value;
}
const USAGE_COMMAND = "/usage\r";
const CLOSE_PANEL = "\x1B";
const REFRESH_TIMEOUT_MS = 8e3;
const POLL_MS = 250;
const IDLE_BEFORE_TYPING_MS = 1e3;
function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
async function refresh(sessionId, options) {
  const entry = entries.get(sessionId);
  if (!entry) return { ok: false, reason: "not-watching", snapshot: emptySnapshot(sessionId, NOT_WATCHED) };
  if (!options.write) return { ok: false, reason: "unwired", snapshot: entry.tracker.current };
  if (entry.refreshing || !entry.tracker.settled(IDLE_BEFORE_TYPING_MS)) {
    return { ok: false, reason: "busy", snapshot: entry.tracker.current };
  }
  if (!entry.tracker.promptIsEmpty()) {
    return { ok: false, reason: "prompt-busy", snapshot: entry.tracker.current };
  }
  entry.refreshing = true;
  const startedAt = Date.now();
  try {
    options.write(sessionId, USAGE_COMMAND);
    const deadline = startedAt + REFRESH_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await delay(POLL_MS);
      entry.tracker.capture();
      const snapshot2 = entry.tracker.current;
      if (snapshot2.source === "usage-panel" && snapshot2.capturedAt >= startedAt) {
        options.write(sessionId, CLOSE_PANEL);
        return { ok: true, reason: null, snapshot: snapshot2 };
      }
    }
    options.write(sessionId, CLOSE_PANEL);
    return { ok: false, reason: "no-panel", snapshot: entry.tracker.current };
  } finally {
    entry.refreshing = false;
  }
}
function registerPlanLimitIpc(ipcMain, options = {}) {
  ipcMain.handle("plan:watch", (event, sessionId) => {
    const entry = ensureEntry(sessionKey(sessionId));
    const contents = event.sender;
    if (!entry.subscribers.has(contents)) {
      entry.subscribers.add(contents);
      contents.once("destroyed", () => releaseAll(contents));
    }
    return entry.tracker.current;
  });
  ipcMain.handle(
    "plan:refresh",
    (_e, sessionId) => refresh(sessionKey(sessionId), options)
  );
  ipcMain.on("plan:unwatch", (event, sessionId) => {
    if (typeof sessionId !== "string" || sessionId.length === 0) return;
    const entry = entries.get(sessionId);
    if (!entry) return;
    entry.subscribers.delete(event.sender);
    if (entry.subscribers.size === 0) dropPlanSession(sessionId);
  });
}
const run$4 = node_util.promisify(node_child_process.execFile);
const MAX_DETAIL = 4e3;
function truncateDetail(text2) {
  if (text2.length <= MAX_DETAIL) return text2;
  return `${text2.slice(0, MAX_DETAIL)}
… ${text2.length - MAX_DETAIL} more characters`;
}
function fail$1(kind, message, action, detail = "") {
  return { ok: false, kind, message, action, detail: truncateDetail(redact$1(detail)) };
}
function redact$1(text2) {
  if (!text2.includes("://")) return text2;
  return text2.replace(/([a-z][a-z0-9+.-]{0,31}:\/\/)[^/\s@]{1,512}@/gi, "$1***@");
}
const NETWORK_PATTERNS = [
  /dial tcp/i,
  /connection refused/i,
  /no such host/i,
  /network is unreachable/i,
  /host is down/i,
  /i\/o timeout/i,
  /tls handshake timeout/i,
  /proxyconnect/i,
  /connection reset by peer/i,
  /EAI_AGAIN/,
  /ENOTFOUND/,
  /certificate.*(expired|not valid|unknown authority)/i
];
function classifyGhError(error) {
  const failure2 = error;
  const text2 = `${failure2?.stderr ?? ""}
${failure2?.stdout ?? ""}
${failure2?.message ?? ""}`.trim();
  if (failure2?.code === "ENOENT") {
    return fail$1(
      "gh-missing",
      "The GitHub CLI is not installed, or is not on your login PATH.",
      "brew install gh",
      text2
    );
  }
  if (failure2?.killed || failure2?.signal === "SIGTERM" || failure2?.code === "ETIMEDOUT") {
    return fail$1("timeout", "GitHub did not answer in time.", null, text2);
  }
  for (const pattern of NETWORK_PATTERNS) {
    if (pattern.test(text2)) {
      return fail$1("network-down", "Could not reach github.com — check your connection.", null, text2);
    }
  }
  if (/not a git repository/i.test(text2)) {
    return fail$1("not-a-repo", "This folder is not a git repository.", "git init", text2);
  }
  if (/no git remotes found/i.test(text2)) {
    return fail$1("no-remote", "This repository has no remotes.", "git remote add origin <url>", text2);
  }
  if (/point to a known GitHub host/i.test(text2)) {
    return fail$1(
      "no-github-remote",
      "None of this repository’s remotes point at GitHub.",
      null,
      text2
    );
  }
  if (/To get started with GitHub CLI|not logged into any GitHub hosts/i.test(text2)) {
    return fail$1("not-authenticated", "You are not signed in to GitHub.", "gh auth login", text2);
  }
  if (/HTTP 401|Bad credentials/i.test(text2)) {
    return fail$1(
      "auth-expired",
      "Your GitHub credentials were rejected — the token has expired or been revoked.",
      "gh auth login",
      text2
    );
  }
  if (/rate limit|HTTP 429|submitted too quickly/i.test(text2)) {
    return fail$1(
      "rate-limited",
      "GitHub’s API rate limit is exhausted. It resets within the hour.",
      "gh api rate_limit",
      text2
    );
  }
  const scope = /missing required scopes?\s*\[([^\]]+)\]|at least ([a-z:_]+) scope/i.exec(text2);
  if (scope) {
    const needed = (scope[1] ?? scope[2] ?? "").trim();
    return fail$1(
      "missing-scope",
      `Your GitHub token is missing the ${needed || "required"} scope.`,
      needed ? `gh auth refresh -h github.com -s ${needed.split(/[,\s]+/)[0]}` : "gh auth refresh",
      text2
    );
  }
  if (/Could not resolve to a Repository|HTTP 404|Not Found/i.test(text2)) {
    return fail$1(
      "repo-not-found",
      "GitHub has no such repository — it may be private, renamed, or deleted.",
      null,
      text2
    );
  }
  if (/HTTP 403|Resource not accessible|must have (push|admin) access/i.test(text2)) {
    return fail$1(
      "no-access",
      "Your GitHub account cannot read this repository.",
      "gh auth status",
      text2
    );
  }
  return fail$1("error", "The GitHub CLI failed.", null, text2 || "gh failed");
}
function parseRemoteConfig(output) {
  const byName = /* @__PURE__ */ new Map();
  for (const line of output.split("\n")) {
    const match = /^remote\.(.+?)\.(url|gh-resolved)\s+(.*)$/.exec(line.trim());
    if (!match) continue;
    const [, name, key, value] = match;
    const entry = byName.get(name) ?? { name, url: "", resolved: null };
    if (key === "url") {
      if (!entry.url) entry.url = value.trim();
    } else {
      entry.resolved = value.trim();
    }
    byName.set(name, entry);
  }
  return [...byName.values()].filter((entry) => entry.url !== "");
}
function parseRemoteUrl(url) {
  const trimmed = url.trim();
  if (!trimmed) return null;
  let host;
  let path;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    const afterScheme = trimmed.slice(trimmed.indexOf("://") + 3);
    const slash = afterScheme.indexOf("/");
    const authority = slash === -1 ? afterScheme : afterScheme.slice(0, slash);
    const at = authority.lastIndexOf("@");
    host = at === -1 ? authority : authority.slice(at + 1);
    path = slash === -1 ? "" : afterScheme.slice(slash);
  } else {
    const match = /^(?:([^@/]+)@)?([^:/]+):(.+)$/.exec(trimmed);
    if (!match) return null;
    host = match[2];
    path = match[3];
  }
  host = host.replace(/:\d+$/, "").toLowerCase();
  if (!isHostName(host)) return null;
  const segments = path.split("/").filter((segment) => segment !== "");
  if (segments.length !== 2) return null;
  const owner = segments[0];
  const name = segments[1].replace(/\.git$/i, "");
  if (!isRepoSegment(owner) || !isRepoSegment(name)) return null;
  if (owner.startsWith("-")) return null;
  return { host, owner, name };
}
const REPO_SEGMENT = /^[A-Za-z0-9._-]+$/;
function isRepoSegment(segment) {
  if (!segment || segment === "." || segment === "..") return false;
  return REPO_SEGMENT.test(segment);
}
const HOST_NAME = /^[a-z0-9][a-z0-9.-]*$/i;
function isHostName(host) {
  return HOST_NAME.test(host);
}
function gitHubHosts() {
  const extra = (process.env.GH_HOST ?? "").trim().toLowerCase();
  return extra ? ["github.com", extra] : ["github.com"];
}
function isGitHubHost(host, hosts = gitHubHosts()) {
  const lower = host.toLowerCase();
  return hosts.some((known) => lower === known || lower.endsWith(`.${known}`));
}
const REMOTE_RANK = ["upstream", "github", "origin"];
function rank(name) {
  const index = REMOTE_RANK.indexOf(name);
  return index === -1 ? REMOTE_RANK.length : index;
}
function parseResolved(value) {
  const parts = value.split("/").filter((part) => part !== "");
  const [host, owner, name] = parts.length === 3 ? parts : parts.length === 2 ? [null, parts[0], parts[1]] : [];
  if (!owner || !name) return null;
  if (!isRepoSegment(owner) || !isRepoSegment(name)) return null;
  if (host !== null && !isHostName(host)) return null;
  return { host: host ? host.toLowerCase() : null, owner, name };
}
function pickRepo(entries2, hosts = gitHubHosts()) {
  const candidates = entries2.map((entry) => ({ entry, parsed: parseRemoteUrl(entry.url) })).filter(
    (item) => item.parsed !== null && isGitHubHost(item.parsed.host, hosts)
  );
  if (candidates.length === 0) return null;
  const explicit = candidates.find(
    (item) => item.entry.resolved && item.entry.resolved !== "base"
  );
  if (explicit && explicit.entry.resolved) {
    const resolved = parseResolved(explicit.entry.resolved);
    if (resolved && (resolved.host === null || isGitHubHost(resolved.host, hosts))) {
      return makeRef(
        resolved.host ?? explicit.parsed.host,
        resolved.owner,
        resolved.name,
        explicit.entry.name
      );
    }
  }
  const base = candidates.find((item) => item.entry.resolved === "base");
  const chosen = base ?? [...candidates].sort((a, b) => rank(a.entry.name) - rank(b.entry.name))[0];
  return makeRef(chosen.parsed.host, chosen.parsed.owner, chosen.parsed.name, chosen.entry.name);
}
function makeRef(host, owner, name, remote) {
  return {
    host,
    owner,
    name,
    nameWithOwner: `${owner}/${name}`,
    url: `https://${host}/${owner}/${name}`,
    remote
  };
}
const GH_TIMEOUT_MS = 15e3;
const GIT_TIMEOUT_MS$1 = 5e3;
const MAX_BUFFER$1 = 8 * 1024 * 1024;
async function toolEnv() {
  return {
    ...process.env,
    PATH: await loginPath(),
    // Error text is matched on below, so it must not be localised.
    LC_ALL: "C",
    // gh will happily block on an interactive prompt (auth, repo selection)
    // forever. In a GUI there is no terminal to answer it, so the call would
    // hang until the timeout with no clue why.
    GH_PROMPT_DISABLED: "1",
    GH_NO_UPDATE_NOTIFIER: "1",
    GH_PAGER: "cat",
    // Same reasoning for git's credential prompts during remote resolution.
    GIT_TERMINAL_PROMPT: "0",
    NO_COLOR: "1",
    CLICOLOR: "0"
  };
}
async function gh(args) {
  const { stdout } = await run$4("gh", args, {
    timeout: GH_TIMEOUT_MS,
    maxBuffer: MAX_BUFFER$1,
    windowsHide: true,
    env: await toolEnv()
  });
  return stdout;
}
async function git$1(cwd, args) {
  const { stdout } = await run$4("git", args, {
    cwd,
    timeout: GIT_TIMEOUT_MS$1,
    maxBuffer: MAX_BUFFER$1,
    windowsHide: true,
    env: await toolEnv()
  });
  return stdout;
}
function repoArg(repo) {
  return repo.host === "github.com" ? repo.nameWithOwner : `${repo.host}/${repo.nameWithOwner}`;
}
function parseJson(text2) {
  return JSON.parse(text2);
}
async function resolveRepo(cwd) {
  if (typeof cwd !== "string" || !node_path.isAbsolute(cwd)) {
    return fail$1("error", "Project path must be absolute.", null, String(cwd));
  }
  try {
    const info = await promises.stat(cwd);
    if (!info.isDirectory()) return fail$1("no-such-folder", "That project path is not a folder.", null);
  } catch {
    return fail$1("no-such-folder", "This project folder no longer exists.", null);
  }
  let config;
  try {
    config = await git$1(cwd, ["config", "--local", "--get-regexp", "^remote\\..*\\.(url|gh-resolved)$"]);
  } catch (error) {
    const failure2 = error;
    if (failure2?.code === 1 && !(failure2?.stderr ?? "").trim()) {
      return fail$1(
        "no-remote",
        "This repository has no remotes yet.",
        "git remote add origin <url>"
      );
    }
    if (failure2?.code === "ENOENT") {
      return fail$1("git-missing", "git is not installed, or not on your login PATH.", null);
    }
    const text2 = failure2?.stderr ?? "";
    if (/--local can only be used inside a git repository|not a git repository/i.test(text2)) {
      return fail$1("not-a-repo", "This folder is not a git repository.", "git init", text2);
    }
    return classifyGhError(error);
  }
  const entries2 = parseRemoteConfig(config);
  if (entries2.length === 0) {
    return fail$1("no-remote", "This repository has no remotes yet.", "git remote add origin <url>");
  }
  const repo = pickRepo(entries2);
  if (!repo) {
    const names = entries2.map((entry) => `${entry.name} → ${redact$1(entry.url)}`).join(", ");
    return fail$1(
      "no-github-remote",
      "None of this repository’s remotes point at GitHub.",
      "git remote add github <url>",
      names
    );
  }
  return repo;
}
function mapLabels(labels) {
  if (!Array.isArray(labels)) return [];
  return labels.filter((label2) => typeof label2?.name === "string").map((label2) => ({
    name: label2.name,
    // Six hex digits or nothing — the value is interpolated into CSS, so a
    // stray `;` from a hand-crafted API response cannot reach the stylesheet.
    color: /^[0-9a-f]{6}$/i.test(label2.color ?? "") ? label2.color : "8b949e"
  }));
}
function pullBadge(raw) {
  const state = (raw.state ?? "").toUpperCase();
  if (state === "MERGED" || raw.mergedAt) return "merged";
  if (state === "CLOSED") return "closed";
  return raw.isDraft ? "draft" : "open";
}
const REVIEW_BY_DECISION = {
  APPROVED: "approved",
  CHANGES_REQUESTED: "changes-requested",
  REVIEW_REQUIRED: "review-required"
};
function mapPullRequest(raw) {
  if (typeof raw?.number !== "number" || typeof raw.url !== "string") return null;
  return {
    number: raw.number,
    title: raw.title ?? "(untitled)",
    url: raw.url,
    badge: pullBadge(raw),
    draft: raw.isDraft === true,
    author: raw.author?.login ?? null,
    authorIsBot: raw.author?.is_bot === true,
    createdAt: raw.createdAt ?? "",
    updatedAt: raw.updatedAt ?? raw.createdAt ?? "",
    review: REVIEW_BY_DECISION[(raw.reviewDecision ?? "").toUpperCase()] ?? null,
    labels: mapLabels(raw.labels),
    branch: raw.headRefName ?? null,
    fromFork: raw.isCrossRepository === true,
    additions: typeof raw.additions === "number" ? raw.additions : null,
    deletions: typeof raw.deletions === "number" ? raw.deletions : null
  };
}
function mapIssue(raw) {
  if (typeof raw?.number !== "number" || typeof raw.url !== "string") return null;
  const reason = (raw.stateReason ?? "").toUpperCase();
  return {
    number: raw.number,
    title: raw.title ?? "(untitled)",
    url: raw.url,
    state: (raw.state ?? "").toUpperCase() === "CLOSED" ? "closed" : "open",
    reason: reason === "COMPLETED" ? "completed" : reason === "NOT_PLANNED" ? "not-planned" : null,
    author: raw.author?.login ?? null,
    authorIsBot: raw.author?.is_bot === true,
    createdAt: raw.createdAt ?? "",
    updatedAt: raw.updatedAt ?? raw.createdAt ?? "",
    labels: mapLabels(raw.labels),
    assignees: Array.isArray(raw.assignees) ? raw.assignees.map((assignee) => assignee?.login).filter((login) => typeof login === "string") : []
  };
}
const NOTIFICATION_PAGE_SIZE = 50;
function summarizeNotifications(raw, nameWithOwner) {
  const list = Array.isArray(raw) ? raw : [];
  const reasons = {};
  let repo = 0;
  for (const item of list) {
    if (item?.unread === false) continue;
    const reason = item?.reason ?? "other";
    reasons[reason] = (reasons[reason] ?? 0) + 1;
    if (item?.repository?.full_name?.toLowerCase() === nameWithOwner.toLowerCase()) repo += 1;
  }
  const total = Object.values(reasons).reduce((sum, count) => sum + count, 0);
  return { total, repo, capped: list.length >= NOTIFICATION_PAGE_SIZE, reasons };
}
const OK_TTL_MS = 6e4;
const ERROR_TTL_MS = 15e3;
const MAX_CACHE_ENTRIES = 200;
const cache$2 = /* @__PURE__ */ new Map();
const inflight = /* @__PURE__ */ new Map();
function remember(key, value, ttl) {
  const now = Date.now();
  for (const [existing, entry] of cache$2) {
    if (entry.expiresAt <= now) cache$2.delete(existing);
  }
  cache$2.delete(key);
  while (cache$2.size >= MAX_CACHE_ENTRIES) {
    const oldest = cache$2.keys().next().value;
    if (oldest === void 0) break;
    cache$2.delete(oldest);
  }
  cache$2.set(key, { value, expiresAt: now + ttl });
}
async function cacheThrough(key, refresh2, load2, ttl) {
  if (!refresh2) {
    const hit = cache$2.get(key);
    if (hit && hit.expiresAt > Date.now()) return hit.value;
    const joined = inflight.get(key);
    if (joined) return joined;
  }
  let pending;
  const release2 = () => {
    if (inflight.get(key) === pending) inflight.delete(key);
  };
  pending = load2().then((value) => {
    if (inflight.get(key) === pending) remember(key, value, ttl(value));
    return value;
  }).finally(release2);
  inflight.set(key, pending);
  return pending;
}
function clearGitHubCache(prefix) {
  {
    cache$2.clear();
    inflight.clear();
    return;
  }
}
function sectionTtl(section) {
  return section.ok ? OK_TTL_MS : ERROR_TTL_MS;
}
function sectionKey(kind, repo, limit) {
  const scope = `${kind} ${repo.host}/${repo.nameWithOwner}`;
  return limit === void 0 ? scope : `${scope} ${limit}`;
}
const DEFAULT_LIMIT$1 = 20;
const MAX_LIMIT = 100;
function clampLimit(value) {
  const n = typeof value === "number" && Number.isFinite(value) ? Math.floor(value) : DEFAULT_LIMIT$1;
  return Math.min(Math.max(n, 1), MAX_LIMIT);
}
const PULL_FIELDS = [
  "number",
  "title",
  "url",
  "state",
  "isDraft",
  "mergedAt",
  "author",
  "createdAt",
  "updatedAt",
  "reviewDecision",
  "labels",
  "headRefName",
  "isCrossRepository",
  "additions",
  "deletions"
].join(",");
const ISSUE_FIELDS = [
  "number",
  "title",
  "url",
  "state",
  "stateReason",
  "author",
  "createdAt",
  "updatedAt",
  "labels",
  "assignees"
].join(",");
function pullListArgs(repo, limit) {
  return [
    "pr",
    "list",
    "-R",
    repoArg(repo),
    "--state",
    "open",
    "--limit",
    String(limit),
    "--json",
    PULL_FIELDS
  ];
}
function issueListArgs(repo, limit) {
  return [
    "issue",
    "list",
    "-R",
    repoArg(repo),
    "--state",
    "open",
    "--limit",
    String(limit),
    "--json",
    ISSUE_FIELDS
  ];
}
function notificationArgs(repo) {
  return [
    "api",
    "--hostname",
    repo.host,
    `notifications?all=false&per_page=${NOTIFICATION_PAGE_SIZE}`,
    "-H",
    "Accept: application/vnd.github+json"
  ];
}
async function fetchPulls(repo, limit) {
  try {
    const out = await gh(pullListArgs(repo, limit));
    const rows = parseJson(out);
    if (!Array.isArray(rows)) return fail$1("error", "gh returned an unexpected pull-request payload.", null);
    return {
      ok: true,
      value: rows.map(mapPullRequest).filter((pull) => pull !== null)
    };
  } catch (error) {
    return error instanceof SyntaxError ? fail$1("error", "gh returned output that could not be parsed.", null, error.message) : classifyGhError(error);
  }
}
async function fetchIssues(repo, limit) {
  try {
    const out = await gh(issueListArgs(repo, limit));
    const rows = parseJson(out);
    if (!Array.isArray(rows)) return fail$1("error", "gh returned an unexpected issue payload.", null);
    return { ok: true, value: rows.map(mapIssue).filter((issue) => issue !== null) };
  } catch (error) {
    return error instanceof SyntaxError ? fail$1("error", "gh returned output that could not be parsed.", null, error.message) : classifyGhError(error);
  }
}
async function fetchNotifications(repo) {
  try {
    const out = await gh(notificationArgs(repo));
    return { ok: true, value: summarizeNotifications(parseJson(out), repo.nameWithOwner) };
  } catch (error) {
    return error instanceof SyntaxError ? fail$1("error", "gh returned output that could not be parsed.", null, error.message) : classifyGhError(error);
  }
}
async function readGitHubOverview(cwd, options = {}) {
  const refresh2 = options.refresh === true;
  const limit = clampLimit(options.limit);
  const repo = await cacheThrough(
    `repo ${cwd}`,
    refresh2,
    () => resolveRepo(cwd),
    // `ok` exists only on the failure arm — a RepoRef carries no such field.
    (value) => "ok" in value ? ERROR_TTL_MS : OK_TTL_MS
  );
  if ("ok" in repo) return repo;
  const ref = repo;
  const [pulls, issues, notifications] = await Promise.all([
    cacheThrough(sectionKey("pulls", ref, limit), refresh2, () => fetchPulls(ref, limit), sectionTtl),
    cacheThrough(
      sectionKey("issues", ref, limit),
      refresh2,
      () => fetchIssues(ref, limit),
      sectionTtl
    ),
    cacheThrough(sectionKey("notifications", ref), refresh2, () => fetchNotifications(ref), sectionTtl)
  ]);
  return { ok: true, cwd, repo: ref, pulls, issues, notifications, limit, fetchedAt: Date.now() };
}
function asPath(value) {
  return typeof value === "string" && value.length > 0 && node_path.isAbsolute(value) ? value : null;
}
function asOptions(value) {
  if (typeof value !== "object" || value === null) return {};
  const raw = value;
  return { refresh: raw.refresh === true, limit: clampLimit(raw.limit) };
}
function registerGitHubIpc(ipcMain) {
  const badPath = (value) => fail$1("error", "Project path must be absolute.", null, String(value));
  ipcMain.handle("github:overview", (_event, cwd, options) => {
    const path = asPath(cwd);
    return path ? readGitHubOverview(path, asOptions(options)) : Promise.resolve(badPath(cwd));
  });
  ipcMain.handle("github:refresh", (_event, cwd, options) => {
    const path = asPath(cwd);
    if (!path) return Promise.resolve(badPath(cwd));
    return readGitHubOverview(path, { ...asOptions(options), refresh: true });
  });
  ipcMain.handle("github:repo", (_event, cwd) => {
    const path = asPath(cwd);
    return path ? resolveRepo(path) : Promise.resolve(badPath(cwd));
  });
  ipcMain.on("github:clear-cache", () => {
    clearGitHubCache();
  });
}
const run$3 = node_util.promisify(node_child_process.execFile);
const STATUS_CREDIT = {
  pass: 1,
  warn: 0.5,
  fail: 0,
  skip: 0
};
const CHECK_WEIGHTS = {
  secrets: 30,
  "claude-md": 18,
  "test-script": 14,
  "git-repo": 12,
  gitignore: 10,
  readme: 8,
  "typecheck-script": 8,
  "git-clean": 8,
  "lint-script": 6,
  lockfile: 6
};
const SECRET_FAIL_CAP = 39;
const SECRET_WARN_CAP = 79;
const BANDS = [
  { min: 85, band: "strong" },
  { min: 65, band: "fair" },
  { min: 40, band: "weak" },
  { min: 0, band: "at-risk" }
];
function bandFor(score) {
  return BANDS.find((entry) => score >= entry.min)?.band ?? "at-risk";
}
function scoreChecks(checks) {
  let earned = 0;
  let applicable = 0;
  for (const check2 of checks) {
    if (check2.status === "skip") continue;
    applicable += check2.weight;
    earned += check2.weight * STATUS_CREDIT[check2.status];
  }
  let score = applicable > 0 ? Math.round(earned / applicable * 100) : 0;
  let cappedBy = null;
  for (const check2 of checks) {
    if (!check2.gate || check2.status === "pass" || check2.status === "skip") continue;
    const cap = check2.status === "fail" ? SECRET_FAIL_CAP : SECRET_WARN_CAP;
    if (score > cap) {
      score = cap;
      cappedBy = check2.title;
    }
  }
  return { score, band: bandFor(score), cappedBy };
}
const MAX_JSON_BYTES = 2 * 1024 * 1024;
const MAX_TEXT_BYTES = 1024 * 1024;
async function readTextEntry(root, relPath, limit = MAX_TEXT_BYTES) {
  try {
    const file = safeJoin(root, relPath);
    const info = await promises.stat(file);
    if (!info.isFile()) return { kind: "missing" };
    if (info.size > limit) return { kind: "too-big", bytes: info.size };
    return { kind: "text", text: await promises.readFile(file, "utf8") };
  } catch {
    return { kind: "missing" };
  }
}
async function readTextAt(root, relPath) {
  const entry = await readTextEntry(root, relPath);
  return entry.kind === "text" ? entry.text : null;
}
function formatBytes(bytes2) {
  if (bytes2 >= 1024 * 1024) return `${(bytes2 / (1024 * 1024)).toFixed(1)} MB`;
  if (bytes2 >= 1024) return `${Math.round(bytes2 / 1024)} KB`;
  return `${bytes2} bytes`;
}
function listPaths(paths, max = 4) {
  const shown = paths.slice(0, max).join(", ");
  return paths.length > max ? `${shown} and ${paths.length - max} more` : shown;
}
async function exists$1(root, relPath) {
  try {
    await promises.stat(safeJoin(root, relPath));
    return true;
  } catch {
    return false;
  }
}
async function readPackageJson$1(root) {
  const entry = await readTextEntry(root, "package.json", MAX_JSON_BYTES);
  if (entry.kind !== "text") return null;
  const raw = entry.text;
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  const root_ = parsed;
  return {
    scripts: stringMap$1(root_.scripts),
    deps: { ...stringMap$1(root_.dependencies), ...stringMap$1(root_.devDependencies) },
    raw
  };
}
function stringMap$1(value) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  const out = {};
  for (const [key, entry] of Object.entries(value)) {
    if (typeof entry === "string") out[key] = entry;
  }
  return out;
}
function meaningfulLines(text2) {
  let count = 0;
  for (const line of text2.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    if (/^(-{3,}|={3,}|\*{3,})$/.test(trimmed)) continue;
    if (trimmed.startsWith("<!--")) continue;
    count++;
  }
  return count;
}
const GIT_TIMEOUT_MS = 8e3;
const MAX_BUFFER = 16 * 1024 * 1024;
async function git(cwd, args, options = {}) {
  const PATH = await loginPath();
  const { stdout } = await run$3("git", args, {
    cwd,
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: MAX_BUFFER,
    windowsHide: true,
    env: {
      ...process.env,
      PATH,
      ...options.write ? {} : { GIT_OPTIONAL_LOCKS: "0" },
      LC_ALL: "C"
    }
  });
  return stdout;
}
async function trackedFiles(root) {
  try {
    const out = await git(root, ["ls-files", "-z"]);
    return out.split("\0").filter((entry) => entry !== "");
  } catch {
    return null;
  }
}
const SECRET_FILE_RE = /(^|\/)(\.env(\.[^/]+)?|[^/]+\.(pem|p12|pfx|jks|keystore)|id_(rsa|dsa|ecdsa|ed25519)|\.netrc|\.pgpass|secrets?\.(json|ya?ml)|credentials\.json|serviceaccount[^/]*\.json)$/i;
const EXAMPLE_SUFFIX_RE = /\.(example|sample|template|dist|defaults?)$/i;
const NPMRC_TOKEN_RE = /^\s*(\/\/.*:)?_auth(Token)?\s*=/im;
function looksLikeSecretFile(relPath) {
  if (EXAMPLE_SUFFIX_RE.test(relPath)) return false;
  return SECRET_FILE_RE.test(relPath);
}
const NPMRC_RE = /(^|\/)\.npmrc$/;
async function secretPathsAmong(root, paths) {
  const found = [];
  for (const path of paths) {
    if (looksLikeSecretFile(path)) {
      found.push(path);
      continue;
    }
    if (!NPMRC_RE.test(path)) continue;
    const text2 = await readTextAt(root, path);
    if (text2 !== null && NPMRC_TOKEN_RE.test(text2)) found.push(path);
  }
  return found;
}
const SECRET_IGNORE_PATTERNS = [
  ".env",
  ".env.*",
  "!.env.example",
  "*.pem",
  "*.p12",
  "*.pfx",
  "id_rsa",
  "id_ed25519",
  ".netrc"
];
function ignoreCovers(rules, relPath, isDir) {
  const segments = relPath.split("/").filter((segment) => segment !== "");
  if (segments.length === 0) return false;
  for (let i = 0; i < segments.length; i++) {
    const last = i === segments.length - 1;
    const path = segments.slice(0, i + 1).join("/");
    let covered = false;
    for (const rule of rules) {
      if (rule.dirOnly && !(last ? isDir : true)) continue;
      if (rule.re.test(path)) covered = !rule.negated;
    }
    if (covered) return true;
    if (last) return false;
  }
  return false;
}
async function readIgnoreRules(root) {
  const text2 = await readTextAt(root, ".gitignore");
  return text2 === null ? null : parseIgnoreFile(text2);
}
function check(id2, title, status, detail, fix = null, gate = false) {
  return { id: id2, title, status, weight: CHECK_WEIGHTS[id2], detail, fix, gate };
}
const FIX_IGNORE_SECRETS = {
  id: "ignore-secrets",
  label: "Ignore secret files",
  description: "Appends the standard secret patterns (.env, .env.*, *.pem, id_rsa and friends) to .gitignore, keeping .env.example allowed. Creates .gitignore if it does not exist. Nothing is deleted, and no file on disk is touched.",
  touches: [".gitignore"],
  destructive: false
};
const FIX_UNTRACK_SECRETS = {
  id: "untrack-secrets",
  label: "Untrack and ignore",
  description: "Adds the secret patterns to .gitignore, then runs `git rm --cached` on the tracked secret files so git stops following them. The files stay on your disk. This does NOT erase them from past commits — anything already pushed must be treated as leaked, and those keys rotated.",
  touches: [".gitignore", "git index"],
  destructive: true
};
async function checkSecrets(root, tracked) {
  const committed = await secretPathsAmong(root, tracked ?? []);
  if (committed.length > 0) {
    return check(
      "secrets",
      "No secrets committed",
      "fail",
      `git is tracking ${committed.length} credential file${committed.length === 1 ? "" : "s"}: ${listPaths(committed)}. Anything an agent reads it can also quote back into a transcript, a commit message or a pull request — and if this repo has ever been pushed, those keys are already public. Untrack them, then rotate them.`,
      FIX_UNTRACK_SECRETS,
      true
    );
  }
  let names = [];
  try {
    names = (await promises.readdir(root, { withFileTypes: true })).filter((entry) => entry.isFile()).map((entry) => entry.name);
  } catch {
    names = [];
  }
  const present = names.filter(looksLikeSecretFile);
  if (present.length === 0) {
    return check(
      "secrets",
      "No secrets committed",
      "pass",
      "No credential files are tracked by git or sitting unignored in the project root.",
      null,
      true
    );
  }
  const rules = await readIgnoreRules(root);
  const exposed = present.filter((name) => !rules || !ignoreCovers(rules, name, false));
  if (exposed.length === 0) {
    return check(
      "secrets",
      "No secrets committed",
      "pass",
      `${present.length} credential file${present.length === 1 ? " is" : "s are"} present but covered by .gitignore, so git will not pick ${present.length === 1 ? "it" : "them"} up.`,
      null,
      true
    );
  }
  return check(
    "secrets",
    "No secrets committed",
    "warn",
    `${listPaths(exposed)} ${exposed.length === 1 ? "is" : "are"} in the project and not covered by .gitignore. Nothing has leaked yet, but the next \`git add .\` — yours or an agent's — commits ${exposed.length === 1 ? "it" : "them"}.`,
    FIX_IGNORE_SECRETS,
    true
  );
}
const CLAUDE_MD_CANDIDATES = ["CLAUDE.md", ".claude/CLAUDE.md", "AGENTS.md"];
const CLAUDE_MD_MIN_LINES = 12;
const CLAUDE_MD_BLOAT_LINES = 400;
const COMMAND_HINT_RE = /```|(^|[\s`("'])(npm|pnpm|yarn|bun|npx|make|cargo|pytest|uv|dotnet|gradle|mvn|docker|deno|rake|tox|go (run|test|build)|python3? -m|\.\/[\w.-]+\.sh)\b/i;
const FIX_CREATE_CLAUDE_MD = {
  id: "create-claude-md",
  label: "Create CLAUDE.md",
  description: "Writes a CLAUDE.md skeleton at the project root with the sections an agent reads first — what this is, how to run it, how to test it, layout and conventions — each left as a prompt for you to fill in. Refuses if CLAUDE.md already exists.",
  touches: ["CLAUDE.md"],
  destructive: false
};
async function checkClaudeMd(root) {
  let found = null;
  let text2 = null;
  for (const candidate of CLAUDE_MD_CANDIDATES) {
    const entry = await readTextEntry(root, candidate);
    if (entry.kind === "too-big") {
      return check(
        "claude-md",
        "CLAUDE.md present and useful",
        "warn",
        `${candidate} is ${formatBytes(entry.bytes)}. It is re-read on every prompt, so at that size it crowds out your own source — and it is too large for this scan to read at all. Cut it to the essentials and link the rest.`
      );
    }
    if (entry.kind === "text") {
      found = candidate;
      text2 = entry.text;
      break;
    }
  }
  if (text2 === null || found === null) {
    return check(
      "claude-md",
      "CLAUDE.md present and useful",
      "fail",
      "No CLAUDE.md, .claude/CLAUDE.md or AGENTS.md. Every session starts by re-deriving your build commands, your layout and your conventions from scratch — slower, more expensive, and wrong more often.",
      FIX_CREATE_CLAUDE_MD
    );
  }
  const lines2 = meaningfulLines(text2);
  if (lines2 < CLAUDE_MD_MIN_LINES) {
    return check(
      "claude-md",
      "CLAUDE.md present and useful",
      "warn",
      `${found} exists but holds only ${lines2} meaningful line${lines2 === 1 ? "" : "s"}. A stub is barely better than nothing: cover what the project is, how to run it, how to test it, and the conventions you actually enforce.`
    );
  }
  if (lines2 > CLAUDE_MD_BLOAT_LINES) {
    return check(
      "claude-md",
      "CLAUDE.md present and useful",
      "warn",
      `${found} is ${lines2} meaningful lines. It is re-read on every prompt, so past roughly ${CLAUDE_MD_BLOAT_LINES} lines it competes with your own source for context. Move the depth into linked files.`
    );
  }
  if (!COMMAND_HINT_RE.test(text2)) {
    return check(
      "claude-md",
      "CLAUDE.md present and useful",
      "warn",
      `${found} is a good length (${lines2} lines) but names no runnable commands. Without the exact build and test commands an agent guesses, and guesses badly on anything with custom scripts.`
    );
  }
  return check(
    "claude-md",
    "CLAUDE.md present and useful",
    "pass",
    `${found} is ${lines2} meaningful lines and documents commands an agent can run.`
  );
}
const FIX_CREATE_README = {
  id: "create-readme",
  label: "Create README.md",
  description: "Writes a short README.md at the project root — title, one-line summary, install, run, test — with placeholders to fill in. Refuses if a README already exists.",
  touches: ["README.md"],
  destructive: false
};
const README_MIN_LINES = 5;
async function checkReadme(root) {
  let name = null;
  try {
    const entries2 = await promises.readdir(root, { withFileTypes: true });
    name = entries2.find((entry2) => entry2.isFile() && /^readme(\.|$)/i.test(entry2.name))?.name ?? null;
  } catch {
    name = null;
  }
  if (name === null) {
    return check(
      "readme",
      "README for humans",
      "fail",
      "No README. It is the file an agent opens when CLAUDE.md does not answer the question, and the one a new contributor opens first.",
      FIX_CREATE_README
    );
  }
  const entry = await readTextEntry(root, name);
  if (entry.kind !== "text") {
    return check(
      "readme",
      "README for humans",
      "pass",
      entry.kind === "too-big" ? `${name} is ${formatBytes(entry.bytes)} — too large to measure here, but nobody could call it a stub.` : `${name} is present but could not be read; taking it at face value.`
    );
  }
  const lines2 = meaningfulLines(entry.text);
  if (lines2 < README_MIN_LINES) {
    return check(
      "readme",
      "README for humans",
      "warn",
      `${name} has ${lines2} meaningful line${lines2 === 1 ? "" : "s"} — effectively a title. Say what this is and how to run it.`
    );
  }
  return check("readme", "README for humans", "pass", `${name} is ${lines2} meaningful lines.`);
}
const PLACEHOLDER_TEST_RE = /no test specified/i;
function detectTestRunner(deps) {
  if (deps.vitest) return { script: "test", command: "vitest run" };
  if (deps.jest) return { script: "test", command: "jest" };
  if (deps.mocha) return { script: "test", command: "mocha" };
  if (deps.ava) return { script: "test", command: "ava" };
  if (deps.playwright || deps["@playwright/test"]) {
    return { script: "test", command: "playwright test" };
  }
  return null;
}
function detectLinter(deps) {
  if (deps.eslint) return { script: "lint", command: "eslint ." };
  if (deps["@biomejs/biome"]) return { script: "lint", command: "biome check ." };
  if (deps.oxlint) return { script: "lint", command: "oxlint" };
  if (deps.prettier) return { script: "lint", command: "prettier --check ." };
  return null;
}
function scriptMatching(scripts, name, body) {
  for (const [key, value] of Object.entries(scripts)) {
    if (name.test(key) || body.test(value)) return key;
  }
  return null;
}
function fixAddScript(id2, label2, runner) {
  return {
    id: id2,
    label: label2,
    description: `Adds "${runner.script}": "${runner.command}" to the scripts block in package.json, using the tool already in your dependencies. Existing scripts are left alone, and it refuses if "${runner.script}" is already defined.`,
    touches: ["package.json"],
    destructive: false
  };
}
async function otherTestMarker(root) {
  const pyproject = await readTextAt(root, "pyproject.toml");
  if (pyproject && /\bpytest\b/.test(pyproject)) return "pyproject.toml (pytest)";
  if (await exists$1(root, "Cargo.toml")) return "Cargo.toml (cargo test)";
  if (await exists$1(root, "go.mod")) return "go.mod (go test)";
  const makefile = await readTextAt(root, "Makefile");
  if (makefile && /^test\s*:/m.test(makefile)) return "Makefile (make test)";
  return null;
}
async function checkTestScript(root, pkg) {
  if (pkg === null) {
    const marker = await otherTestMarker(root);
    if (marker !== null) {
      return check(
        "test-script",
        "Tests can be run with one command",
        "pass",
        `${marker} gives an agent a single command to verify its own changes.`
      );
    }
    return check(
      "test-script",
      "Tests can be run with one command",
      "skip",
      "No package.json or other recognised project manifest, so there is no test entry point to look for."
    );
  }
  const value = pkg.scripts.test;
  if (typeof value === "string" && value.trim() !== "" && !PLACEHOLDER_TEST_RE.test(value)) {
    return check(
      "test-script",
      "Tests can be run with one command",
      "pass",
      `\`npm test\` runs \`${value}\`. An agent can check its own work before handing it back.`
    );
  }
  const runner = detectTestRunner(pkg.deps);
  const placeholder = typeof value === "string" && PLACEHOLDER_TEST_RE.test(value);
  const detail = placeholder ? "The test script is still npm's placeholder, which exits 1 without running anything. An agent that runs it sees a failure it cannot explain." : runner ? `No test script, although \`${runner.command.split(" ")[0]}\` is installed. Without one, an agent writes code it has no way to verify.` : "No test script and no test runner in the dependencies. An agent cannot verify its own changes, so every mistake reaches you instead of the test output.";
  return check(
    "test-script",
    "Tests can be run with one command",
    "fail",
    detail,
    runner && !placeholder ? fixAddScript("add-test-script", "Add test script", runner) : null
  );
}
async function checkTypecheckScript(root, pkg) {
  const hasTsconfig = await exists$1(root, "tsconfig.json");
  const hasTypescript = pkg !== null && Boolean(pkg.deps.typescript);
  if (!hasTsconfig && !hasTypescript) {
    return check(
      "typecheck-script",
      "Types can be checked without building",
      "skip",
      "Not a TypeScript project."
    );
  }
  if (pkg === null) {
    return check(
      "typecheck-script",
      "Types can be checked without building",
      "warn",
      "A tsconfig.json is present but there is no package.json to hang a typecheck script on."
    );
  }
  const found = scriptMatching(pkg.scripts, /^(typecheck|type-check|check-types|tsc)$/i, /tsc\b[^&|]*--noEmit/);
  if (found !== null) {
    return check(
      "typecheck-script",
      "Types can be checked without building",
      "pass",
      `\`npm run ${found}\` type-checks the project. That is the fastest signal an agent has that an edit is sound.`
    );
  }
  return check(
    "typecheck-script",
    "Types can be checked without building",
    "fail",
    "No typecheck script. An agent either runs a full build to find a type error — slow — or ships the error.",
    hasTypescript ? fixAddScript("add-typecheck-script", "Add typecheck script", {
      script: "typecheck",
      command: "tsc --noEmit"
    }) : null
  );
}
function checkLintScript(pkg) {
  if (pkg === null) {
    return check("lint-script", "Lint or format check", "skip", "No package.json to look for a lint script in.");
  }
  const found = scriptMatching(
    pkg.scripts,
    /^(lint|format|fmt|check)$/i,
    /\b(eslint|biome|oxlint|prettier|standard)\b/
  );
  if (found !== null) {
    return check(
      "lint-script",
      "Lint or format check",
      "pass",
      `\`npm run ${found}\` checks style, so generated code lands in your house style rather than the model's.`
    );
  }
  const linter = detectLinter(pkg.deps);
  return check(
    "lint-script",
    "Lint or format check",
    linter ? "fail" : "warn",
    linter ? "A linter is installed but no script exposes it. An agent will not find it, so nothing it writes is checked." : "No lint or format script. Without one, every agent edit drifts a little further from your conventions and reviews get noisier.",
    linter ? fixAddScript("add-lint-script", "Add lint script", linter) : null
  );
}
const FIX_CREATE_GITIGNORE = {
  id: "create-gitignore",
  label: "Create .gitignore",
  description: "Writes a .gitignore covering dependencies, build output, logs, editor and OS junk, and every common secret file — with .env.example still allowed through.",
  touches: [".gitignore"],
  destructive: false
};
const FIX_PATCH_GITIGNORE = {
  id: "patch-gitignore",
  label: "Add missing patterns",
  description: "Appends only the essential patterns your .gitignore is missing, under a comment saying where they came from. Existing lines are never edited or reordered.",
  touches: [".gitignore"],
  destructive: false
};
async function essentialPatterns(root, pkg) {
  const wanted = [".env"];
  if (pkg !== null) wanted.push("node_modules");
  if (await exists$1(root, "dist")) wanted.push("dist");
  if (await exists$1(root, "build")) wanted.push("build");
  return wanted;
}
async function checkGitignore(root, pkg) {
  const rules = await readIgnoreRules(root);
  if (rules === null) {
    return check(
      "gitignore",
      ".gitignore covers the basics",
      "fail",
      "No .gitignore. Build output, dependencies and — worse — secrets are all one `git add .` from being committed, and agents run `git add .` constantly.",
      FIX_CREATE_GITIGNORE
    );
  }
  const wanted = await essentialPatterns(root, pkg);
  const missing = wanted.filter((path) => !ignoreCovers(rules, path, path !== ".env"));
  if (missing.length === 0) {
    return check(
      "gitignore",
      ".gitignore covers the basics",
      "pass",
      `.gitignore has ${rules.length} rule${rules.length === 1 ? "" : "s"} and covers ${wanted.join(", ")}.`
    );
  }
  return check(
    "gitignore",
    ".gitignore covers the basics",
    "warn",
    `.gitignore does not cover ${missing.join(", ")}. Uncovered paths become noise in every diff an agent reads — and one of them is where credentials live.`,
    FIX_PATCH_GITIGNORE
  );
}
const FIX_GIT_INIT = {
  id: "git-init",
  label: "Initialise git",
  description: "Runs `git init` in the project folder. It creates a repository and commits nothing — no files are added, staged or changed.",
  touches: [".git"],
  destructive: false
};
async function checkGitRepo(root, gitDir) {
  if (gitDir !== null) {
    return check(
      "git-repo",
      "Git repository initialised",
      "pass",
      "The project is a git repository, so an agent's work is reviewable and reversible."
    );
  }
  return check(
    "git-repo",
    "Git repository initialised",
    "fail",
    "Not a git repository. Nothing an agent changes can be diffed, reviewed or undone — the single biggest safety net for AI-assisted work is missing.",
    await exists$1(root, ".git") ? null : FIX_GIT_INIT
  );
}
const DIRTY_FAIL_FILES = 20;
async function checkGitClean(root, gitDir) {
  if (gitDir === null) {
    return check("git-clean", "Working tree is reviewable", "skip", "Not a git repository.");
  }
  const status = await readGitStatus(root);
  if (!status.repo) {
    return check("git-clean", "Working tree is reviewable", "skip", status.message);
  }
  if (status.conflicted.length > 0) {
    return check(
      "git-clean",
      "Working tree is reviewable",
      "fail",
      `${status.conflicted.length} file${status.conflicted.length === 1 ? " is" : "s are"} in a merge conflict. An agent editing around conflict markers makes the mess worse, not better.`
    );
  }
  if (status.clean) {
    return check(
      "git-clean",
      "Working tree is reviewable",
      "pass",
      "Clean tree. Anything an agent changes from here shows up in `git diff` as its own work."
    );
  }
  const dirty = (/* @__PURE__ */ new Set([
    ...status.staged.map((file) => file.path),
    ...status.unstaged.map((file) => file.path),
    ...status.untracked.map((file) => file.path)
  ])).size;
  return check(
    "git-clean",
    "Working tree is reviewable",
    dirty > DIRTY_FAIL_FILES ? "fail" : "warn",
    `${dirty} uncommitted change${dirty === 1 ? "" : "s"} already in the tree. Commit or stash first, or an agent's diff arrives mixed into yours and neither can be reverted on its own.`
  );
}
const LOCKFILES = [
  "package-lock.json",
  "npm-shrinkwrap.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "bun.lockb",
  "bun.lock"
];
async function checkLockfile(root, pkg) {
  if (pkg === null) {
    if (await exists$1(root, "Cargo.toml")) {
      const locked = await exists$1(root, "Cargo.lock");
      return check(
        "lockfile",
        "Dependencies are pinned",
        locked ? "pass" : "warn",
        locked ? "Cargo.lock pins the dependency graph." : "Cargo.toml with no Cargo.lock."
      );
    }
    return check("lockfile", "Dependencies are pinned", "skip", "No package manifest to lock.");
  }
  for (const name of LOCKFILES) {
    if (await exists$1(root, name)) {
      return check(
        "lockfile",
        "Dependencies are pinned",
        "pass",
        `${name} pins the dependency graph, so an agent running an install gets what you have.`
      );
    }
  }
  return check(
    "lockfile",
    "Dependencies are pinned",
    "warn",
    "No lockfile. An agent that runs an install can pull different versions than you have, and the failure it then debugs is not the one you would see. Commit the lockfile your package manager generates."
  );
}
function failedCheck(id2, title, error, gate = false) {
  const message = error instanceof Error ? error.message : String(error);
  return gate ? check(
    id2,
    title,
    "warn",
    `This check could not run: ${message}. Until it can, this project is unverified and cannot be scored as safe.`,
    null,
    true
  ) : check(id2, title, "skip", `This check could not run: ${message}`);
}
async function guard(id2, title, fn, gate = false) {
  try {
    return await fn();
  } catch (error) {
    return failedCheck(id2, title, error, gate);
  }
}
async function scanReadiness(projectPath2) {
  const root = projectPath2;
  const gitDir = await findGitDir(root);
  const [pkg, tracked] = await Promise.all([
    readPackageJson$1(root),
    gitDir === null ? Promise.resolve(null) : trackedFiles(root)
  ]);
  const checks = await Promise.all([
    guard("secrets", "No secrets committed", () => checkSecrets(root, tracked), true),
    guard("claude-md", "CLAUDE.md present and useful", () => checkClaudeMd(root)),
    guard("test-script", "Tests can be run with one command", () => checkTestScript(root, pkg)),
    guard("git-repo", "Git repository initialised", () => checkGitRepo(root, gitDir)),
    guard("gitignore", ".gitignore covers the basics", () => checkGitignore(root, pkg)),
    guard("readme", "README for humans", () => checkReadme(root)),
    guard(
      "typecheck-script",
      "Types can be checked without building",
      () => checkTypecheckScript(root, pkg)
    ),
    guard("git-clean", "Working tree is reviewable", () => checkGitClean(root, gitDir)),
    guard("lint-script", "Lint or format check", async () => checkLintScript(pkg)),
    guard("lockfile", "Dependencies are pinned", () => checkLockfile(root, pkg))
  ]);
  const { score, band, cappedBy } = scoreChecks(checks);
  return { projectPath: root, score, band, checks, cappedBy, scannedAt: (/* @__PURE__ */ new Date()).toISOString() };
}
const CLAUDE_MD_TEMPLATE = `# CLAUDE.md

Instructions for an AI agent working in this repository.

## What this is

<!-- One paragraph: what the project does and who it is for. -->

## Run it

\`\`\`sh
# install
# start
\`\`\`

## Test it

\`\`\`sh
# the exact command that proves a change is sound
\`\`\`

## Layout

<!-- The three or four directories that matter, and what lives in each. -->

## Conventions

<!-- Style, naming and patterns you actually enforce in review. -->

## Do not

<!-- Files, directories or commands an agent must leave alone. -->
`;
function readmeTemplate(name) {
  return `# ${name}

<!-- One line: what this is. -->

## Install

\`\`\`sh
# install command
\`\`\`

## Run

\`\`\`sh
# run command
\`\`\`

## Test

\`\`\`sh
# test command
\`\`\`
`;
}
const GITIGNORE_TEMPLATE = `# Dependencies
node_modules/

# Build output
dist/
build/
out/
*.tsbuildinfo

# Logs
*.log
npm-debug.log*

# Editor and OS
.DS_Store
.idea/
.vscode/*
!.vscode/extensions.json

# Secrets — never commit these
${SECRET_IGNORE_PATTERNS.join("\n")}
`;
const TERMINALDECK_BLOCK_HEADER = "# added by Deck — AI readiness";
const RM_BATCH = 100;
const TEMPLATE_NOTE = "Fill in the placeholders — a skeleton is a starting point, not context.";
function ok(message, changed) {
  return { ok: true, message, changed };
}
function refuse(message) {
  return { ok: false, message, changed: [] };
}
async function createFile(root, relPath, body, note = "") {
  const target2 = safeJoin(root, relPath);
  try {
    await promises.writeFile(target2, body, { encoding: "utf8", flag: "wx" });
    return ok(`Created ${relPath}.${note ? ` ${note}` : ""}`, [relPath]);
  } catch (error) {
    if (error.code === "EEXIST") {
      return refuse(`${relPath} already exists — nothing was changed.`);
    }
    throw error;
  }
}
function samplePathFor(pattern) {
  const isDir = pattern.endsWith("/");
  const body = (isDir ? pattern.slice(0, -1) : pattern).replace(/^!/, "");
  return { path: body.replace(/\*\*\//g, "").replace(/\*/g, "x") || "x", isDir };
}
function ignoreBlockFor(existing, patterns) {
  const lines2 = new Set(existing.split(/\r?\n/).map((line) => line.trim()));
  const rules = parseIgnoreFile(existing);
  const additions = [];
  for (const pattern of patterns) {
    if (pattern.startsWith("!")) continue;
    if (lines2.has(pattern)) continue;
    const sample = samplePathFor(pattern);
    if (ignoreCovers(rules, sample.path, sample.isDir)) continue;
    additions.push(pattern);
    const rule = compileIgnorePattern(pattern);
    if (rule) rules.push(rule);
  }
  if (additions.length === 0) return [];
  const restated = patterns.filter((pattern) => {
    if (!pattern.startsWith("!")) return false;
    const sample = samplePathFor(pattern);
    return ignoreCovers(rules, sample.path, sample.isDir);
  });
  return [...additions, ...restated];
}
function anchoredIgnoreLine(relPath) {
  const escaped = relPath.replace(/[\\*?[\]]/g, (char) => `\\${char}`);
  return `/${escaped.replace(/ $/, "\\ ")}`;
}
async function appendIgnorePatterns(root, patterns) {
  const existing = await readTextAt(root, ".gitignore");
  const block = ignoreBlockFor(existing ?? "", patterns);
  if (block.length === 0) return refuse(".gitignore already covers all of these — nothing was changed.");
  if (existing === null) {
    return createFile(root, ".gitignore", `${TERMINALDECK_BLOCK_HEADER}
${block.join("\n")}
`);
  }
  const separator = existing.endsWith("\n") ? "" : "\n";
  await promises.writeFile(
    safeJoin(root, ".gitignore"),
    `${existing}${separator}
${TERMINALDECK_BLOCK_HEADER}
${block.join("\n")}
`,
    "utf8"
  );
  return ok(`Added ${block.length} pattern${block.length === 1 ? "" : "s"} to .gitignore.`, [".gitignore"]);
}
function detectJsonIndent(text2) {
  const match = /\n([ \t]+)"/.exec(text2);
  return match ? match[1] : "  ";
}
async function addScript(root, runner) {
  const pkg = await readPackageJson$1(root);
  if (pkg === null) return refuse("package.json is missing or unreadable — nothing was changed.");
  if (pkg.scripts[runner.script] !== void 0) {
    return refuse(`package.json already defines a "${runner.script}" script — nothing was changed.`);
  }
  const parsed = JSON.parse(pkg.raw);
  const scripts = { ...stringMap$1(parsed.scripts), [runner.script]: runner.command };
  const next = { ...parsed, scripts };
  const indent = detectJsonIndent(pkg.raw);
  const trailing = pkg.raw.endsWith("\n") ? "\n" : "";
  await promises.writeFile(safeJoin(root, "package.json"), `${JSON.stringify(next, null, indent)}${trailing}`, "utf8");
  return ok(`Added "${runner.script}": "${runner.command}" to package.json.`, ["package.json"]);
}
async function applyReadinessFix(projectPath2, fixId) {
  const root = projectPath2;
  switch (fixId) {
    case "create-claude-md":
      return createFile(root, "CLAUDE.md", CLAUDE_MD_TEMPLATE, TEMPLATE_NOTE);
    case "create-readme":
      return createFile(root, "README.md", readmeTemplate(basenameOf(root)), TEMPLATE_NOTE);
    case "create-gitignore":
      return await readTextAt(root, ".gitignore") === null ? createFile(root, ".gitignore", GITIGNORE_TEMPLATE) : refuse('.gitignore already exists — use "Add missing patterns" instead.');
    case "patch-gitignore": {
      const pkg = await readPackageJson$1(root);
      const wanted = await essentialPatterns(root, pkg);
      const patterns = wanted.flatMap(
        (entry) => entry === ".env" ? SECRET_IGNORE_PATTERNS : [`${entry}/`]
      );
      return appendIgnorePatterns(root, patterns);
    }
    case "ignore-secrets":
      return appendIgnorePatterns(root, SECRET_IGNORE_PATTERNS);
    case "git-init": {
      if (await findGitDir(root) !== null) return refuse("This folder is already a git repository.");
      await git(root, ["init"], { write: true });
      return ok("Initialised an empty git repository. Nothing was staged or committed.", [".git"]);
    }
    case "untrack-secrets": {
      const tracked = await trackedFiles(root);
      if (tracked === null) return refuse("git could not list this folder — nothing was changed.");
      const secrets = await secretPathsAmong(root, tracked);
      if (secrets.length === 0) return refuse("git is no longer tracking any secret files.");
      const ignored2 = await appendIgnorePatterns(root, [
        ...SECRET_IGNORE_PATTERNS,
        ...secrets.map(anchoredIgnoreLine)
      ]);
      for (let i = 0; i < secrets.length; i += RM_BATCH) {
        await git(root, ["rm", "--cached", "--quiet", "--", ...secrets.slice(i, i + RM_BATCH)], {
          write: true
        });
      }
      return ok(
        `Untracked ${secrets.length} file${secrets.length === 1 ? "" : "s"} and ignored ${secrets.length === 1 ? "it" : "them"}. The files are still on disk. They remain in every past commit — rotate those credentials.`,
        [...ignored2.ok ? [".gitignore"] : [], ...secrets]
      );
    }
    case "add-test-script": {
      const pkg = await readPackageJson$1(root);
      const runner = pkg && detectTestRunner(pkg.deps);
      if (!runner) return refuse("No test runner found in the dependencies — nothing was changed.");
      return addScript(root, runner);
    }
    case "add-typecheck-script": {
      const pkg = await readPackageJson$1(root);
      if (!pkg?.deps.typescript) return refuse("TypeScript is not a dependency here — nothing was changed.");
      return addScript(root, { script: "typecheck", command: "tsc --noEmit" });
    }
    case "add-lint-script": {
      const pkg = await readPackageJson$1(root);
      const linter = pkg && detectLinter(pkg.deps);
      if (!linter) return refuse("No linter found in the dependencies — nothing was changed.");
      return addScript(root, linter);
    }
    default:
      return refuse("Unknown fix.");
  }
}
function basenameOf(path) {
  const trimmed = path.replace(/[/\\]+$/, "");
  const cut = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return cut === -1 ? trimmed : trimmed.slice(cut + 1);
}
const FIX_IDS = /* @__PURE__ */ new Set([
  "create-claude-md",
  "create-readme",
  "create-gitignore",
  "patch-gitignore",
  "git-init",
  "ignore-secrets",
  "untrack-secrets",
  "add-test-script",
  "add-typecheck-script",
  "add-lint-script"
]);
function asProjectPath(value) {
  if (typeof value !== "string" || value === "" || value.includes("\0")) return null;
  return node_path.isAbsolute(value) ? value : null;
}
function registerReadinessIpc(ipcMain) {
  ipcMain.handle("readiness:scan", async (_event, projectPath2) => {
    const root = asProjectPath(projectPath2);
    if (root === null) throw new Error("readiness: an absolute project path is required");
    return scanReadiness(root);
  });
  ipcMain.handle("readiness:fix", async (_event, projectPath2, fixId) => {
    const root = asProjectPath(projectPath2);
    if (root === null) throw new Error("readiness: an absolute project path is required");
    if (typeof fixId !== "string" || !FIX_IDS.has(fixId)) {
      return refuse("That fix is not one this version knows how to apply.");
    }
    try {
      return await applyReadinessFix(root, fixId);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return refuse(`The fix could not be applied: ${message}`);
    }
  });
}
const MAX_LAYOUT_BYTES = 512 * 1024;
const MAX_WIDGETS = 200;
function dashboardFileName(projectPath2) {
  const canonical = node_path.resolve(projectPath2);
  const slug2 = node_path.basename(canonical).replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 40);
  const hash2 = node_crypto.createHash("sha256").update(canonical).digest("hex").slice(0, 10);
  return `${slug2 || "project"}-${hash2}.json`;
}
function dashboardsDir() {
  return node_path.join(electron.app.getPath("userData"), "dashboards");
}
function dashboardFilePath(projectPath2) {
  return node_path.join(dashboardsDir(), dashboardFileName(projectPath2));
}
function assertProjectPath(projectPath2) {
  if (typeof projectPath2 !== "string" || !node_path.isAbsolute(projectPath2)) {
    throw new Error("dashboard: an absolute project path is required");
  }
}
function isLayoutLike(value) {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value;
  return Array.isArray(candidate.widgets) && candidate.widgets.length <= MAX_WIDGETS;
}
function loadDashboard(projectPath2) {
  assertProjectPath(projectPath2);
  const file = dashboardFilePath(projectPath2);
  try {
    const { size } = node_fs.statSync(file);
    if (size > MAX_LAYOUT_BYTES) {
      console.error(`[dashboard] ignoring an oversized layout file (${size} bytes):`, file);
      return null;
    }
    return JSON.parse(node_fs.readFileSync(file, "utf8"));
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.error("[dashboard] unreadable layout, falling back to the default:", err);
    }
    return null;
  }
}
function saveDashboard(projectPath2, layout) {
  assertProjectPath(projectPath2);
  if (!isLayoutLike(layout)) {
    throw new Error("dashboard: refusing to save a payload that is not a layout");
  }
  const json = JSON.stringify({ ...layout, projectPath: projectPath2 }, null, 2);
  if (Buffer.byteLength(json, "utf8") > MAX_LAYOUT_BYTES) {
    throw new Error("dashboard: payload too large to save");
  }
  const file = dashboardFilePath(projectPath2);
  const tmp = `${file}.${process.pid}.tmp`;
  node_fs.mkdirSync(dashboardsDir(), { recursive: true });
  try {
    node_fs.writeFileSync(tmp, json, "utf8");
    node_fs.renameSync(tmp, file);
  } catch (err) {
    try {
      node_fs.unlinkSync(tmp);
    } catch {
    }
    throw err;
  }
}
function clearDashboard(projectPath2) {
  assertProjectPath(projectPath2);
  try {
    node_fs.unlinkSync(dashboardFilePath(projectPath2));
  } catch (err) {
    if (err.code !== "ENOENT") throw err;
  }
}
function registerDashboardIpc(ipcMain) {
  ipcMain.handle("dashboard:load", (_e, projectPath2) => loadDashboard(projectPath2));
  ipcMain.handle("dashboard:save", (_e, projectPath2, layout) => {
    saveDashboard(projectPath2, layout);
  });
  ipcMain.handle("dashboard:clear", (_e, projectPath2) => {
    clearDashboard(projectPath2);
  });
}
const SESSION_SEARCH_CHANNEL = "session-search:run";
const SESSION_SEARCH_CANCEL_CHANNEL = "session-search:cancel";
const CHUNK_BYTES = 4 * 1024 * 1024;
const MAX_LINE_BYTES = 8 * 1024 * 1024;
const MAX_BLOCK_CHARS = 12e4;
const MAX_MATCHES_PER_BLOCK = 50;
const MAX_COUNTED_PER_TERM = 200;
const DEADLINE_CHECK_LINES = 512;
const DEFAULT_MAX_HITS = 200;
const MAX_MAX_HITS = 1e3;
const DEFAULT_MAX_HITS_PER_SESSION = 6;
const DEFAULT_MAX_SESSIONS = 80;
const MAX_MAX_SESSIONS = 600;
const DEFAULT_MAX_AGE_MS = 365 * 24 * 60 * 60 * 1e3;
const DEFAULT_TIME_BUDGET_MS = 12e3;
const MIN_QUERY_CHARS = 2;
const SNIPPET_LEAD = 90;
const SNIPPET_TRAIL = 220;
const SNIPPET_MAX_CHARS = 260;
const ALL_ROLES = ["user", "assistant", "thinking", "tool", "system"];
const DEFAULT_ROLES = ["user", "assistant"];
function escapeRegExp$1(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function classEnd(source, start) {
  let i = start + 1;
  if (source[i] === "^") i += 1;
  if (source[i] === "]") i += 1;
  while (i < source.length && source[i] !== "]") {
    if (source[i] === "\\") i += 1;
    i += 1;
  }
  return i + 1;
}
function quantifierAt(source, index) {
  const ch = source[index];
  if (ch === "*" || ch === "+") return { length: 1, unbounded: true };
  if (ch === "?") return { length: 1, unbounded: false };
  if (ch !== "{") return { length: 0, unbounded: false };
  const close = source.indexOf("}", index);
  if (close === -1) return { length: 0, unbounded: false };
  const body = source.slice(index + 1, close);
  if (!/^\d*(,\d*)?$/.test(body) || body === "") return { length: 0, unbounded: false };
  return { length: close - index + 1, unbounded: /,\s*$/.test(body) };
}
function repeatsUnbounded(fragment) {
  let i = 0;
  while (i < fragment.length) {
    const ch = fragment[i];
    if (ch === "\\") {
      i += 2;
      continue;
    }
    if (ch === "[") {
      i = classEnd(fragment, i);
      continue;
    }
    if (ch === "*" || ch === "+") return true;
    if (ch === "{") {
      const quant = quantifierAt(fragment, i);
      if (quant.unbounded) return true;
      i += Math.max(1, quant.length);
      continue;
    }
    i += 1;
  }
  return false;
}
function hasNestedRepeat(source) {
  const opens = [];
  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    if (ch === "\\") {
      i += 2;
      continue;
    }
    if (ch === "[") {
      i = classEnd(source, i);
      continue;
    }
    if (ch === "(") {
      opens.push(i);
      i += 1;
      continue;
    }
    if (ch === ")") {
      const start = opens.pop();
      i += 1;
      if (start === void 0) continue;
      const quant = quantifierAt(source, i);
      if (quant.unbounded && repeatsUnbounded(source.slice(start + 1, i - 1))) return true;
      i += quant.length;
      continue;
    }
    i += 1;
  }
  return false;
}
function tokenizeQuery(raw) {
  const tokens = [];
  let i = 0;
  while (i < raw.length) {
    while (i < raw.length && /\s/.test(raw[i])) i += 1;
    if (i >= raw.length) break;
    let negated = false;
    if (raw[i] === "-" && i + 1 < raw.length && !/\s/.test(raw[i + 1])) {
      negated = true;
      i += 1;
    }
    let phrase = false;
    let text2 = "";
    if (raw[i] === '"') {
      phrase = true;
      i += 1;
      while (i < raw.length && raw[i] !== '"') {
        text2 += raw[i];
        i += 1;
      }
      if (i < raw.length) i += 1;
    } else {
      while (i < raw.length && !/\s/.test(raw[i])) {
        text2 += raw[i];
        i += 1;
      }
    }
    if (!phrase && text2 === "-") continue;
    if (text2.length > 0) tokens.push({ text: text2, negated, phrase });
  }
  return tokens;
}
const PREFILTER_SAFE = /^[A-Za-z0-9_.\-/]+$/;
function rawLinePrefilter(include, caseSensitive) {
  const candidates = include.filter((term) => PREFILTER_SAFE.test(term.text)).sort((a, b) => b.text.length - a.text.length);
  const best = candidates[0];
  if (!best) return null;
  return new RegExp(escapeRegExp$1(best.text), caseSensitive ? "" : "i");
}
function parseQuery(raw, options = {}) {
  const caseSensitive = options.caseSensitive === true;
  const flags = caseSensitive ? "g" : "gi";
  const trimmed = raw.trim();
  if (trimmed.length < MIN_QUERY_CHARS) {
    return {
      ok: false,
      error: "query-too-short",
      message: `Type at least ${MIN_QUERY_CHARS} characters.`
    };
  }
  if (options.regex === true) {
    try {
      const pattern = new RegExp(trimmed, flags);
      if (hasNestedRepeat(trimmed)) {
        return {
          ok: false,
          error: "unsafe-regex",
          message: "That pattern repeats inside a repeat (like `(a+)+`), which can take hours on one line. Rewrite it without the inner repeat."
        };
      }
      return {
        ok: true,
        query: {
          include: [{ text: trimmed, phrase: false, pattern }],
          exclude: [],
          // A regex cannot be substring-tested against the raw line.
          prefilter: null
        }
      };
    } catch (error) {
      return {
        ok: false,
        error: "invalid-regex",
        message: error instanceof Error ? error.message : "Not a valid regular expression."
      };
    }
  }
  const include = [];
  const exclude = [];
  for (const token2 of tokenizeQuery(trimmed)) {
    const term = {
      text: token2.text,
      phrase: token2.phrase,
      pattern: new RegExp(escapeRegExp$1(token2.text), flags)
    };
    if (token2.negated) exclude.push(term);
    else include.push(term);
  }
  if (include.length === 0) {
    return {
      ok: false,
      error: "query-too-short",
      message: "Add something to search for, not only exclusions."
    };
  }
  return { ok: true, query: { include, exclude, prefilter: rawLinePrefilter(include, caseSensitive) } };
}
function isRecord$3(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function str$1(value) {
  return typeof value === "string" && value.length > 0 ? value : void 0;
}
function clip(text2) {
  return text2.length > MAX_BLOCK_CHARS ? text2.slice(0, MAX_BLOCK_CHARS) : text2;
}
function toolResultText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts = [];
  for (const block of content) {
    if (!isRecord$3(block)) continue;
    if (str$1(block.type) === "text") {
      const text2 = str$1(block.text);
      if (text2) parts.push(text2);
    }
  }
  return parts.join("\n");
}
function parseSearchLine(line) {
  const trimmed = line.trim();
  if (trimmed.length === 0) return null;
  let raw;
  try {
    raw = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (!isRecord$3(raw)) return null;
  if (raw.isMeta === true) return null;
  const type = str$1(raw.type);
  if (!type) return null;
  const parsed = {
    at: typeof raw.timestamp === "string" ? Date.parse(raw.timestamp) || 0 : 0,
    sessionId: str$1(raw.sessionId),
    cwd: str$1(raw.cwd),
    isSidechain: raw.isSidechain === true,
    blocks: []
  };
  if (type === "system") {
    const content2 = str$1(raw.content);
    if (!content2) return null;
    parsed.blocks.push({ role: "system", text: clip(content2) });
    return parsed;
  }
  if (type !== "user" && type !== "assistant") return null;
  const message = isRecord$3(raw.message) ? raw.message : void 0;
  if (!message) return null;
  const content = message.content;
  if (typeof content === "string") {
    if (content.length === 0) return null;
    parsed.blocks.push({ role: type === "user" ? "user" : "assistant", text: clip(content) });
    return parsed;
  }
  if (!Array.isArray(content)) return null;
  for (const block of content) {
    if (!isRecord$3(block)) continue;
    switch (str$1(block.type)) {
      case "text": {
        const text2 = str$1(block.text);
        if (text2) parsed.blocks.push({ role: type === "user" ? "user" : "assistant", text: clip(text2) });
        break;
      }
      case "thinking": {
        const text2 = str$1(block.thinking);
        if (text2) parsed.blocks.push({ role: "thinking", text: clip(text2) });
        break;
      }
      case "tool_use": {
        const name = str$1(block.name) ?? "tool";
        let args = "";
        try {
          args = block.input === void 0 ? "" : JSON.stringify(block.input);
        } catch {
          args = "";
        }
        parsed.blocks.push({ role: "tool", text: clip(`${name} ${args}`.trim()), tool: name });
        break;
      }
      case "tool_result": {
        const text2 = toolResultText(block.content);
        if (text2) parsed.blocks.push({ role: "tool", text: clip(text2) });
        break;
      }
    }
  }
  return parsed.blocks.length > 0 ? parsed : null;
}
function mayCarryText(line) {
  return line.includes('"message"') || line.includes('"content"');
}
function findMatches(text2, pattern, out, limit) {
  pattern.lastIndex = 0;
  let found = 0;
  const ceiling = out.length + Math.max(1, limit);
  for (; ; ) {
    const match = pattern.exec(text2);
    if (!match) break;
    found += 1;
    if (out.length < ceiling) {
      out.push({ start: match.index, length: match[0].length });
    }
    if (match[0].length === 0) pattern.lastIndex += 1;
    if (found >= MAX_COUNTED_PER_TERM) break;
  }
  return found;
}
const WORD_CHAR = /[A-Za-z0-9_]/;
function atWordBoundary(text2, range) {
  const before = range.start > 0 ? text2[range.start - 1] : "";
  const after = text2[range.start + range.length] ?? "";
  return (before === "" || !WORD_CHAR.test(before)) && (after === "" || !WORD_CHAR.test(after));
}
function condense(window, ranges) {
  const map = new Array(window.length + 1);
  let out = "";
  let pendingSpace = false;
  for (let i = 0; i < window.length; i += 1) {
    map[i] = out.length;
    const ch = window[i];
    if (ch === " " || ch === "	" || ch === "\n" || ch === "\r" || ch === "\f" || ch === "\v") {
      if (out.length > 0) pendingSpace = true;
      continue;
    }
    if (pendingSpace) {
      out += " ";
      pendingSpace = false;
      map[i] = out.length;
    }
    out += ch;
  }
  map[window.length] = out.length;
  const moved = [];
  for (const range of ranges) {
    const start = map[Math.max(0, Math.min(window.length, range.start))];
    const end = map[Math.max(0, Math.min(window.length, range.start + range.length))];
    if (end > start) moved.push({ start, length: end - start });
  }
  return { text: out, ranges: moved };
}
function buildSnippet(text2, ranges, anchor) {
  const first = anchor ?? ranges[0];
  if (!first) {
    const whole2 = condense(text2.slice(0, SNIPPET_LEAD + SNIPPET_TRAIL), []);
    return {
      text: whole2.text.slice(0, SNIPPET_MAX_CHARS),
      ranges: [],
      truncatedStart: false,
      truncatedEnd: whole2.text.length > SNIPPET_MAX_CHARS || text2.length > SNIPPET_LEAD + SNIPPET_TRAIL
    };
  }
  const start = Math.max(0, first.start - SNIPPET_LEAD);
  const end = Math.min(text2.length, first.start + first.length + SNIPPET_TRAIL);
  const window = text2.slice(start, end);
  const local = ranges.filter((range) => range.start >= start && range.start + range.length <= end).map((range) => ({ start: range.start - start, length: range.length }));
  const collapsed = condense(window, local);
  let body = collapsed.text;
  let kept = collapsed.ranges;
  let truncatedEnd = end < text2.length;
  if (body.length > SNIPPET_MAX_CHARS) {
    body = body.slice(0, SNIPPET_MAX_CHARS);
    truncatedEnd = true;
    kept = kept.filter((range) => range.start < body.length).map((range) => ({ start: range.start, length: Math.min(range.length, body.length - range.start) }));
  }
  return { text: body, ranges: kept, truncatedStart: start > 0, truncatedEnd };
}
const ROLE_WEIGHT = {
  user: 4,
  assistant: 3,
  thinking: 1.5,
  tool: 1,
  system: 0.75
};
const RECENCY_HALF_LIFE_MS = 14 * 24 * 60 * 60 * 1e3;
const RECENCY_WEIGHT = 2;
function scoreHit(input) {
  const coverage = input.termsTotal > 0 ? input.termsMatched / input.termsTotal : 0;
  let score = ROLE_WEIGHT[input.role] * coverage;
  if (input.phraseHit) score += 1.5;
  if (input.wordBoundaryHit) score += 0.75;
  score += Math.min(2, Math.log2(1 + input.matches));
  if (input.at > 0 && input.now > input.at) {
    score += RECENCY_WEIGHT * Math.pow(0.5, (input.now - input.at) / RECENCY_HALF_LIFE_MS);
  } else if (input.at > 0) {
    score += RECENCY_WEIGHT;
  }
  if (input.isSidechain) score *= 0.8;
  return score;
}
class SearchAborted extends Error {
  constructor() {
    super("session search aborted");
    this.name = "AbortError";
  }
}
function isAbortError(error) {
  return error instanceof Error && error.name === "AbortError";
}
function clamp(value, fallback, max) {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return fallback;
  return Math.min(Math.floor(value), max);
}
async function* streamLines(path, signal) {
  let size;
  try {
    const info = await promises.stat(path);
    if (!info.isFile()) return;
    size = info.size;
  } catch {
    return;
  }
  const handle2 = await promises.open(path, "r");
  const decoder = new node_string_decoder.StringDecoder("utf8");
  let offset = 0;
  let partial = "";
  try {
    while (offset < size) {
      if (signal?.aborted) throw new SearchAborted();
      const length = Math.min(CHUNK_BYTES, size - offset);
      const buffer = Buffer.allocUnsafe(length);
      const { bytesRead } = await handle2.read(buffer, 0, length, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
      const text2 = partial + decoder.write(buffer.subarray(0, bytesRead));
      const lines2 = text2.split("\n");
      partial = lines2.pop() ?? "";
      if (partial.length > MAX_LINE_BYTES) partial = "";
      for (const line of lines2) yield line;
    }
  } finally {
    await handle2.close();
  }
  if (partial.length > 0) yield partial;
}
async function searchTranscript(file, query, roles, options) {
  const hits = [];
  const clock = options.clock ?? Date.now;
  const perTerm = Math.max(1, Math.floor(MAX_MATCHES_PER_BLOCK / Math.max(1, query.include.length)));
  let bytes2 = 0;
  let cwd = "";
  let lines2 = 0;
  let timedOut = false;
  for await (const line of streamLines(file.path, options.signal)) {
    bytes2 += line.length + 1;
    lines2 += 1;
    if (options.deadline !== void 0 && lines2 % DEADLINE_CHECK_LINES === 0 && clock() > options.deadline) {
      timedOut = true;
      break;
    }
    if (!mayCarryText(line)) continue;
    if (query.prefilter && !query.prefilter.test(line)) continue;
    const parsed = parseSearchLine(line);
    if (!parsed) continue;
    if (parsed.cwd && !cwd) cwd = parsed.cwd;
    for (const block of parsed.blocks) {
      if (!roles.has(block.role)) continue;
      let excluded = false;
      for (const term of query.exclude) {
        term.pattern.lastIndex = 0;
        if (term.pattern.test(block.text)) {
          excluded = true;
          break;
        }
      }
      if (excluded) continue;
      const ranges = [];
      let termsMatched = 0;
      let matches = 0;
      let phraseHit = false;
      let anchor;
      let rarest = Number.POSITIVE_INFINITY;
      for (const term of query.include) {
        const before = ranges.length;
        const found = findMatches(block.text, term.pattern, ranges, perTerm);
        if (found === 0) {
          termsMatched = 0;
          break;
        }
        termsMatched += 1;
        matches += found;
        if (term.phrase) phraseHit = true;
        if (found < rarest && ranges.length > before) {
          rarest = found;
          anchor = ranges[before];
        }
      }
      if (termsMatched !== query.include.length) continue;
      ranges.sort((a, b) => a.start - b.start);
      const wordBoundaryHit = ranges.some((range) => atWordBoundary(block.text, range));
      hits.push({
        sessionId: file.sessionId,
        transcriptPath: file.path,
        cwd,
        projectName: cwd ? node_path.basename(cwd) : "",
        at: parsed.at > 0 ? parsed.at : file.modifiedAt,
        role: block.role,
        tool: block.tool,
        isSidechain: parsed.isSidechain,
        matches,
        score: scoreHit({
          role: block.role,
          termsMatched,
          termsTotal: query.include.length,
          matches,
          phraseHit,
          wordBoundaryHit,
          at: parsed.at > 0 ? parsed.at : file.modifiedAt,
          now: options.now,
          isSidechain: parsed.isSidechain
        }),
        snippet: buildSnippet(block.text, ranges, anchor)
      });
    }
    if (hits.length > options.maxHits * 4) {
      hits.sort((a, b) => b.score - a.score);
      hits.length = options.maxHits;
    }
  }
  hits.sort((a, b) => b.score - a.score);
  if (hits.length > options.maxHits) hits.length = options.maxHits;
  if (cwd) {
    for (const hit of hits) {
      if (!hit.cwd) {
        hit.cwd = cwd;
        hit.projectName = node_path.basename(cwd);
      }
    }
  }
  return { hits, bytes: bytes2, timedOut };
}
async function allTranscriptDirs(configDir) {
  const root = node_path.join(configDir, "projects");
  let names;
  try {
    names = await promises.readdir(root);
  } catch {
    return [];
  }
  return names.map((name) => node_path.join(root, name)).sort();
}
async function collectFiles(cwd, scope, configDir, cutoff, stop) {
  if (scope === "project") {
    return (await listTranscripts(transcriptDir(cwd, configDir))).filter(
      (file) => file.modifiedAt >= cutoff
    );
  }
  const dirs = await allTranscriptDirs(configDir);
  const files = [];
  for (const dir of dirs) {
    if (stop?.()) break;
    for (const file of await listTranscripts(dir)) {
      if (file.modifiedAt >= cutoff) files.push(file);
    }
  }
  return files.sort((a, b) => b.modifiedAt - a.modifiedAt);
}
async function searchSessions(cwd, rawQuery, options = {}) {
  const parsed = parseQuery(rawQuery, options);
  if (!parsed.ok) return { error: parsed.error, message: parsed.message };
  const clock = options.clock ?? Date.now;
  const startedAt = clock();
  const now = options.now ?? Date.now();
  const scope = options.scope === "all" ? "all" : "project";
  const configDir = options.configDir ?? claudeConfigDir();
  const maxHits = clamp(options.maxHits, DEFAULT_MAX_HITS, MAX_MAX_HITS);
  const perSession = clamp(options.maxHitsPerSession, DEFAULT_MAX_HITS_PER_SESSION, maxHits);
  const maxSessions = clamp(options.maxSessions, DEFAULT_MAX_SESSIONS, MAX_MAX_SESSIONS);
  const maxAge = options.maxAgeMs === 0 ? 0 : clamp(options.maxAgeMs, DEFAULT_MAX_AGE_MS, Number.MAX_SAFE_INTEGER);
  const budget = clamp(options.timeBudgetMs, DEFAULT_TIME_BUDGET_MS, 12e4);
  const roles = new Set(options.roles && options.roles.length > 0 ? options.roles : DEFAULT_ROLES);
  const cutoff = maxAge > 0 ? now - maxAge : 0;
  const deadline = startedAt + budget;
  const stop = () => options.signal?.aborted === true || clock() > deadline;
  const hits = [];
  let all = [];
  let sessionsScanned = 0;
  let bytesScanned = 0;
  let totalHits = 0;
  let truncated = false;
  let cancelled = false;
  try {
    all = await collectFiles(node_path.resolve(cwd), scope, configDir, cutoff, stop);
    if (options.signal?.aborted) throw new SearchAborted();
    const files = all.slice(0, maxSessions);
    truncated = all.length > files.length;
    for (const file of files) {
      if (options.signal?.aborted) throw new SearchAborted();
      if (clock() > deadline) {
        truncated = true;
        break;
      }
      const found = await searchTranscript(file, parsed.query, roles, {
        maxHits: perSession,
        now,
        signal: options.signal,
        deadline,
        clock
      });
      sessionsScanned += 1;
      bytesScanned += found.bytes;
      totalHits += found.hits.length;
      hits.push(...found.hits);
      if (found.timedOut) {
        truncated = true;
        break;
      }
    }
  } catch (error) {
    if (!isAbortError(error)) throw error;
    cancelled = true;
  }
  hits.sort((a, b) => b.score - a.score || b.at - a.at);
  if (hits.length > maxHits) {
    hits.length = maxHits;
    truncated = true;
  }
  return {
    query: rawQuery,
    scope,
    hits,
    sessionsScanned,
    sessionsSkipped: Math.max(0, all.length - sessionsScanned),
    bytesScanned,
    totalHits,
    truncated,
    cancelled,
    tookMs: clock() - startedAt
  };
}
function projectPath(cwd) {
  if (typeof cwd !== "string" || cwd.trim().length === 0) {
    throw new Error("session-search: a project path is required");
  }
  const resolved = node_path.resolve(cwd);
  if (resolved === node_path.sep) throw new Error("session-search: refusing to search the filesystem root");
  return resolved;
}
function roleList(value) {
  if (!Array.isArray(value)) return void 0;
  const roles = value.filter(
    (role) => typeof role === "string" && ALL_ROLES.includes(role)
  );
  return roles.length > 0 ? roles : void 0;
}
function registerSessionSearchIpc(ipcMain) {
  const inFlight2 = /* @__PURE__ */ new Map();
  const watched = /* @__PURE__ */ new Set();
  const cancelFor = (senderId) => {
    inFlight2.get(senderId)?.abort();
    inFlight2.delete(senderId);
  };
  ipcMain.handle(
    SESSION_SEARCH_CHANNEL,
    async (event, request) => {
      const payload = request ?? {};
      let cwd;
      try {
        cwd = projectPath(payload.cwd);
      } catch (error) {
        return {
          ok: false,
          error: "invalid-project",
          message: error instanceof Error ? error.message : "Invalid project path."
        };
      }
      const senderId = event.sender.id;
      cancelFor(senderId);
      const controller = new AbortController();
      inFlight2.set(senderId, controller);
      if (!watched.has(senderId)) {
        watched.add(senderId);
        event.sender.once("destroyed", () => {
          cancelFor(senderId);
          watched.delete(senderId);
        });
      }
      try {
        const result = await searchSessions(cwd, typeof payload.query === "string" ? payload.query : "", {
          scope: payload.scope === "all" ? "all" : "project",
          roles: roleList(payload.roles),
          caseSensitive: payload.caseSensitive === true,
          regex: payload.regex === true,
          maxHits: payload.maxHits,
          maxSessions: payload.maxSessions,
          signal: controller.signal
        });
        if ("error" in result) return { ok: false, error: result.error, message: result.message };
        if (result.cancelled) return { ok: false, error: "cancelled", message: "Search cancelled." };
        return { ok: true, ...result };
      } catch (error) {
        if (isAbortError(error)) return { ok: false, error: "cancelled", message: "Search cancelled." };
        console.error("[session-search] failed:", error);
        return { ok: false, error: "failed", message: "Search failed. See the main-process log." };
      } finally {
        if (inFlight2.get(senderId) === controller) inFlight2.delete(senderId);
      }
    }
  );
  ipcMain.handle(SESSION_SEARCH_CANCEL_CHANNEL, (event) => {
    cancelFor(event.sender.id);
  });
}
const ALERTS_CHANNEL = "alerts:project";
const BLOCKED_WARNING_MS = 10 * 60 * 1e3;
const BLOCKED_CRITICAL_MS = 45 * 60 * 1e3;
const EXPENSIVE_MIN_SAMPLE = 5;
const EXPENSIVE_MULTIPLE = 3;
const EXPENSIVE_SEVERE_MULTIPLE = 6;
const EXPENSIVE_MIN_USD = 1;
const DIRTY_TREE_SESSION_STREAK = 3;
const DIRTY_TREE_CRITICAL_STREAK = 8;
const DIRTY_TREE_MIN_FILES = 1;
const SEVERITY_ORDER = { critical: 0, warning: 1, info: 2 };
function median(values) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}
function formatDuration(ms) {
  const minutes = Math.max(1, Math.round(ms / 6e4));
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? "" : "s"}`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? "" : "s"}`;
  const days = Math.round(hours / 24);
  return `${days} day${days === 1 ? "" : "s"}`;
}
function shortId(sessionId) {
  return sessionId.slice(0, 8);
}
function activeSessions(sessions2) {
  return sessions2.filter((session) => session.requests > 0);
}
function contextAlerts(input) {
  const active = activeSessions(input.sessions);
  if (active.length === 0) return [];
  const newest = [...active].sort((a, b) => b.lastActivityAt - a.lastActivityAt)[0];
  const alerts = [];
  if (newest.context) {
    const warning = contextWarning(newest.context);
    if (warning) {
      alerts.push({
        id: `context-bloat:${newest.sessionId}`,
        kind: "context-bloat",
        severity: warning.level,
        title: `Context ${Math.round(newest.context.percent)}% full`,
        detail: `${warning.message} Session ${shortId(newest.sessionId)} is holding ${formatTokens(
          newest.context.tokens
        )} of a ${formatTokens(newest.context.window)} window. Compacting now costs one request; letting it fill costs quality on every request until it does.`,
        sessionId: newest.sessionId,
        at: newest.lastActivityAt,
        action: { kind: "compact-session", label: "Compact this session", target: newest.sessionId }
      });
    }
  }
  const window = newest.context?.window ?? 0;
  const prefix = preContextWarning(newest.preContextTokens, window);
  if (prefix) {
    alerts.push({
      id: `pre-context-bloat:${newest.sessionId}`,
      kind: "pre-context-bloat",
      severity: prefix.level,
      title: "Every request starts heavy",
      detail: `${prefix.message} That prefix is re-sent on every turn of every session in this project, so trimming it is the one change that pays back more than once.`,
      sessionId: newest.sessionId,
      at: newest.lastActivityAt,
      action: { kind: "open-inspector", label: "Open the inspector", target: newest.transcriptPath }
    });
  }
  return alerts;
}
function blockedAlerts(input) {
  const alerts = [];
  for (const session of input.sessions) {
    if (session.status !== "input") continue;
    const since = session.statusSince ?? session.lastActivityAt;
    if (!since || since <= 0) continue;
    const waited = input.now - since;
    if (waited < BLOCKED_WARNING_MS) continue;
    alerts.push({
      id: `session-blocked:${session.sessionId}`,
      kind: "session-blocked",
      severity: waited >= BLOCKED_CRITICAL_MS ? "critical" : "warning",
      title: `Waiting on you for ${formatDuration(waited)}`,
      detail: `Session ${shortId(
        session.sessionId
      )} asked a question ${formatDuration(waited)} ago and has done nothing since. Nothing is running and nothing is being spent — it is simply stopped until you answer.`,
      sessionId: session.sessionId,
      at: since,
      action: { kind: "focus-session", label: "Go to the session", target: session.sessionId }
    });
  }
  return alerts;
}
function providerAlerts(input) {
  const alerts = [];
  const seen = /* @__PURE__ */ new Set();
  for (const provider of input.providersInUse) {
    if (provider === "shell" || seen.has(provider)) continue;
    seen.add(provider);
    if (input.providersInstalled[provider] !== false) continue;
    const spec = PROVIDERS[provider];
    if (!spec) continue;
    alerts.push({
      id: `provider-missing:${provider}`,
      kind: "provider-missing",
      severity: "critical",
      title: `${spec.label} is not installed`,
      detail: `This project is set up to run ${spec.label}, but \`${spec.bin}\` is not on the login shell's PATH. Sessions started with it will fail immediately.`,
      at: input.now,
      action: { kind: "install-provider", label: `Set up ${spec.label}`, target: provider }
    });
  }
  return alerts;
}
function expensiveSessionAlerts(input) {
  const priced = activeSessions(input.sessions).filter(
    (session) => typeof session.costUsd === "number" && session.costUsd > 0
  );
  if (priced.length < EXPENSIVE_MIN_SAMPLE) return [];
  const middle = median(priced.map((session) => session.costUsd));
  if (middle <= 0) return [];
  const alerts = [];
  const worst = [...priced].sort((a, b) => b.costUsd - a.costUsd)[0];
  const ratio = worst.costUsd / middle;
  if (ratio < EXPENSIVE_MULTIPLE || worst.costUsd < EXPENSIVE_MIN_USD) return alerts;
  alerts.push({
    id: `expensive-session:${worst.sessionId}`,
    kind: "expensive-session",
    severity: ratio >= EXPENSIVE_SEVERE_MULTIPLE && worst.costUsd >= EXPENSIVE_MIN_USD * 5 ? "warning" : "info",
    title: `One session cost ${ratio.toFixed(1)}x the usual`,
    detail: `Session ${shortId(worst.sessionId)} cost ${formatUsd(
      worst.costUsd
    )} against a median of ${formatUsd(
      middle
    )} across ${priced.length} priced sessions here. Worth a look at what it spent it on — usually a context that was never compacted, or a tool loop.`,
    sessionId: worst.sessionId,
    at: worst.lastActivityAt,
    action: { kind: "open-inspector", label: "See where it went", target: worst.transcriptPath }
  });
  return alerts;
}
function dirtyTreeAlerts(input) {
  const git2 = input.git;
  if (!git2 || !git2.repo || !git2.dirty) return [];
  if (git2.changedFiles < DIRTY_TREE_MIN_FILES) return [];
  if (git2.lastChangeAt === null || git2.lastChangeAt <= 0) return [];
  const since = activeSessions(input.sessions).filter(
    (session) => session.startedAt > (git2.lastChangeAt ?? 0)
  ).length;
  if (since < DIRTY_TREE_SESSION_STREAK) return [];
  return [
    {
      id: "dirty-tree",
      kind: "dirty-tree",
      severity: since >= DIRTY_TREE_CRITICAL_STREAK ? "warning" : "info",
      title: `${git2.changedFiles} file${git2.changedFiles === 1 ? "" : "s"} uncommitted across ${since} sessions`,
      detail: `The working tree has been dirty since before the last ${since} sessions started. Every one of them has been reading and rewriting on top of changes nothing can roll back to — commit or stash before the next one.`,
      at: git2.lastChangeAt,
      action: { kind: "open-git", label: "Open the git panel", target: input.projectPath }
    }
  ];
}
const RULES = [
  contextAlerts,
  blockedAlerts,
  providerAlerts,
  expensiveSessionAlerts,
  dirtyTreeAlerts
];
function deriveAlerts(input) {
  const alerts = [];
  for (const rule of RULES) alerts.push(...rule(input));
  alerts.sort(
    (a, b) => SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity] || b.at - a.at
  );
  const counts = { critical: 0, warning: 0, info: 0 };
  for (const alert of alerts) counts[alert.severity] += 1;
  return {
    projectPath: input.projectPath,
    alerts,
    counts,
    worst: alerts[0]?.severity ?? null,
    scannedAt: input.now
  };
}
const MAX_DIRTY_STATS = 400;
const STAT_BATCH = 32;
async function newestChangeAt(root, paths) {
  let newest = 0;
  const capped = paths.slice(0, MAX_DIRTY_STATS);
  for (let i = 0; i < capped.length; i += STAT_BATCH) {
    const batch = capped.slice(i, i + STAT_BATCH);
    const times = await Promise.all(
      batch.map(async (relative) => {
        const full = node_path.isAbsolute(relative) ? relative : node_path.join(root, relative);
        try {
          return (await promises.stat(full)).mtimeMs;
        } catch {
          return 0;
        }
      })
    );
    for (const time of times) if (time > newest) newest = time;
  }
  return newest > 0 ? newest : null;
}
async function withTimeout$1(work, ms, fallback) {
  let timer;
  try {
    return await Promise.race([
      work,
      new Promise((resolve2) => {
        timer = setTimeout(() => resolve2(fallback), ms);
      })
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
const GATHER_TIMEOUT_MS = 15e3;
function toAlertGit(status, lastChangeAt) {
  if (!status.repo) return { repo: false, dirty: false, changedFiles: 0, lastChangeAt: null };
  const changedFiles = status.staged.length + status.unstaged.length + status.untracked.length + status.conflicted.length;
  return { repo: true, dirty: !status.clean, changedFiles, lastChangeAt };
}
async function collectAlertInput(projectPath2, options = {}) {
  const now = options.now?.() ?? Date.now();
  const root = node_path.resolve(projectPath2);
  const cutoff = now - DEFAULT_MAX_AGE_MS$1;
  const files = (await listTranscripts(transcriptDir(root, options.configDir))).filter((file) => file.modifiedAt >= cutoff).slice(0, DEFAULT_MAX_SESSIONS$1);
  const live = options.liveSessions?.(root) ?? [];
  const sessions2 = [];
  for (const file of files) {
    let summary;
    try {
      summary = await readTranscript(file.path);
    } catch {
      continue;
    }
    sessions2.push({
      sessionId: summary.sessionId,
      transcriptPath: summary.transcriptPath,
      context: summary.context,
      preContextTokens: summary.preContextTokens,
      requests: summary.requests,
      // `unpricedModels` non-empty means the total is a floor, so it stays a
      // number; only a session with no priced model at all reports null.
      costUsd: Object.keys(summary.cost.byModel).length > 0 ? summary.cost.cost.total : null,
      startedAt: summary.startedAt,
      lastActivityAt: summary.lastActivityAt,
      // Never a live status: see the loop below for why the two cannot be joined.
      status: null
    });
  }
  for (const session of live) {
    sessions2.push({
      sessionId: session.sessionId,
      transcriptPath: "",
      context: null,
      preContextTokens: 0,
      requests: 0,
      costUsd: null,
      startedAt: session.statusSince ?? now,
      lastActivityAt: session.statusSince ?? now,
      status: session.status,
      statusSince: session.statusSince,
      provider: session.provider
    });
  }
  const providersInUse = [];
  for (const session of live) {
    if (session.provider && !providersInUse.includes(session.provider)) {
      providersInUse.push(session.provider);
    }
  }
  const preferred = options.defaultProvider?.(root);
  if (preferred && !providersInUse.includes(preferred)) providersInUse.push(preferred);
  const noProviders = {};
  const noGit = { repo: false, cwd: root, reason: "error", message: "git failed" };
  const [installed, gitStatus] = await Promise.all([
    // An empty map reads as "we could not look", which `providerAlerts` treats
    // as silence rather than as "nothing is installed".
    withTimeout$1(detectProviders().catch(() => noProviders), GATHER_TIMEOUT_MS, noProviders),
    withTimeout$1(readGitStatus(root).catch(() => noGit), GATHER_TIMEOUT_MS, noGit)
  ]);
  const dirtyPaths = gitStatus.repo ? [...gitStatus.staged, ...gitStatus.unstaged, ...gitStatus.untracked, ...gitStatus.conflicted].map(
    (file) => file.path
  ) : [];
  const lastChangeAt = gitStatus.repo ? await newestChangeAt(gitStatus.root, dirtyPaths) : null;
  return {
    projectPath: root,
    now,
    sessions: sessions2,
    providersInUse,
    providersInstalled: installed,
    git: toAlertGit(gitStatus, lastChangeAt)
  };
}
function projectPathOf(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error("alerts: a project path is required");
  }
  return node_path.resolve(value);
}
function registerAlertsIpc(ipcMain, options = {}) {
  const inFlight2 = /* @__PURE__ */ new Map();
  ipcMain.handle(
    ALERTS_CHANNEL,
    async (_event, projectPath2) => {
      const root = projectPathOf(projectPath2);
      const running = inFlight2.get(root);
      if (running) return running;
      const scan = collectAlertInput(root, options).then(deriveAlerts).finally(() => {
        inFlight2.delete(root);
      });
      inFlight2.set(root, scan);
      return scan;
    }
  );
}
function profileIsolation(platform, credentialsInConfigDir) {
  if (platform === "darwin") {
    return {
      store: "macos-keychain",
      isolated: true,
      note: "Logins are kept in the macOS Keychain under a name derived from this profile’s config directory, so profiles cannot overwrite each other’s login, and deleting this profile’s files does not sign it out."
    };
  }
  if (credentialsInConfigDir) {
    return {
      store: "config-directory",
      isolated: true,
      note: "This profile keeps its own credentials file inside its config directory, so its login is separate from the others — and deleting this profile’s files does sign it out."
    };
  }
  return {
    store: "unknown",
    isolated: false,
    note: platform === "win32" ? "Profile isolation is unverified on Windows. The config directory is redirected, but where the agent keeps its credentials there has not been checked, so two profiles may share one login until this one has been signed into at least once." : `Profile isolation is unverified on ${platform}. The config directory is redirected, but where the agent keeps its credentials there has not been checked, so two profiles may share one login until this one has been signed into at least once.`
  };
}
const SYSTEM_PROFILE_ID = "system";
const STATE_VERSION = 1;
const MAX_NAME_LENGTH = 60;
const PROFILE_COLORS = [
  "--accent",
  "--status-completed",
  "--status-waiting",
  "--status-input",
  "--color-warning",
  "--color-critical"
];
const EMPTY_STATE = {
  version: STATE_VERSION,
  profiles: [],
  defaultProfileId: null,
  projectDefaults: {}
};
class ProfileError extends Error {
  constructor(message) {
    super(message);
    this.name = "ProfileError";
  }
}
const WINDOWS_RESERVED_NAMES = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/;
function slugifyProfileId(name) {
  const slug2 = name.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32);
  if (slug2 === "") return "profile";
  return WINDOWS_RESERVED_NAMES.test(slug2) ? `${slug2}-profile` : slug2;
}
function uniqueProfileId(base, taken) {
  if (!taken.has(base) && base !== SYSTEM_PROFILE_ID) return base;
  for (let n = 2; n < 1e3; n++) {
    const candidate = `${base}-${n}`;
    if (!taken.has(candidate)) return candidate;
  }
  throw new ProfileError("could not allocate a profile id");
}
const CONTROL_CHARS = /[\p{Cc}\p{Cf}]/gu;
function normalizeProfileName(raw) {
  if (typeof raw !== "string") throw new ProfileError("a profile needs a name");
  const name = raw.replace(CONTROL_CHARS, " ").trim().replace(/\s+/g, " ");
  if (name === "") throw new ProfileError("a profile needs a name");
  if (name.length > MAX_NAME_LENGTH) {
    throw new ProfileError(`profile names are limited to ${MAX_NAME_LENGTH} characters`);
  }
  return name;
}
function canonicalProjectKey(projectPath2) {
  return node_path.resolve(projectPath2);
}
function userData() {
  return electron.app.getPath("userData");
}
function profilesRoot() {
  return node_path.join(userData(), "profiles");
}
function stateFile() {
  return node_path.join(userData(), "profiles.json");
}
function isManagedConfigDir(configDir, root = profilesRoot()) {
  if (typeof configDir !== "string" || configDir === "" || !node_path.isAbsolute(configDir)) return false;
  const rel = node_path.relative(node_path.resolve(root), node_path.resolve(configDir));
  if (rel === "" || rel === "..") return false;
  return !rel.startsWith(`..${node_path.sep}`) && !node_path.isAbsolute(rel);
}
function isProtectedDir(configDir) {
  const target2 = node_path.resolve(configDir);
  return target2 === node_path.resolve(node_os.homedir()) || target2 === node_path.resolve(claudeConfigDir()) || target2 === node_path.resolve(node_path.join(node_os.homedir(), ".claude")) || target2 === node_path.dirname(target2);
}
function systemProfile() {
  return {
    id: SYSTEM_PROFILE_ID,
    name: "Default",
    configDir: claudeConfigDir(),
    system: true,
    color: PROFILE_COLORS[0],
    createdAt: 0,
    lastUsedAt: null
  };
}
function sanitizeProfile(raw) {
  if (typeof raw !== "object" || raw === null) return null;
  const value = raw;
  if (typeof value.id !== "string" || value.id === "" || value.id === SYSTEM_PROFILE_ID) return null;
  if (typeof value.name !== "string" || value.name.trim() === "") return null;
  if (typeof value.configDir !== "string" || !node_path.isAbsolute(value.configDir)) return null;
  return {
    id: value.id,
    name: value.name,
    configDir: value.configDir,
    // Never trusted from disk: a persisted record claiming to be the system
    // profile would inherit the protections meant for the real one.
    system: false,
    color: typeof value.color === "string" ? value.color : PROFILE_COLORS[0],
    createdAt: typeof value.createdAt === "number" ? value.createdAt : Date.now(),
    lastUsedAt: typeof value.lastUsedAt === "number" ? value.lastUsedAt : null
  };
}
function sanitizeState(raw) {
  if (typeof raw !== "object" || raw === null) return structuredClone(EMPTY_STATE);
  const value = raw;
  const profiles = [];
  const seen = /* @__PURE__ */ new Set();
  if (Array.isArray(value.profiles)) {
    for (const entry of value.profiles) {
      const profile = sanitizeProfile(entry);
      if (!profile || seen.has(profile.id)) continue;
      seen.add(profile.id);
      profiles.push(profile);
    }
  }
  const projectDefaults = {};
  if (typeof value.projectDefaults === "object" && value.projectDefaults !== null) {
    for (const [path, id2] of Object.entries(value.projectDefaults)) {
      if (typeof id2 !== "string") continue;
      if (id2 !== SYSTEM_PROFILE_ID && !seen.has(id2)) continue;
      projectDefaults[canonicalProjectKey(path)] = id2;
    }
  }
  const defaultId = value.defaultProfileId;
  const defaultProfileId = typeof defaultId === "string" && (defaultId === SYSTEM_PROFILE_ID || seen.has(defaultId)) ? defaultId : null;
  return { version: STATE_VERSION, profiles, defaultProfileId, projectDefaults };
}
let cached = null;
const KNOWN_STATE_KEYS = /* @__PURE__ */ new Set([
  "version",
  "profiles",
  "defaultProfileId",
  "projectDefaults"
]);
let carriedForward$1 = {};
let backupBeforeWrite$1 = false;
function unknownStateKeys(raw) {
  const extras = {};
  for (const [key, value] of Object.entries(raw)) {
    if (!KNOWN_STATE_KEYS.has(key)) extras[key] = value;
  }
  return extras;
}
function getState() {
  if (cached) return cached;
  cached = structuredClone(EMPTY_STATE);
  carriedForward$1 = {};
  backupBeforeWrite$1 = false;
  let text2;
  try {
    text2 = node_fs.readFileSync(stateFile(), "utf8");
  } catch (cause) {
    backupBeforeWrite$1 = cause?.code !== "ENOENT";
    return cached;
  }
  let raw;
  try {
    raw = JSON.parse(text2);
  } catch {
    backupBeforeWrite$1 = true;
    return cached;
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    backupBeforeWrite$1 = true;
    return cached;
  }
  cached = sanitizeState(raw);
  carriedForward$1 = unknownStateKeys(raw);
  const version2 = raw.version;
  if (typeof version2 === "number" && version2 > STATE_VERSION) backupBeforeWrite$1 = true;
  return cached;
}
function persist$1(state) {
  const file = stateFile();
  node_fs.mkdirSync(node_path.dirname(file), { recursive: true });
  if (backupBeforeWrite$1) {
    try {
      node_fs.renameSync(file, `${file}.bak-${Date.now()}`);
    } catch {
    }
    backupBeforeWrite$1 = false;
  }
  const payload = {
    ...carriedForward$1,
    version: STATE_VERSION,
    profiles: state.profiles,
    defaultProfileId: state.defaultProfileId,
    projectDefaults: state.projectDefaults
  };
  const tmp = `${file}.tmp`;
  node_fs.writeFileSync(tmp, JSON.stringify(payload, null, 2), "utf8");
  node_fs.renameSync(tmp, file);
}
function knownProfileIds(state) {
  return /* @__PURE__ */ new Set([SYSTEM_PROFILE_ID, ...state.profiles.map((profile) => profile.id)]);
}
function resolveProfileId(state, input = {}) {
  const known = knownProfileIds(state);
  const projectDefault = typeof input.projectPath === "string" && input.projectPath !== "" ? state.projectDefaults[canonicalProjectKey(input.projectPath)] : void 0;
  for (const candidate of [input.sessionProfileId, projectDefault, state.defaultProfileId]) {
    if (typeof candidate === "string" && known.has(candidate)) return candidate;
  }
  return SYSTEM_PROFILE_ID;
}
function findProfile(state, id2) {
  if (id2 === SYSTEM_PROFILE_ID) return systemProfile();
  return state.profiles.find((profile) => profile.id === id2) ?? null;
}
function resolveProfile(state, input = {}) {
  return findProfile(state, resolveProfileId(state, input)) ?? systemProfile();
}
const CONFIG_DIR_ENV = {
  claude: "CLAUDE_CONFIG_DIR"
};
function sessionEnv(profile, provider) {
  const key = CONFIG_DIR_ENV[provider];
  if (!key || profile.system) return {};
  return { [key]: profile.configDir };
}
function adoptableConfigDir(state, raw) {
  if (typeof raw !== "string" || !node_path.isAbsolute(raw)) {
    throw new ProfileError("a config directory must be an absolute path");
  }
  const resolved = node_path.resolve(raw);
  if (isProtectedDir(resolved)) {
    throw new ProfileError(
      "that is your own Claude install — the default profile already uses it, and pointing a second profile at it would break the login"
    );
  }
  const clash = state.profiles.find((entry) => node_path.resolve(entry.configDir) === resolved);
  if (clash) {
    throw new ProfileError(`"${clash.name}" already uses that config directory`);
  }
  return resolved;
}
function listProfiles(state = getState()) {
  return [systemProfile(), ...state.profiles];
}
function createProfile(name, options = {}) {
  const state = getState();
  const clean2 = normalizeProfileName(name);
  if (listProfiles(state).some((profile2) => profile2.name.toLowerCase() === clean2.toLowerCase())) {
    throw new ProfileError(`a profile called "${clean2}" already exists`);
  }
  const id2 = uniqueProfileId(slugifyProfileId(clean2), knownProfileIds(state));
  const configDir = options.configDir !== void 0 ? adoptableConfigDir(state, options.configDir) : node_path.join(profilesRoot(), id2);
  node_fs.mkdirSync(configDir, { recursive: true });
  const profile = {
    id: id2,
    name: clean2,
    configDir,
    system: false,
    color: PROFILE_COLORS[state.profiles.length % PROFILE_COLORS.length],
    createdAt: Date.now(),
    lastUsedAt: null
  };
  state.profiles.push(profile);
  persist$1(state);
  return profile;
}
function renameProfile(id2, name) {
  const state = getState();
  if (id2 === SYSTEM_PROFILE_ID) throw new ProfileError("the default profile cannot be renamed");
  const profile = state.profiles.find((entry) => entry.id === id2);
  if (!profile) throw new ProfileError(`no profile with id ${id2}`);
  const clean2 = normalizeProfileName(name);
  const clash = listProfiles(state).some(
    (entry) => entry.id !== id2 && entry.name.toLowerCase() === clean2.toLowerCase()
  );
  if (clash) throw new ProfileError(`a profile called "${clean2}" already exists`);
  profile.name = clean2;
  persist$1(state);
  return profile;
}
function deleteProfile(id2, options = {}, platform = currentPlatform()) {
  const state = getState();
  if (id2 === SYSTEM_PROFILE_ID) {
    throw new ProfileError("the default profile is your own Claude install and cannot be deleted");
  }
  const index = state.profiles.findIndex((entry) => entry.id === id2);
  if (index === -1) throw new ProfileError(`no profile with id ${id2}`);
  const [profile] = state.profiles.splice(index, 1);
  const isolation = profileIsolation(
    platform,
    node_fs.existsSync(node_path.join(profile.configDir, ".credentials.json"))
  );
  if (state.defaultProfileId === id2) state.defaultProfileId = null;
  for (const [path, assigned] of Object.entries(state.projectDefaults)) {
    if (assigned === id2) delete state.projectDefaults[path];
  }
  persist$1(state);
  let filesDeleted = false;
  if (options.deleteFiles === true) {
    if (isManagedConfigDir(profile.configDir) && !isProtectedDir(profile.configDir)) {
      node_fs.rmSync(profile.configDir, { recursive: true, force: true });
      filesDeleted = true;
    }
  }
  return {
    removed: true,
    filesDeleted,
    // Nothing was deleted, or the credential is somewhere this did not touch.
    credentialsRetained: !filesDeleted || isolation.store !== "config-directory"
  };
}
function setGlobalDefault(id2) {
  const state = getState();
  if (id2 !== null && !knownProfileIds(state).has(id2)) throw new ProfileError(`no profile with id ${id2}`);
  state.defaultProfileId = id2 === SYSTEM_PROFILE_ID ? null : id2;
  persist$1(state);
  return state;
}
function setProjectDefault(projectPath2, id2) {
  const state = getState();
  if (typeof projectPath2 !== "string" || projectPath2 === "") {
    throw new ProfileError("a project path is required");
  }
  const key = canonicalProjectKey(projectPath2);
  if (id2 === null) {
    delete state.projectDefaults[key];
  } else {
    if (!knownProfileIds(state).has(id2)) throw new ProfileError(`no profile with id ${id2}`);
    state.projectDefaults[key] = id2;
  }
  persist$1(state);
  return state;
}
function profileStatus(profile, platform = currentPlatform()) {
  return {
    id: profile.id,
    exists: node_fs.existsSync(profile.configDir),
    initialized: node_fs.existsSync(node_path.join(profile.configDir, ".claude.json")),
    configDir: profile.configDir,
    // A `stat`, not a keychain read: it costs nothing and prompts for nothing,
    // which is what keeps the paragraph above true.
    isolation: profileIsolation(platform, node_fs.existsSync(node_path.join(profile.configDir, ".credentials.json")))
  };
}
function requireString$1(value, label2) {
  if (typeof value !== "string") throw new ProfileError(`${label2} must be a string`);
  return value;
}
function optionalId(value) {
  return typeof value === "string" && value !== "" ? value : null;
}
function snapshot() {
  const state = getState();
  return {
    profiles: listProfiles(state),
    defaultProfileId: state.defaultProfileId,
    projectDefaults: { ...state.projectDefaults }
  };
}
function registerProfilesIpc(ipcMain) {
  ipcMain.handle("profiles:list", () => snapshot());
  ipcMain.handle("profiles:create", (_e, name, options) => {
    const configDir = typeof options === "object" && options !== null ? options.configDir : void 0;
    return createProfile(requireString$1(name, "name"), {
      configDir: typeof configDir === "string" ? configDir : void 0
    });
  });
  ipcMain.handle(
    "profiles:rename",
    (_e, id2, name) => renameProfile(requireString$1(id2, "id"), requireString$1(name, "name"))
  );
  ipcMain.handle("profiles:delete", (_e, id2, options) => {
    const deleteFiles = typeof options === "object" && options !== null && options.deleteFiles === true;
    return deleteProfile(requireString$1(id2, "id"), { deleteFiles });
  });
  ipcMain.handle("profiles:set-default", (_e, id2) => {
    setGlobalDefault(optionalId(id2));
    return snapshot();
  });
  ipcMain.handle(
    "profiles:set-project-default",
    (_e, projectPath2, id2) => {
      setProjectDefault(requireString$1(projectPath2, "projectPath"), optionalId(id2));
      return snapshot();
    }
  );
  ipcMain.handle("profiles:resolve", (_e, input) => {
    const request = typeof input === "object" && input !== null ? input : {};
    return resolveProfile(getState(), {
      sessionProfileId: optionalId(request.sessionProfileId),
      projectPath: typeof request.projectPath === "string" ? request.projectPath : null
    });
  });
  ipcMain.handle("profiles:status", (_e, id2) => {
    const profile = findProfile(getState(), requireString$1(id2, "id"));
    if (!profile) throw new ProfileError(`no profile with id ${id2}`);
    return profileStatus(profile);
  });
}
const TERMINALDECKIGNORE_FILE = ".deckignore";
const GITIGNORE_FILE = ".gitignore";
const IGNORE_FILE_ORDER = [GITIGNORE_FILE, TERMINALDECKIGNORE_FILE];
const MAX_IGNORE_BYTES = 256 * 1024;
async function readIgnoreFile(root, file) {
  const path = node_path.join(root, file);
  const absent = { file, path, present: false, ruleCount: 0, skipped: null };
  const tooLarge2 = { file, path, present: true, ruleCount: 0, skipped: "too-large" };
  let text2;
  let handle2;
  try {
    handle2 = await promises.open(path, node_fs.constants.O_RDONLY | (node_fs.constants.O_NONBLOCK ?? 0));
    const info = await handle2.stat();
    if (!info.isFile()) return { source: absent, rules: [] };
    if (info.size > MAX_IGNORE_BYTES) return { source: tooLarge2, rules: [] };
    const buffer = Buffer.allocUnsafe(Math.min(info.size, MAX_IGNORE_BYTES) + 1);
    let filled = 0;
    while (filled < buffer.length) {
      const { bytesRead } = await handle2.read(buffer, filled, buffer.length - filled, filled);
      if (bytesRead === 0) break;
      filled += bytesRead;
    }
    if (filled > MAX_IGNORE_BYTES) return { source: tooLarge2, rules: [] };
    text2 = buffer.subarray(0, filled).toString("utf8");
  } catch {
    return { source: absent, rules: [] };
  } finally {
    await handle2?.close().catch(() => {
    });
  }
  const rules = [];
  const lines2 = text2.split(/\r?\n/);
  for (let i = 0; i < lines2.length; i++) {
    const [rule] = parseIgnoreFile(lines2[i]);
    if (rule) rules.push({ rule, file, line: i + 1 });
  }
  return {
    source: { file, path, present: true, ruleCount: rules.length, skipped: null },
    rules
  };
}
async function loadProjectIgnore(root, options = {}) {
  const resolved = node_path.resolve(root);
  const files = options.includeGitignore === false ? [TERMINALDECKIGNORE_FILE] : [...IGNORE_FILE_ORDER];
  const loaded = await Promise.all(files.map((file) => readIgnoreFile(resolved, file)));
  const rules = loaded.flatMap((entry) => entry.rules);
  return {
    root: resolved,
    matches: createIgnoreMatcher(rules.map((tagged) => tagged.rule)),
    rules,
    sources: loaded.map((entry) => entry.source)
  };
}
const MAX_CACHED_PROJECTS = 64;
function cacheKey(root, includeGitignore) {
  return `${includeGitignore ? "g" : "-"}:${root}`;
}
const cache$1 = /* @__PURE__ */ new Map();
const inFlight = /* @__PURE__ */ new Map();
async function ignoreStamp(root, files) {
  const parts = await Promise.all(
    files.map(async (file) => {
      try {
        const info = await promises.stat(node_path.join(root, file));
        return `${file}:${info.mtimeMs}:${info.size}`;
      } catch {
        return `${file}:-`;
      }
    })
  );
  return parts.join("|");
}
async function ignoreFor(root, options = {}) {
  const resolved = node_path.resolve(root);
  const includeGitignore = options.includeGitignore !== false;
  const files = includeGitignore ? IGNORE_FILE_ORDER : [TERMINALDECKIGNORE_FILE];
  const stamp2 = await ignoreStamp(resolved, files);
  const key = cacheKey(resolved, includeGitignore);
  const cached2 = cache$1.get(key);
  if (cached2 && cached2.stamp === stamp2) {
    cache$1.delete(key);
    cache$1.set(key, cached2);
    return cached2.ignore;
  }
  const flightKey = `${key}|${stamp2}`;
  const pending = inFlight.get(flightKey);
  if (pending) return pending;
  const load2 = loadProjectIgnore(resolved, options).then((ignore) => {
    cache$1.set(key, { ignore, stamp: stamp2 });
    while (cache$1.size > MAX_CACHED_PROJECTS) {
      const oldest = cache$1.keys().next();
      if (oldest.done) break;
      cache$1.delete(oldest.value);
    }
    return ignore;
  }).finally(() => {
    inFlight.delete(flightKey);
  });
  inFlight.set(flightKey, load2);
  return load2;
}
function invalidateIgnoreCache(root) {
  if (root === void 0) {
    cache$1.clear();
    return;
  }
  const resolved = node_path.resolve(root);
  cache$1.delete(cacheKey(resolved, true));
  cache$1.delete(cacheKey(resolved, false));
}
function explainPath(ignore, relPath, isDir) {
  const base = {
    relPath,
    ignored: false,
    rule: null,
    viaAncestor: null,
    alwaysIgnored: false
  };
  const segments = relPath.split("/").filter((segment) => segment !== "");
  if (segments.length === 0) return base;
  if (segments.some((segment) => isAlwaysIgnored(segment))) {
    return { ...base, ignored: true, alwaysIgnored: true };
  }
  for (let i = 0; i < segments.length; i++) {
    const last = i === segments.length - 1;
    const prefix = segments.slice(0, i + 1).join("/");
    const asDir = last ? isDir : true;
    let ignored2 = false;
    let deciding = null;
    for (const tagged of ignore.rules) {
      if (tagged.rule.dirOnly && !asDir) continue;
      if (tagged.rule.re.test(prefix)) {
        ignored2 = !tagged.rule.negated;
        deciding = tagged;
      }
    }
    const rule = deciding ? {
      source: deciding.rule.source,
      file: deciding.file,
      line: deciding.line,
      negated: deciding.rule.negated
    } : null;
    if (last) return { ...base, ignored: ignored2, rule };
    if (ignored2) return { ...base, ignored: true, rule, viaAncestor: prefix };
  }
  return base;
}
async function filterIgnoredFiles(root, files, options = {}) {
  const ignore = await ignoreFor(root, options);
  return files.filter((file) => !ignore.matches(file, false));
}
function requireString(value, label2) {
  if (typeof value !== "string") throw new TypeError(`${label2} must be a string`);
  return value;
}
function registerDeckignoreIpc(ipcMain, options = {}) {
  const guard2 = (root) => {
    const resolved = node_path.resolve(root);
    if (options.isAllowedRoot && !options.isAllowedRoot(resolved)) {
      throw new Error("that folder is not an open project");
    }
    return resolved;
  };
  ipcMain.handle(
    "deckignore:overview",
    async (_e, root) => {
      const ignore = await ignoreFor(guard2(requireString(root, "root")));
      return { root: ignore.root, sources: ignore.sources, ruleCount: ignore.rules.length };
    }
  );
  ipcMain.handle(
    "deckignore:explain",
    async (_e, root, relPath, isDir) => {
      const ignore = await ignoreFor(guard2(requireString(root, "root")));
      return explainPath(ignore, requireString(relPath, "relPath"), isDir === true);
    }
  );
  ipcMain.handle(
    "deckignore:filter",
    async (_e, root, paths) => {
      if (!Array.isArray(paths)) throw new TypeError("paths must be an array");
      const files = paths.filter((entry) => typeof entry === "string");
      return filterIgnoredFiles(guard2(requireString(root, "root")), files);
    }
  );
  ipcMain.handle("deckignore:invalidate", (_e, root) => {
    invalidateIgnoreCache(typeof root === "string" ? root : void 0);
  });
}
const HOST = "127.0.0.1";
const TOKEN_HEADER$1 = `x-${BRAND.id}-token`;
const SESSION_HEADER$1 = `x-${BRAND.id}-session`;
const MAX_BODY_BYTES = 1024 * 1024;
const SEGMENT_RE = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
const HEADERS_TIMEOUT_MS = 1e4;
const REQUEST_TIMEOUT_MS = 3e4;
let server = null;
let endpoint = null;
let starting = null;
const listeners = /* @__PURE__ */ new Set();
function currentHookEndpoint() {
  return endpoint;
}
function emit(event) {
  for (const listener of listeners) {
    try {
      listener(event);
    } catch (error) {
      console.error("[hook-server] listener threw:", error);
    }
  }
}
function tokenMatches(supplied, expected) {
  if (typeof supplied !== "string") return false;
  const a = Buffer.from(supplied);
  const b = Buffer.from(expected);
  if (a.length !== b.length) {
    node_crypto.timingSafeEqual(b, b);
    return false;
  }
  return node_crypto.timingSafeEqual(a, b);
}
function isLoopback$1(address) {
  if (!address) return false;
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}
function hostIsLocal(host, port) {
  if (!host) return false;
  const expected = /* @__PURE__ */ new Set([`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`]);
  return expected.has(host.toLowerCase());
}
function parseHookPath(url) {
  if (!url) return null;
  const path = url.split("?")[0];
  const parts = path.split("/").filter((part) => part !== "");
  if (parts.length !== 3 || parts[0] !== "hook") return null;
  if (!SEGMENT_RE.test(parts[1]) || !SEGMENT_RE.test(parts[2])) return null;
  return { provider: parts[1], event: parts[2] };
}
class PayloadTooLarge extends Error {
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    const finish = (error, body) => {
      if (settled) return;
      settled = true;
      if (error) reject(error);
      else resolve(body ?? "");
    };
    req.on("data", (chunk) => {
      if (settled) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        finish(new PayloadTooLarge("hook payload too large"));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => finish(null, Buffer.concat(chunks).toString("utf8")));
    req.on("error", (error) => finish(error));
    req.on("close", () => finish(new Error("hook request closed before its body arrived")));
  });
}
function str(value) {
  return typeof value === "string" && value !== "" ? value : null;
}
function toHookEvent(provider, event, sessionId, body) {
  let payload = {};
  if (body.trim() !== "") {
    try {
      const parsed = JSON.parse(body);
      if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
        payload = parsed;
      }
    } catch {
    }
  }
  return {
    provider,
    event,
    sessionId,
    cliSessionId: str(payload.session_id),
    cwd: str(payload.cwd) ?? str(payload.workspace_dir),
    toolName: str(payload.tool_name),
    receivedAt: Date.now(),
    payload
  };
}
function deny(res, code) {
  if (res.writableEnded || res.destroyed) return;
  res.writeHead(code, { "content-type": "text/plain" });
  res.end();
}
async function handle(req, res, live) {
  if (!isLoopback$1(req.socket.remoteAddress)) return deny(res, 403);
  if (req.method !== "POST") return deny(res, 405);
  if (!hostIsLocal(req.headers.host, live.port)) return deny(res, 403);
  if (!tokenMatches(req.headers[TOKEN_HEADER$1], live.token)) return deny(res, 403);
  const route = parseHookPath(req.url);
  if (!route) return deny(res, 404);
  let body;
  try {
    body = await readBody(req);
  } catch (error) {
    return deny(res, error instanceof PayloadTooLarge ? 413 : 400);
  }
  const sessionId = str(req.headers[SESSION_HEADER$1]);
  res.writeHead(204);
  res.end();
  emit(toHookEvent(route.provider, route.event, sessionId, body));
}
async function registerHookServer(ipcMain, options = {}) {
  if (options.onEvent) listeners.add(options.onEvent);
  ipcMain.removeHandler("hooks:server");
  ipcMain.handle("hooks:server", () => ({
    port: endpoint?.port ?? null,
    running: endpoint !== null
  }));
  if (endpoint) return endpoint;
  return startHookServer(options);
}
async function startHookServer(options = {}) {
  if (options.onEvent) listeners.add(options.onEvent);
  if (endpoint) return endpoint;
  if (starting) return starting;
  starting = openServer(options);
  try {
    return await starting;
  } finally {
    starting = null;
  }
}
async function openServer(options) {
  const token2 = node_crypto.randomBytes(24).toString("hex");
  const live = { port: 0, token: token2 };
  const next = node_http.createServer((req, res) => {
    void handle(req, res, live).catch(() => {
      if (!res.headersSent) deny(res, 500);
      else res.end();
    });
  });
  next.on("clientError", (_error, socket) => socket.destroy());
  next.headersTimeout = HEADERS_TIMEOUT_MS;
  next.requestTimeout = REQUEST_TIMEOUT_MS;
  await new Promise((resolve, reject) => {
    const onListenError = (error) => {
      next.close();
      reject(error);
    };
    next.once("error", onListenError);
    next.listen(options.port ?? 0, HOST, () => {
      next.removeListener("error", onListenError);
      next.on("error", (error) => console.error("[hook-server] server error:", error));
      resolve();
    });
  });
  const address = next.address();
  if (!address) {
    next.close();
    throw new Error("hook server: could not determine the listening port");
  }
  live.port = address.port;
  server = next;
  endpoint = live;
  return live;
}
async function stopHookServer() {
  if (starting) {
    try {
      await starting;
    } catch {
    }
  }
  const running = server;
  server = null;
  endpoint = null;
  listeners.clear();
  if (!running) return;
  await new Promise((resolve) => {
    running.close(() => resolve());
    running.closeAllConnections?.();
  });
}
const CLAUDE_EVENTS = [
  "SessionStart",
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "PostToolUseFailure",
  "PermissionRequest",
  "Notification",
  "Stop",
  "StopFailure",
  "SessionEnd"
];
const CODEX_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"];
const GEMINI_EVENTS = [
  "SessionStart",
  "BeforeAgent",
  "BeforeTool",
  "AfterTool",
  "AfterAgent",
  "Notification",
  "SessionEnd"
];
const HOOK_PROVIDERS = {
  claude: {
    id: "claude",
    label: "Claude Code",
    path: [".claude", "settings.json"],
    events: CLAUDE_EVENTS,
    // Seconds. Long enough to survive a stalled loopback connect, short enough
    // that a wedged hook never becomes a wedged session.
    timeout: { key: "timeout", value: 5 },
    supportsName: false,
    requirement: null
  },
  codex: {
    id: "codex",
    label: "Codex CLI",
    path: [".codex", "hooks.json"],
    events: CODEX_EVENTS,
    timeout: null,
    supportsName: false,
    requirement: "Codex only runs hooks with `codex_hooks = true` under [features] in ~/.codex/config.toml."
  },
  gemini: {
    id: "gemini",
    label: "Gemini CLI",
    path: [".gemini", "settings.json"],
    events: GEMINI_EVENTS,
    // Milliseconds — same key, different unit from Claude's.
    timeout: { key: "timeout", value: 5e3 },
    supportsName: true,
    requirement: null
  }
};
const HOOK_PROVIDER_IDS = Object.keys(HOOK_PROVIDERS);
const HOOK_MARKER = `# ${BRAND.id}-hook`;
const TOKEN_HEADER = `x-${BRAND.id}-token`;
const SESSION_HEADER = `x-${BRAND.id}-session`;
const FOREIGN_MARKER_RE = /#\s*([a-z][a-z0-9_-]*)-hook\b/i;
const CURL = "/usr/bin/curl";
function shellQuote(value) {
  return `'${value.split("'").join(`'\\''`)}'`;
}
function hookCommand(provider, event, endpoint2) {
  const url = `http://127.0.0.1:${endpoint2.port}/hook/${provider}/${event}`;
  return [
    CURL,
    "-s",
    "-o /dev/null",
    "--connect-timeout 1",
    "--max-time 3",
    "-X POST",
    "-H 'content-type: application/json'",
    `-H ${shellQuote(`${TOKEN_HEADER}: ${endpoint2.token}`)}`,
    // Double-quoted so the shell expands it: the PTY injects this per session,
    // which is what ties a hook back to the tab the user is looking at. Inside
    // double quotes `$VAR` expands but its *value* is never re-evaluated, so a
    // session id is data here no matter what it contains.
    `-H "${SESSION_HEADER}: $${BRAND.sessionEnvVar}"`,
    "--data-binary @-",
    shellQuote(url),
    "|| true",
    HOOK_MARKER
  ].join(" ");
}
const NEW_FILE_MODE = 384;
function detectIndent(text2) {
  const match = /\n([ \t]+)"/.exec(text2);
  return match ? match[1] : "  ";
}
class SettingsError extends Error {
}
function loadSettings(file) {
  let raw;
  let mode = NEW_FILE_MODE;
  try {
    raw = node_fs.readFileSync(file, "utf8");
    mode = node_fs.statSync(file).mode & 511;
  } catch (error) {
    if (error.code === "ENOENT") {
      return { raw: "", data: {}, exists: false, mode: NEW_FILE_MODE, indent: "  ", trailingNewline: true };
    }
    throw new SettingsError(`could not be read: ${error.message}`);
  }
  if (raw.trim() === "") {
    return { raw, data: {}, exists: true, mode, indent: "  ", trailingNewline: true };
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new SettingsError(`is not valid JSON (${error.message}), so it was left untouched`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new SettingsError("is not a JSON object, so it was left untouched");
  }
  return {
    raw,
    data: parsed,
    exists: true,
    mode,
    indent: detectIndent(raw),
    trailingNewline: raw.endsWith("\n")
  };
}
function serialise(settings, data) {
  const body = JSON.stringify(data, null, settings.indent);
  return settings.trailingNewline ? `${body}
` : body;
}
function resolveWriteTarget(file) {
  try {
    return node_fs.realpathSync(file);
  } catch {
    return file;
  }
}
function writeAtomic(target2, text2, mode) {
  const file = resolveWriteTarget(target2);
  node_fs.mkdirSync(node_path.dirname(file), { recursive: true });
  const tmp = node_path.join(node_path.dirname(file), `.${BRAND.id}-${process.pid}-${node_crypto.randomBytes(6).toString("hex")}.tmp`);
  const fd = node_fs.openSync(tmp, "wx", mode);
  try {
    node_fs.writeSync(fd, text2);
    node_fs.fsyncSync(fd);
  } finally {
    node_fs.closeSync(fd);
  }
  try {
    node_fs.chmodSync(tmp, mode);
    node_fs.renameSync(tmp, file);
  } catch (error) {
    try {
      node_fs.unlinkSync(tmp);
    } catch {
    }
    throw error;
  }
}
function backupPathFor(context, id2) {
  return node_path.join(context.backupDir, `${id2}-${HOOK_PROVIDERS[id2].path.join("-")}.bak`);
}
function backupOnce(context, id2, file) {
  const target2 = backupPathFor(context, id2);
  try {
    node_fs.mkdirSync(node_path.dirname(target2), { recursive: true });
    node_fs.copyFileSync(
      file,
      target2,
      1
      /* COPYFILE_EXCL */
    );
    return target2;
  } catch (error) {
    const code = error.code;
    if (code === "EEXIST") return target2;
    if (code === "ENOENT") return null;
    throw error;
  }
}
function hasBackup(context, id2) {
  const target2 = backupPathFor(context, id2);
  try {
    node_fs.statSync(target2);
    return target2;
  } catch {
    return null;
  }
}
function isRecord$2(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function isOurs(entry) {
  if (!isRecord$2(entry)) return false;
  return typeof entry.command === "string" && entry.command.includes(HOOK_MARKER);
}
function ownerOf(entry) {
  if (!isRecord$2(entry) || typeof entry.command !== "string") return null;
  const match = FOREIGN_MARKER_RE.exec(entry.command);
  return match ? match[1].toLowerCase() : null;
}
function eventEntries(hooks) {
  const out = [];
  for (const [key, value] of Object.entries(hooks)) {
    if (Array.isArray(value)) out.push([key, value]);
  }
  return out;
}
function hooksObject(data) {
  const existing = data.hooks;
  if (existing === void 0) return {};
  if (!isRecord$2(existing)) {
    throw new SettingsError("has a `hooks` key that is not an object, so it was left untouched");
  }
  return existing;
}
function ourEntriesByEvent(hooks) {
  const found = /* @__PURE__ */ new Map();
  for (const [event, groups] of eventEntries(hooks)) {
    const entries2 = [];
    for (const group of groups) {
      if (!isRecord$2(group) || !Array.isArray(group.hooks)) continue;
      for (const entry of group.hooks) {
        if (isOurs(entry)) entries2.push(entry);
      }
    }
    if (entries2.length > 0) found.set(event, entries2);
  }
  return found;
}
function surveyForeign(hooks) {
  let count = 0;
  const owners = /* @__PURE__ */ new Set();
  for (const [, groups] of eventEntries(hooks)) {
    for (const group of groups) {
      if (!isRecord$2(group) || !Array.isArray(group.hooks)) continue;
      for (const entry of group.hooks) {
        if (!isRecord$2(entry) || isOurs(entry)) continue;
        count++;
        const owner = ownerOf(entry);
        if (owner) owners.add(owner);
      }
    }
  }
  return { count, owners: [...owners].sort() };
}
function buildEntry(spec, event, endpoint2) {
  const entry = { type: "command", command: hookCommand(spec.id, event, endpoint2) };
  if (spec.timeout) entry[spec.timeout.key] = spec.timeout.value;
  if (spec.supportsName) {
    entry.name = `${BRAND.id}-hook`;
    entry.description = `${BRAND.name} session tracking`;
  }
  return entry;
}
function applyInstall(data, spec, endpoint2) {
  const hooks = hooksObject(data);
  const next = { ...hooks };
  for (const [event, groups] of eventEntries(next)) {
    const kept = stripOurs(groups);
    if (!kept.changed) continue;
    if (kept.groups.length === 0 && !spec.events.includes(event)) delete next[event];
    else next[event] = kept.groups;
  }
  for (const event of spec.events) {
    const existing = next[event];
    if (existing !== void 0 && !Array.isArray(existing)) {
      throw new SettingsError(`has a \`hooks.${event}\` that is not an array, so it was left untouched`);
    }
    const groups = Array.isArray(existing) ? [...existing] : [];
    groups.push({ matcher: "", hooks: [buildEntry(spec, event, endpoint2)] });
    next[event] = groups;
  }
  return { ...data, hooks: next };
}
function stripOurs(groups) {
  let removed = 0;
  const out = [];
  for (const group of groups) {
    if (!isRecord$2(group) || !Array.isArray(group.hooks)) {
      out.push(group);
      continue;
    }
    const kept = group.hooks.filter((entry) => !isOurs(entry));
    const dropped = group.hooks.length - kept.length;
    removed += dropped;
    if (dropped === 0) {
      out.push(group);
      continue;
    }
    if (kept.length === 0) continue;
    out.push({ ...group, hooks: kept });
  }
  return { groups: out, changed: removed > 0, removed };
}
function applyRemove(data) {
  const hooks = hooksObject(data);
  const next = { ...hooks };
  let removed = 0;
  for (const [event, groups] of eventEntries(hooks)) {
    const result = stripOurs(groups);
    if (!result.changed) continue;
    removed += result.removed;
    if (result.groups.length === 0) delete next[event];
    else next[event] = result.groups;
  }
  if (removed === 0) return { data, removed: 0 };
  const out = { ...data };
  if (Object.keys(next).length === 0) delete out.hooks;
  else out.hooks = next;
  return { data: out, removed };
}
function fileFor(context, id2) {
  return node_path.join(context.home, ...HOOK_PROVIDERS[id2].path);
}
function errorStatus(spec, file, context, message) {
  return {
    id: spec.id,
    label: spec.label,
    file,
    fileExists: true,
    state: "error",
    installedEvents: [],
    staleEvents: [],
    missingEvents: [...spec.events],
    foreignHooks: 0,
    foreignOwners: [],
    backupPath: hasBackup(context, spec.id),
    message
  };
}
function readStatus(context, id2) {
  const spec = HOOK_PROVIDERS[id2];
  const file = fileFor(context, id2);
  let settings;
  try {
    settings = loadSettings(file);
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error);
    return errorStatus(spec, file, context, `${file} ${detail}`);
  }
  let hooks;
  try {
    hooks = hooksObject(settings.data);
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error);
    return errorStatus(spec, file, context, `${file} ${detail}`);
  }
  const ours = ourEntriesByEvent(hooks);
  const foreign = surveyForeign(hooks);
  const installed = [];
  const stale = [];
  const missing = [];
  for (const event of spec.events) {
    const entries2 = ours.get(event);
    if (!entries2 || entries2.length === 0) {
      missing.push(event);
      continue;
    }
    const expected = context.endpoint ? hookCommand(spec.id, event, context.endpoint) : null;
    const current = entries2.some((entry) => expected !== null && entry.command === expected);
    if (current) installed.push(event);
    else stale.push(event);
  }
  const orphaned = [...ours.keys()].filter((event) => !spec.events.includes(event));
  const state = installed.length === spec.events.length ? "complete" : stale.length > 0 && installed.length + stale.length === spec.events.length ? "stale" : installed.length + stale.length === 0 && orphaned.length === 0 ? "none" : "partial";
  return {
    id: spec.id,
    label: spec.label,
    file,
    fileExists: settings.exists,
    state,
    installedEvents: installed,
    staleEvents: stale,
    missingEvents: missing,
    foreignHooks: foreign.count,
    foreignOwners: foreign.owners,
    backupPath: hasBackup(context, spec.id),
    message: describe(spec, state, settings.exists, stale.length)
  };
}
function describe(spec, state, fileExists, staleCount) {
  switch (state) {
    case "complete":
      return `All ${spec.events.length} events are installed and pointing at this run.`;
    case "stale":
      return `Installed, but ${staleCount} event${staleCount === 1 ? "" : "s"} still point at a previous run of the app. Reinstall to aim them at this one.`;
    case "partial":
      return "Only some events are installed, so parts of a session go unreported.";
    default:
      return fileExists ? "No hooks from this app in this file yet." : "This file does not exist yet; installing creates it.";
  }
}
function readAllStatus(context) {
  return HOOK_PROVIDER_IDS.map((id2) => readStatus(context, id2));
}
function installHooks(context, id2) {
  const spec = HOOK_PROVIDERS[id2];
  const file = fileFor(context, id2);
  if (!context.endpoint) {
    return {
      ok: false,
      message: "The local hook endpoint is not running, so there is no address to install.",
      status: readStatus(context, id2)
    };
  }
  let settings;
  try {
    settings = loadSettings(file);
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error);
    return { ok: false, message: `${file} ${detail}`, status: readStatus(context, id2) };
  }
  let next;
  try {
    next = applyInstall(settings.data, spec, context.endpoint);
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error);
    return { ok: false, message: `${file} ${detail}`, status: readStatus(context, id2) };
  }
  const backup = settings.exists ? backupOnce(context, id2, file) : null;
  writeAtomic(file, serialise(settings, next), settings.mode);
  const status = readStatus(context, id2);
  const note = backup ? ` The original was kept at ${backup}.` : "";
  const requirement = spec.requirement ? ` ${spec.requirement}` : "";
  return {
    ok: true,
    message: `Installed ${spec.events.length} hooks into ${file}.${note}${requirement}`,
    status
  };
}
function removeHooks(context, id2) {
  const file = fileFor(context, id2);
  let settings;
  try {
    settings = loadSettings(file);
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error);
    return { ok: false, message: `${file} ${detail}`, status: readStatus(context, id2) };
  }
  if (!settings.exists) {
    return { ok: true, message: `${file} does not exist — nothing to remove.`, status: readStatus(context, id2) };
  }
  let result;
  try {
    result = applyRemove(settings.data);
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error);
    return { ok: false, message: `${file} ${detail}`, status: readStatus(context, id2) };
  }
  if (result.removed === 0) {
    return {
      ok: true,
      message: `No hooks from this app were in ${file} — it was not modified.`,
      status: readStatus(context, id2)
    };
  }
  backupOnce(context, id2, file);
  writeAtomic(file, serialise(settings, result.data), settings.mode);
  return {
    ok: true,
    message: `Removed ${result.removed} hook${result.removed === 1 ? "" : "s"} from ${file}. Nothing else in the file was changed.`,
    status: readStatus(context, id2)
  };
}
function syncInstalledHooks(context) {
  const out = [];
  for (const id2 of HOOK_PROVIDER_IDS) {
    const status = readStatus(context, id2);
    if (status.state === "stale" || status.state === "partial") {
      try {
        out.push(installHooks(context, id2).status);
        continue;
      } catch (error) {
        console.error(`[hooks] could not refresh ${id2}:`, error);
      }
    }
    out.push(status);
  }
  return out;
}
function defaultContext() {
  const home = node_os.homedir();
  return {
    home,
    backupDir: node_path.join(home, BRAND.projectConfigDir, "hook-backups"),
    endpoint: currentHookEndpoint()
  };
}
function asProviderId(value) {
  return typeof value === "string" && HOOK_PROVIDER_IDS.includes(value) ? value : null;
}
function registerHooksIpc(ipcMain, options = {}) {
  const context = options.context ?? defaultContext;
  ipcMain.handle("hooks:status", () => readAllStatus(context()));
  ipcMain.handle("hooks:sync", () => syncInstalledHooks(context()));
  ipcMain.handle("hooks:install", (_event, providerId) => {
    const id2 = asProviderId(providerId);
    if (id2 === null) throw new Error("hooks: unknown provider");
    try {
      return installHooks(context(), id2);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return { ok: false, message: `Install failed: ${message}`, status: readStatus(context(), id2) };
    }
  });
  ipcMain.handle("hooks:remove", (_event, providerId) => {
    const id2 = asProviderId(providerId);
    if (id2 === null) throw new Error("hooks: unknown provider");
    try {
      return removeHooks(context(), id2);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return { ok: false, message: `Remove failed: ${message}`, status: readStatus(context(), id2) };
    }
  });
}
const DEFAULT_TIMEOUTS = {
  connectMs: 2e4,
  listMs: 15e3,
  callMs: 6e4,
  closeMs: 3e3
};
function resolveTimeouts(overrides = {}) {
  const merged = { ...DEFAULT_TIMEOUTS };
  for (const key of Object.keys(DEFAULT_TIMEOUTS)) {
    const value = overrides[key];
    if (typeof value === "number" && Number.isFinite(value) && value > 0) merged[key] = value;
  }
  return merged;
}
const MAX_PAGES = 50;
const MAX_CONFIG_BYTES = 4 * 1024 * 1024;
const STDERR_TAIL_CHARS = 8e3;
const MAX_RESULT_CHARS = 512 * 1024;
function claudeJsonPath(env = process.env) {
  const override = env.CLAUDE_CONFIG_DIR?.trim();
  return override && override.length > 0 ? node_path.join(override, ".claude.json") : node_path.join(node_os.homedir(), ".claude.json");
}
function claudeSettingsDir(env = process.env) {
  const override = env.CLAUDE_CONFIG_DIR?.trim();
  return override && override.length > 0 ? override : node_path.join(node_os.homedir(), ".claude");
}
function projectMcpJsonPath(projectPath2) {
  return node_path.join(projectPath2, ".mcp.json");
}
function isRecord$1(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function readJsonFile(path) {
  try {
    const stats = node_fs.statSync(path);
    if (!stats.isFile()) {
      console.error("[mcp] ignoring a config path that is not a regular file:", path);
      return null;
    }
    if (stats.size > MAX_CONFIG_BYTES) {
      console.error(`[mcp] ignoring an oversized config file (${stats.size} bytes):`, path);
      return null;
    }
    return JSON.parse(node_fs.readFileSync(path, "utf8"));
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.error("[mcp] unreadable config, skipping:", path, err);
    }
    return null;
  }
}
function expandEnvRefs(value, env = process.env) {
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g, (whole2, name, fallback) => {
    const found = env[name];
    if (found !== void 0 && found !== "") return found;
    if (fallback !== void 0) return fallback;
    return whole2;
  });
}
function stringMap(value, env) {
  if (!isRecord$1(value)) return {};
  const out = {};
  for (const [key, raw] of Object.entries(value)) {
    if (typeof raw === "string") out[key] = expandEnvRefs(raw, env);
    else if (typeof raw === "number" || typeof raw === "boolean") out[key] = String(raw);
  }
  return out;
}
function stringArray(value, env) {
  if (!Array.isArray(value)) return [];
  return value.filter((item) => typeof item === "string" || typeof item === "number").map((item) => expandEnvRefs(String(item), env));
}
function parseServerEntry(name, raw, scope, source, env = process.env) {
  if (typeof name !== "string" || name.trim().length === 0) return null;
  if (!isRecord$1(raw)) return null;
  const declared = typeof raw.type === "string" ? raw.type.toLowerCase() : "";
  const command = typeof raw.command === "string" && raw.command.trim().length > 0 ? raw.command.trim() : null;
  const url = typeof raw.url === "string" && raw.url.trim().length > 0 ? raw.url.trim() : null;
  let transport;
  if (declared === "stdio" || declared === "http" || declared === "sse") transport = declared;
  else if (command) transport = "stdio";
  else if (url) transport = "http";
  else return null;
  if (transport === "stdio" && !command) return null;
  if (transport !== "stdio" && !url) return null;
  const cwd = typeof raw.cwd === "string" && raw.cwd.trim().length > 0 ? expandEnvRefs(raw.cwd.trim(), env) : null;
  return {
    id: `${scope}:${name}`,
    name,
    scope,
    transport,
    command: command ? expandEnvRefs(command, env) : null,
    args: stringArray(raw.args, env),
    env: stringMap(raw.env, env),
    cwd,
    url,
    source,
    enabled: true,
    disabledReason: null,
    unsupported: transport === "stdio" ? null : `${transport.toUpperCase()} servers are configured here but dialled by Claude Code itself — this inspector speaks stdio only.`
  };
}
function parseServerMap(raw, scope, source, env = process.env) {
  if (!isRecord$1(raw)) return [];
  const out = [];
  for (const [name, entry] of Object.entries(raw)) {
    const parsed = parseServerEntry(name, entry, scope, source, env);
    if (parsed) out.push(parsed);
  }
  return out;
}
function readProjectGates(claudeJson, settings, projectPath2) {
  const gates = { enabled: [], disabled: [], enableAll: false };
  const collect = (source) => {
    if (!isRecord$1(source)) return;
    if (Array.isArray(source.enabledMcpjsonServers)) {
      gates.enabled.push(...source.enabledMcpjsonServers.filter((n) => typeof n === "string"));
    }
    if (Array.isArray(source.disabledMcpjsonServers)) {
      gates.disabled.push(...source.disabledMcpjsonServers.filter((n) => typeof n === "string"));
    }
    if (source.enableAllProjectMcpServers === true) gates.enableAll = true;
  };
  collect(settings);
  if (projectPath2 && isRecord$1(claudeJson) && isRecord$1(claudeJson.projects)) {
    collect(claudeJson.projects[node_path.resolve(projectPath2)]);
  }
  return gates;
}
function applyProjectGates(servers, gates) {
  return servers.map((server2) => {
    if (server2.scope !== "project") return server2;
    if (gates.disabled.includes(server2.name)) {
      return { ...server2, enabled: false, disabledReason: "Rejected for this project in Claude Code." };
    }
    if (gates.enabled.includes(server2.name) || gates.enableAll) return server2;
    return { ...server2, enabled: false, disabledReason: "Not approved for this project yet." };
  });
}
function mergeByPrecedence(...groups) {
  const byName = /* @__PURE__ */ new Map();
  for (const group of groups) {
    for (const server2 of group) byName.set(server2.name, server2);
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
}
function collectServersFrom(sources) {
  const env = sources.env ?? process.env;
  const claudeJson = isRecord$1(sources.claudeJson) ? sources.claudeJson : {};
  const user = parseServerMap(claudeJson.mcpServers, "user", sources.claudeJsonPath, env);
  const project = sources.projectMcpJsonPath ? parseServerMap(
    isRecord$1(sources.projectMcpJson) ? sources.projectMcpJson.mcpServers : null,
    "project",
    sources.projectMcpJsonPath,
    env
  ) : [];
  let local = [];
  if (sources.projectPath && isRecord$1(claudeJson.projects)) {
    const entry = claudeJson.projects[node_path.resolve(sources.projectPath)];
    if (isRecord$1(entry)) {
      local = parseServerMap(entry.mcpServers, "local", sources.claudeJsonPath, env);
    }
  }
  const gates = readProjectGates(claudeJson, sources.settings, sources.projectPath);
  return mergeByPrecedence(user, applyProjectGates(project, gates), local);
}
function loadServers(projectPath2, env = process.env) {
  const configPath = claudeJsonPath(env);
  const settingsPath = node_path.join(claudeSettingsDir(env), "settings.json");
  const project = projectPath2 && node_path.isAbsolute(projectPath2) ? node_path.resolve(projectPath2) : null;
  const mcpJsonPath = project ? projectMcpJsonPath(project) : null;
  return collectServersFrom({
    claudeJson: readJsonFile(configPath),
    settings: readJsonFile(settingsPath),
    projectMcpJson: mcpJsonPath ? readJsonFile(mcpJsonPath) : null,
    projectPath: project,
    claudeJsonPath: configPath,
    projectMcpJsonPath: mcpJsonPath,
    env
  });
}
function withTimeout(work, ms, label2) {
  let timer;
  void work.catch(() => void 0);
  return Promise.race([
    work,
    new Promise((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error(`${label2} timed out after ${ms}ms`)), ms);
    })
  ]).finally(() => clearTimeout(timer));
}
function isMethodNotFound(err) {
  if (err instanceof types_js.McpError) return err.code === types_js.ErrorCode.MethodNotFound;
  if (typeof err === "object" && err !== null && "code" in err) {
    return err.code === types_js.ErrorCode.MethodNotFound;
  }
  return err instanceof Error && /-32601/.test(err.message);
}
function messageOf(err) {
  if (err instanceof Error) return err.message;
  if (typeof err === "string") return err;
  return String(err);
}
function optionalString(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}
function initialStatus(server2) {
  return {
    ...server2,
    state: "idle",
    error: null,
    serverInfo: null,
    capabilities: [],
    instructions: null,
    pid: null,
    connectedAt: null,
    stderr: ""
  };
}
async function defaultEnv(server2) {
  const path = await loginPath();
  const base = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (typeof value === "string") base[key] = value;
  }
  return { ...base, PATH: path, ...server2.env };
}
class McpPool {
  constructor(deps = {}) {
    this.deps = deps;
    this.timeouts = resolveTimeouts(deps.timeouts);
  }
  deps;
  live = /* @__PURE__ */ new Map();
  /**
   * Connections currently being opened, so overlapping callers share one.
   *
   * Without this, a second `connect()` arriving during a handshake tore the
   * first one down and started its own — and the first one's failure handler
   * then deleted the *second* one's entry from `live`, leaving a spawned child
   * process nobody held a handle to (never closed, not even on quit) while
   * `inventory()` reported "Not connected" for a server that was in fact ready.
   * Two clicks on Refresh were enough to hit it.
   */
  opening = /* @__PURE__ */ new Map();
  timeouts;
  /** Current status for a set of configs, live where we hold a connection. */
  statusFor(servers) {
    return servers.map((server2) => {
      const held = this.live.get(server2.id);
      return held ? { ...held.status, ...server2, ...pickRuntime(held.status) } : initialStatus(server2);
    });
  }
  getStatus(id2) {
    return this.live.get(id2)?.status ?? null;
  }
  publish(status) {
    this.deps.onStatusChange?.(status);
  }
  appendStderr(live, chunk) {
    const next = live.status.stderr + chunk;
    live.status.stderr = next.length > STDERR_TAIL_CHARS ? next.slice(next.length - STDERR_TAIL_CHARS) : next;
  }
  /**
   * Connect, or hand back the connection we already hold.
   *
   * Every failure path ends with the transport closed and a status carrying the
   * reason. Nothing here is allowed to reject into IPC without first leaving the
   * pool in a state the panel can render.
   */
  async connect(server2) {
    const inFlight2 = this.opening.get(server2.id);
    if (inFlight2) return inFlight2;
    const held = this.live.get(server2.id);
    if (held && held.status.state === "ready") return held.status;
    const work = this.openConnection(server2);
    this.opening.set(server2.id, work);
    try {
      return await work;
    } finally {
      if (this.opening.get(server2.id) === work) this.opening.delete(server2.id);
    }
  }
  async openConnection(server2) {
    const existing = this.live.get(server2.id);
    if (existing) await this.disconnect(server2.id);
    if (server2.unsupported) {
      const status2 = { ...initialStatus(server2), state: "failed", error: server2.unsupported };
      this.publish(status2);
      return status2;
    }
    const status = { ...initialStatus(server2), state: "connecting" };
    this.publish(status);
    let transport;
    let env;
    try {
      env = await (this.deps.resolveEnv ?? defaultEnv)(server2);
      transport = (this.deps.createTransport ?? createStdioTransport)(server2, env);
    } catch (err) {
      const failed = { ...status, state: "failed", error: messageOf(err) };
      this.publish(failed);
      return failed;
    }
    const client = new index_js.Client(
      { name: BRAND.id, version: "0.1.0" },
      // We answer no sampling/elicitation requests, so advertising those would
      // invite a server to ask something we can never answer.
      { capabilities: {} }
    );
    const entry = { client, status, intentionalClose: false, detachStderr: () => void 0 };
    this.live.set(server2.id, entry);
    const stderrStream = transport.stderr;
    if (stderrStream) {
      const onStderr = (chunk) => this.appendStderr(entry, chunk.toString());
      stderrStream.on("data", onStderr);
      entry.detachStderr = () => stderrStream.off?.("data", onStderr);
    }
    client.onerror = (err) => {
      if (entry.intentionalClose) return;
      this.appendStderr(entry, `
[transport] ${messageOf(err)}`);
    };
    client.onclose = () => {
      if (entry.intentionalClose || entry.status.state !== "ready") return;
      entry.status = {
        ...entry.status,
        state: "closed",
        error: entry.status.error ?? "The server exited.",
        pid: null
      };
      entry.detachStderr();
      if (this.live.get(server2.id) === entry) this.live.delete(server2.id);
      this.publish(entry.status);
    };
    try {
      await withTimeout(
        client.connect(transport, { timeout: this.timeouts.connectMs }),
        this.timeouts.connectMs,
        `Connecting to ${server2.name}`
      );
    } catch (err) {
      entry.intentionalClose = true;
      entry.detachStderr();
      await this.forceClose(client);
      if (this.live.get(server2.id) === entry) this.live.delete(server2.id);
      const failed = {
        ...entry.status,
        state: "failed",
        error: messageOf(err),
        pid: null
      };
      this.publish(failed);
      return failed;
    }
    const info = client.getServerVersion();
    const caps = client.getServerCapabilities() ?? {};
    entry.status = {
      ...entry.status,
      state: "ready",
      error: null,
      serverInfo: info ? { name: info.name, version: info.version } : null,
      capabilities: Object.keys(caps),
      instructions: optionalString(client.getInstructions()),
      pid: transport.pid ?? null,
      connectedAt: Date.now()
    };
    this.publish(entry.status);
    return entry.status;
  }
  /** Close a connection we opened. Safe to call for one we never had. */
  async disconnect(id2) {
    const entry = this.live.get(id2);
    if (!entry) return null;
    entry.intentionalClose = true;
    entry.detachStderr();
    this.live.delete(id2);
    await this.forceClose(entry.client);
    const status = { ...entry.status, state: "idle", pid: null, connectedAt: null, error: null };
    this.publish(status);
    return status;
  }
  async disconnectAll() {
    await Promise.allSettled([...this.opening.values()]);
    await Promise.all([...this.live.keys()].map((id2) => this.disconnect(id2)));
  }
  /**
   * `close()` on a wedged transport can itself hang — it waits for a process
   * that is not listening. Quit must not wait for that, so we give it a short
   * window and then abandon it.
   */
  async forceClose(closable) {
    try {
      await withTimeout(closable.close(), this.timeouts.closeMs, "Closing the connection");
    } catch (err) {
      console.error("[mcp] a connection would not close cleanly:", messageOf(err));
    }
  }
  require(id2) {
    const entry = this.live.get(id2);
    if (!entry || entry.status.state !== "ready") throw new Error("Not connected.");
    return entry;
  }
  /**
   * Everything a server offers, in one round trip from the panel's point of
   * view. Sections are gated on advertised capabilities: the SDK throws
   * client-side for a method the server never claimed, and surfacing
   * "Server does not support resources" as an error would make every
   * tools-only server look broken.
   */
  async inventory(server2) {
    const status = await this.connect(server2);
    const inventory = {
      serverId: server2.id,
      tools: [],
      resources: [],
      resourceTemplates: [],
      prompts: [],
      errors: {},
      status
    };
    if (status.state !== "ready") return inventory;
    const entry = this.live.get(server2.id);
    if (!entry || entry.status.state !== "ready") {
      inventory.errors.server = "The server exited before it could be listed.";
      inventory.status = this.getStatus(server2.id) ?? { ...status, state: "closed" };
      return inventory;
    }
    const caps = new Set(status.capabilities);
    if (caps.has("tools")) {
      await this.section(inventory, "tools", async () => {
        inventory.tools = await paginate(
          (cursor) => entry.client.listTools({ cursor }, { timeout: this.timeouts.listMs }),
          (page) => page.tools.map(toToolInfo)
        );
      });
    }
    if (caps.has("resources")) {
      await this.section(inventory, "resources", async () => {
        inventory.resources = await paginate(
          (cursor) => entry.client.listResources({ cursor }, { timeout: this.timeouts.listMs }),
          (page) => page.resources.map(toResourceInfo)
        );
      });
      await this.section(inventory, "resourceTemplates", async () => {
        inventory.resourceTemplates = await paginate(
          (cursor) => entry.client.listResourceTemplates({ cursor }, { timeout: this.timeouts.listMs }),
          (page) => page.resourceTemplates.map(toResourceTemplateInfo)
        );
      });
    }
    if (caps.has("prompts")) {
      await this.section(inventory, "prompts", async () => {
        inventory.prompts = await paginate(
          (cursor) => entry.client.listPrompts({ cursor }, { timeout: this.timeouts.listMs }),
          (page) => page.prompts.map(toPromptInfo)
        );
      });
    }
    inventory.status = this.getStatus(server2.id) ?? status;
    return inventory;
  }
  async section(inventory, key, work) {
    try {
      await withTimeout(work(), this.timeouts.listMs, `Listing ${key}`);
    } catch (err) {
      if (isMethodNotFound(err)) return;
      inventory.errors[key] = messageOf(err);
    }
  }
  /** Invoke a tool by hand from the inspector. */
  async callTool(server2, name, args) {
    const started = Date.now();
    const status = await this.connect(server2);
    if (status.state !== "ready") {
      return { ok: false, result: null, error: status.error ?? "Not connected.", durationMs: Date.now() - started, truncated: false };
    }
    try {
      const entry = this.require(server2.id);
      const raw = await withTimeout(
        entry.client.callTool({ name, arguments: args }, void 0, { timeout: this.timeouts.callMs }),
        this.timeouts.callMs,
        `Calling ${name}`
      );
      const { value, truncated } = capPayload(raw);
      return { ok: true, result: value, error: null, durationMs: Date.now() - started, truncated };
    } catch (err) {
      return { ok: false, result: null, error: messageOf(err), durationMs: Date.now() - started, truncated: false };
    }
  }
  async readResource(server2, uri) {
    return this.simpleCall(
      server2,
      `Reading ${uri}`,
      (client) => client.readResource({ uri }, { timeout: this.timeouts.listMs })
    );
  }
  async getPrompt(server2, name, args) {
    return this.simpleCall(
      server2,
      `Rendering ${name}`,
      (client) => client.getPrompt({ name, arguments: args }, { timeout: this.timeouts.listMs })
    );
  }
  async simpleCall(server2, label2, work) {
    const started = Date.now();
    const status = await this.connect(server2);
    if (status.state !== "ready") {
      return { ok: false, result: null, error: status.error ?? "Not connected.", durationMs: Date.now() - started, truncated: false };
    }
    try {
      const entry = this.require(server2.id);
      const raw = await withTimeout(work(entry.client), this.timeouts.listMs, label2);
      const { value, truncated } = capPayload(raw);
      return { ok: true, result: value, error: null, durationMs: Date.now() - started, truncated };
    } catch (err) {
      return { ok: false, result: null, error: messageOf(err), durationMs: Date.now() - started, truncated: false };
    }
  }
}
function pickRuntime(status) {
  return {
    state: status.state,
    error: status.error,
    serverInfo: status.serverInfo,
    capabilities: status.capabilities,
    instructions: status.instructions,
    pid: status.pid,
    connectedAt: status.connectedAt,
    stderr: status.stderr
  };
}
function createStdioTransport(server2, env) {
  if (!server2.command) throw new Error("This server has no command to run.");
  return new stdio_js.StdioClientTransport({
    command: server2.command,
    args: server2.args,
    env,
    cwd: server2.cwd ?? void 0,
    // Piped rather than inherited: inheriting dumps a server's chatter into the
    // app's own stderr where the user will never see it.
    stderr: "pipe"
  });
}
async function paginate(fetchPage, select) {
  const items = [];
  const seen = /* @__PURE__ */ new Set();
  let cursor;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const result = await fetchPage(cursor);
    items.push(...select(result));
    if (!result.nextCursor) return items;
    if (seen.has(result.nextCursor)) {
      console.error("[mcp] stopped paging: the server repeated a cursor");
      return items;
    }
    seen.add(result.nextCursor);
    cursor = result.nextCursor;
  }
  console.error("[mcp] stopped paging after", MAX_PAGES, "pages");
  return items;
}
function toToolInfo(tool) {
  return {
    name: tool.name,
    title: optionalString(tool.title),
    description: optionalString(tool.description),
    inputSchema: tool.inputSchema ?? null,
    outputSchema: tool.outputSchema ?? null
  };
}
function toResourceInfo(resource) {
  return {
    uri: resource.uri,
    name: resource.name,
    title: optionalString(resource.title),
    description: optionalString(resource.description),
    mimeType: optionalString(resource.mimeType)
  };
}
function toResourceTemplateInfo(template) {
  return {
    uriTemplate: template.uriTemplate,
    name: template.name,
    title: optionalString(template.title),
    description: optionalString(template.description),
    mimeType: optionalString(template.mimeType)
  };
}
function toPromptInfo(prompt) {
  return {
    name: prompt.name,
    title: optionalString(prompt.title),
    description: optionalString(prompt.description),
    arguments: (prompt.arguments ?? []).map((arg) => ({
      name: arg.name,
      description: optionalString(arg.description),
      required: arg.required === true
    }))
  };
}
function capPayload(value) {
  let json;
  try {
    json = JSON.stringify(value) ?? "";
  } catch {
    return { value: { note: "The result could not be serialised." }, truncated: true };
  }
  if (json.length <= MAX_RESULT_CHARS) return { value, truncated: false };
  return {
    value: {
      note: `The result was ${json.length} characters; showing the first ${MAX_RESULT_CHARS}.`,
      preview: json.slice(0, MAX_RESULT_CHARS)
    },
    truncated: true
  };
}
const STATE_CHANNEL = "mcp:state";
const pool = new McpPool({ onStatusChange: (status) => broadcast(status) });
const subscribers$1 = /* @__PURE__ */ new Set();
let ipcRegistered = false;
function broadcast(status) {
  for (const contents of subscribers$1) {
    if (contents.isDestroyed()) {
      subscribers$1.delete(contents);
      continue;
    }
    try {
      contents.send(STATE_CHANNEL, status);
    } catch (err) {
      subscribers$1.delete(contents);
      console.error("[mcp] dropping a dead subscriber:", messageOf(err));
    }
  }
}
function optionalProjectPath(value) {
  if (typeof value !== "string" || value.length === 0) return null;
  if (!node_path.isAbsolute(value)) throw new Error("mcp: a project path must be absolute");
  return node_path.resolve(value);
}
function findServer(id2, projectPath2) {
  if (typeof id2 !== "string" || id2.length === 0) throw new Error("mcp: a server id is required");
  const found = loadServers(projectPath2).find((server2) => server2.id === id2);
  if (!found) throw new Error(`mcp: no configured server with id ${id2}`);
  return found;
}
function argsObject(value) {
  if (value === void 0 || value === null) return {};
  if (!isRecord$1(value)) throw new Error("mcp: tool arguments must be an object");
  return value;
}
function stringArgs(value) {
  const out = {};
  for (const [key, raw] of Object.entries(argsObject(value))) {
    if (typeof raw === "string") out[key] = raw;
    else if (raw !== void 0 && raw !== null) out[key] = String(raw);
  }
  return out;
}
function registerMcpIpc(ipcMain) {
  if (ipcRegistered) return;
  ipcRegistered = true;
  ipcMain.handle("mcp:list", (event, projectPath2) => {
    const contents = event.sender;
    if (!subscribers$1.has(contents)) {
      subscribers$1.add(contents);
      contents.once("destroyed", () => subscribers$1.delete(contents));
    }
    return pool.statusFor(loadServers(optionalProjectPath(projectPath2)));
  });
  ipcMain.handle(
    "mcp:connect",
    (_e, id2, projectPath2) => pool.connect(findServer(id2, optionalProjectPath(projectPath2)))
  );
  ipcMain.handle("mcp:disconnect", (_e, id2) => {
    if (typeof id2 !== "string") throw new Error("mcp: a server id is required");
    return pool.disconnect(id2);
  });
  ipcMain.handle("mcp:inventory", (_e, id2, projectPath2) => {
    const project = optionalProjectPath(projectPath2);
    return pool.inventory(findServer(id2, project));
  });
  ipcMain.handle("mcp:call", (_e, id2, tool, args, projectPath2) => {
    if (typeof tool !== "string" || tool.length === 0) throw new Error("mcp: a tool name is required");
    return pool.callTool(findServer(id2, optionalProjectPath(projectPath2)), tool, argsObject(args));
  });
  ipcMain.handle("mcp:read-resource", (_e, id2, uri, projectPath2) => {
    if (typeof uri !== "string" || uri.length === 0) throw new Error("mcp: a resource uri is required");
    return pool.readResource(findServer(id2, optionalProjectPath(projectPath2)), uri);
  });
  ipcMain.handle("mcp:get-prompt", (_e, id2, name, args, projectPath2) => {
    if (typeof name !== "string" || name.length === 0) throw new Error("mcp: a prompt name is required");
    return pool.getPrompt(findServer(id2, optionalProjectPath(projectPath2)), name, stringArgs(args));
  });
}
const ALLOWED_PROTOCOLS = /* @__PURE__ */ new Set(["http:", "https:"]);
const BLANK_URL = "about:blank";
const HOST_PORT = /^(?:[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*|\[[0-9a-fA-F:]+\]):\d{1,5}(?:[/?#].*)?$/;
const HAS_SCHEME = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;
function normalizeUrl(input) {
  if (typeof input !== "string") return { ok: false, reason: "Enter a URL to open." };
  const trimmed = input.trim();
  if (!trimmed) return { ok: false, reason: "Enter a URL to open." };
  if (/[\u0000-\u0020\u007f]/.test(trimmed)) {
    return { ok: false, reason: "That URL contains characters a URL cannot contain." };
  }
  let candidate = trimmed;
  if (HAS_SCHEME.test(trimmed)) {
    const scheme = trimmed.slice(0, trimmed.indexOf(":")).toLowerCase();
    if (!ALLOWED_PROTOCOLS.has(`${scheme}:`)) {
      if (!HOST_PORT.test(trimmed)) {
        return { ok: false, reason: `Only http and https can be opened here, not ${scheme}:.` };
      }
      candidate = `http://${trimmed}`;
    }
  } else {
    candidate = trimmed.startsWith("//") ? `http:${trimmed}` : `http://${trimmed}`;
  }
  let parsed;
  try {
    parsed = new URL(candidate);
  } catch {
    return { ok: false, reason: "That is not a URL this can open." };
  }
  if (!ALLOWED_PROTOCOLS.has(parsed.protocol)) {
    return {
      ok: false,
      reason: `Only http and https can be opened here, not ${parsed.protocol}`
    };
  }
  if (!parsed.hostname) return { ok: false, reason: "That URL has no host." };
  return { ok: true, url: parsed.href };
}
function isNavigationAllowed(url) {
  if (typeof url !== "string" || url === "") return false;
  if (url === BLANK_URL) return true;
  try {
    return ALLOWED_PROTOCOLS.has(new URL(url).protocol);
  } catch {
    return false;
  }
}
const MAX_LABEL_LENGTH$1 = 120;
function shortLabel(url) {
  if (typeof url !== "string" || !url || url === BLANK_URL) return "New tab";
  const source = url.length > MAX_LABEL_LENGTH$1 * 4 ? url.slice(0, MAX_LABEL_LENGTH$1 * 4) : url;
  let label2;
  try {
    const parsed = new URL(source);
    const path = parsed.pathname === "/" ? "" : parsed.pathname;
    label2 = `${parsed.host}${path}`;
  } catch {
    label2 = source;
  }
  label2 = label2.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ").trim();
  return label2.length > MAX_LABEL_LENGTH$1 ? `${label2.slice(0, MAX_LABEL_LENGTH$1)}…` : label2;
}
const GUEST_ELEMENT_CHANNEL = "terminaldeck-browser:element";
const GUEST_INSPECT_CHANNEL = "terminaldeck-browser:set-inspect";
const GUEST_CANCEL_CHANNEL = "terminaldeck-browser:inspect-cancelled";
const GUEST_PRELOAD_FILENAME = "browser-guest-preload.js";
const TEST_ATTRS$1 = ["data-testid", "data-test-id", "data-test", "data-qa", "data-cy", "data-automation-id"];
const ATTR_KEYS$1 = ["aria-label", "alt", "placeholder", "title", "role", "type", "name", "href"];
const HIGHLIGHT_BORDER = "#8588f2";
const HIGHLIGHT_FILL = "rgba(133, 136, 242, 0.16)";
const CAPTURED_FILL = "rgba(133, 136, 242, 0.38)";
const GUEST_PRELOAD_SOURCE = `'use strict'
/* Generated by Deck from src/main/browser-preload.ts. Do not edit — it is overwritten on launch. */
;(function () {
  var ipc = require('electron').ipcRenderer

  var CH_ELEMENT = ${JSON.stringify(GUEST_ELEMENT_CHANNEL)}
  var CH_INSPECT = ${JSON.stringify(GUEST_INSPECT_CHANNEL)}
  var CH_CANCEL = ${JSON.stringify(GUEST_CANCEL_CHANNEL)}
  var TEST_ATTRS = ${JSON.stringify(TEST_ATTRS$1)}
  var ATTR_KEYS = ${JSON.stringify(ATTR_KEYS$1)}

  var MAX_DEPTH = 64
  var MAX_TEXT = 300
  var MAX_ATTR = 300
  var MAX_IDENT = 200

  var BASE_STYLE =
    'position:fixed;top:0;left:0;width:0;height:0;margin:0;padding:0;' +
    'box-sizing:border-box;pointer-events:none;display:none;' +
    'z-index:2147483647;border:2px solid ${HIGHLIGHT_BORDER};border-radius:2px;' +
    'background:${HIGHLIGHT_FILL};'
  var FILL = ${JSON.stringify(HIGHLIGHT_FILL)}
  var FILL_CAPTURED = ${JSON.stringify(CAPTURED_FILL)}

  var active = false
  var overlay = null
  var hovered = null
  var savedCursor = null

  function flatten(value, max) {
    if (typeof value !== 'string') return ''
    // Cut first, collapse second. textContent on a big page is megabytes — and
    // clicking <body> while inspecting asks for exactly that — so an unbounded
    // collapse would hang the page on the click it is meant to capture.
    var raw = value.length > max * 8 ? value.slice(0, max * 8) : value
    var flat = raw.replace(/\\s+/g, ' ').trim()
    return flat.length > max ? flat.slice(0, max) : flat
  }

  function printable(value) {
    return !/[\\u0000-\\u001f\\u007f]/.test(value)
  }

  function ensureOverlay() {
    // isConnected, not a null check: a single-page app can wipe the DOM out
    // from under us, and a detached box would silently stop appearing.
    if (overlay && overlay.isConnected) return overlay
    var box = document.createElement('div')
    box.setAttribute('data-terminaldeck-inspector', '')
    box.style.cssText = BASE_STYLE
    document.documentElement.appendChild(box)
    overlay = box
    return box
  }

  function place(el, captured) {
    var box = ensureOverlay()
    var rect = el.getBoundingClientRect()
    box.style.transform = 'translate(' + Math.round(rect.left) + 'px,' + Math.round(rect.top) + 'px)'
    box.style.width = Math.max(0, Math.round(rect.width)) + 'px'
    box.style.height = Math.max(0, Math.round(rect.height)) + 'px'
    box.style.background = captured ? FILL_CAPTURED : FILL
    box.style.display = 'block'
  }

  function hideOverlay() {
    if (overlay) overlay.style.display = 'none'
  }

  function removeOverlay() {
    if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay)
    overlay = null
  }

  function isUnique(selector) {
    try {
      return document.querySelectorAll(selector).length === 1
    } catch (err) {
      return false
    }
  }

  function cssStringOf(value) {
    return '"' + value.replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"') + '"'
  }

  function describe(el) {
    var d = { tag: typeof el.localName === 'string' ? el.localName : '' }

    var id = el.getAttribute('id')
    if (typeof id === 'string' && id !== '' && id.length <= MAX_IDENT && printable(id)) {
      d.id = id
      d.idUnique = isUnique('#' + CSS.escape(id))
    }

    for (var i = 0; i < TEST_ATTRS.length; i++) {
      var name = TEST_ATTRS[i]
      var value = el.getAttribute(name)
      if (typeof value === 'string' && value !== '' && value.length <= MAX_IDENT && printable(value)) {
        d.testAttr = name
        d.testValue = value
        d.testUnique = isUnique('[' + name + '=' + cssStringOf(value) + ']')
        break
      }
    }

    var count = 1
    var index = 1
    var parent = el.parentElement
    if (parent) {
      var kids = parent.children
      count = 0
      for (var j = 0; j < kids.length; j++) {
        var kid = kids[j]
        // :nth-of-type counts by element type, which is local name plus
        // namespace — an <a> in SVG is not the same type as an <a> in HTML.
        if (kid.localName === el.localName && kid.namespaceURI === el.namespaceURI) {
          count++
          if (kid === el) index = count
        }
      }
      if (count < 1) count = 1
    }
    d.ofTypeCount = count
    d.nthOfType = index
    return d
  }

  function pathFrom(el) {
    var path = []
    var node = el
    var depth = 0
    while (node && node.nodeType === 1 && depth < MAX_DEPTH) {
      path.push(describe(node))
      node = node.parentElement
      depth++
    }
    return path
  }

  function isSecretField(el) {
    // The property wins where it exists — a page can set input.type without
    // touching the attribute — and the attribute covers the fake-DOM case.
    var type = typeof el.type === 'string' && el.type !== '' ? el.type : el.getAttribute('type')
    return typeof type === 'string' && type.toLowerCase() === 'password'
  }

  function attributesOf(el) {
    var out = {}
    for (var i = 0; i < ATTR_KEYS.length; i++) {
      var name = ATTR_KEYS[i]
      var value = el.getAttribute(name)
      if (typeof value === 'string' && value !== '') out[name] = flatten(value, MAX_ATTR)
    }
    // What a form control currently holds, which its attribute does not track.
    // Never for a password field: that value would be shown in the capture
    // panel and pasted into the agent's prompt, which is written to disk.
    if (typeof el.value === 'string' && el.value !== '' && !isSecretField(el)) {
      out.value = flatten(el.value, MAX_ATTR)
    }
    return out
  }

  function elementFrom(event) {
    var target = event.target
    if (!target || target.nodeType !== 1) return null
    if (overlay !== null && target === overlay) return null
    return target
  }

  function onOver(event) {
    var el = elementFrom(event)
    if (!el) return
    hovered = el
    place(el, false)
  }

  function onOut() {
    hovered = null
    hideOverlay()
  }

  function reposition() {
    if (hovered && hovered.isConnected) place(hovered, false)
    else hideOverlay()
  }

  function swallow(event) {
    // Inspecting must not also drive the page: a click on a nav link would
    // navigate away from the thing being inspected.
    event.preventDefault()
    event.stopPropagation()
    if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation()
  }

  function onClick(event) {
    var el = elementFrom(event)
    swallow(event)
    if (!el) return
    place(el, true)
    ipc.send(CH_ELEMENT, {
      v: 1,
      path: pathFrom(el),
      text: flatten(el.textContent, MAX_TEXT),
      attributes: attributesOf(el)
    })
  }

  function onKeyDown(event) {
    if (event.key !== 'Escape') return
    event.preventDefault()
    event.stopPropagation()
    disable()
    ipc.send(CH_CANCEL)
  }

  // Capture phase everywhere, so page handlers never see these first.
  var DOC_EVENTS = [
    ['mouseover', onOver],
    ['mouseout', onOut],
    ['click', onClick],
    ['mousedown', swallow],
    ['mouseup', swallow],
    ['dblclick', swallow],
    ['contextmenu', swallow],
    ['keydown', onKeyDown]
  ]
  var WIN_EVENTS = [
    ['scroll', reposition],
    ['resize', reposition]
  ]

  function enable() {
    if (active) return
    active = true
    for (var i = 0; i < DOC_EVENTS.length; i++) {
      document.addEventListener(DOC_EVENTS[i][0], DOC_EVENTS[i][1], true)
    }
    for (var j = 0; j < WIN_EVENTS.length; j++) {
      window.addEventListener(WIN_EVENTS[j][0], WIN_EVENTS[j][1], true)
    }
    var root = document.documentElement
    // Remember what the page had rather than blanking it, so turning
    // inspection off cannot destroy a cursor the page set itself.
    savedCursor = root.style.cursor
    root.style.cursor = 'crosshair'
    ensureOverlay()
  }

  function disable() {
    if (!active) return
    active = false
    hovered = null
    for (var i = 0; i < DOC_EVENTS.length; i++) {
      document.removeEventListener(DOC_EVENTS[i][0], DOC_EVENTS[i][1], true)
    }
    for (var j = 0; j < WIN_EVENTS.length; j++) {
      window.removeEventListener(WIN_EVENTS[j][0], WIN_EVENTS[j][1], true)
    }
    if (savedCursor !== null) {
      document.documentElement.style.cursor = savedCursor
      savedCursor = null
    }
    removeOverlay()
  }

  ipc.on(CH_INSPECT, function (event, enabled) {
    if (enabled === true) enable()
    else disable()
  })
})()
`;
function writeGuestPreload(userDataDir) {
  node_fs.mkdirSync(userDataDir, { recursive: true });
  const target2 = node_path.join(userDataDir, GUEST_PRELOAD_FILENAME);
  node_fs.rmSync(target2, { force: true });
  node_fs.writeFileSync(target2, GUEST_PRELOAD_SOURCE, { encoding: "utf8", mode: 384, flag: "wx" });
  node_fs.chmodSync(target2, 384);
  return target2;
}
const TEST_ID_ATTRS = [
  "data-testid",
  "data-test-id",
  "data-test",
  "data-qa",
  "data-cy",
  "data-automation-id"
];
const CAPTURE_ATTRS = [
  "aria-label",
  "alt",
  "placeholder",
  "title",
  "role",
  "type",
  "name",
  "href",
  "value"
];
const MAX_PATH_DEPTH = 64;
const MAX_LABEL_LENGTH = 150;
const MAX_IDENT_LENGTH = 200;
const MAX_ATTR_LENGTH = 300;
const MAX_URL_LENGTH = 400;
const MAX_CONTEXT_LENGTH = 1200;
const SCAN_HEADROOM = 32;
function sanitizeLine(value, max) {
  if (typeof value !== "string") return "";
  const scanLimit = max * SCAN_HEADROOM + 1024;
  const stripped = (value.length > scanLimit ? value.slice(0, scanLimit) : value).replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ").replace(/[\u202a-\u202e\u2066-\u2069\u200e\u200f]/g, "").replace(/\s+/g, " ").trim();
  if (stripped.length <= max) return stripped;
  return `${stripped.slice(0, max).trimEnd()}…`;
}
function isPrintable(value) {
  return !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(value);
}
function escapeIdent(value) {
  let out = "";
  const first = value.charCodeAt(0);
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code === 0) {
      out += "�";
      continue;
    }
    const isDigit = code >= 48 && code <= 57;
    if (code >= 1 && code <= 31 || code === 127 || i === 0 && isDigit || i === 1 && isDigit && first === 45) {
      out += `\\${code.toString(16)} `;
      continue;
    }
    if (i === 0 && code === 45 && value.length === 1) {
      out += `\\${value.charAt(i)}`;
      continue;
    }
    if (code >= 128 || code === 45 || code === 95 || isDigit || code >= 65 && code <= 90 || code >= 97 && code <= 122) {
      out += value.charAt(i);
      continue;
    }
    out += `\\${value.charAt(i)}`;
  }
  return out;
}
function cssString(value) {
  if (!isPrintable(value)) return null;
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}
function safeTag(tag) {
  return typeof tag === "string" && /^[a-zA-Z][a-zA-Z0-9-]*$/.test(tag) && tag.length <= 60 ? tag : "*";
}
function usableId(d) {
  const id2 = typeof d.id === "string" ? d.id.trim() : "";
  if (!id2 || id2.length > MAX_IDENT_LENGTH || !isPrintable(id2)) return null;
  return id2;
}
function usableTest(d) {
  const attr = typeof d.testAttr === "string" ? d.testAttr : "";
  const value = typeof d.testValue === "string" ? d.testValue : "";
  if (!TEST_ID_ATTRS.includes(attr)) return null;
  if (!value || value.length > MAX_IDENT_LENGTH || !isPrintable(value)) return null;
  return { attr, value };
}
function attrSelector(attr, value) {
  const literal = cssString(value);
  return literal === null ? null : `[${attr}=${literal}]`;
}
function segmentFor(d) {
  const tag = safeTag(d.tag);
  const count = typeof d.ofTypeCount === "number" ? d.ofTypeCount : 1;
  const nth = typeof d.nthOfType === "number" ? d.nthOfType : 1;
  if (count > 1 && Number.isInteger(nth) && nth >= 1) return `${tag}:nth-of-type(${nth})`;
  return tag;
}
function computeSelector(path) {
  if (!Array.isArray(path) || path.length === 0) return "";
  const segments = [];
  for (let i = 0; i < path.length && i < MAX_PATH_DEPTH; i++) {
    const d = path[i];
    if (!d || typeof d !== "object") break;
    const id2 = usableId(d);
    if (id2 && d.idUnique === true) {
      segments.unshift(`#${escapeIdent(id2)}`);
      return segments.join(" > ");
    }
    const test = usableTest(d);
    if (test && d.testUnique === true) {
      const selector = attrSelector(test.attr, test.value);
      if (selector) {
        segments.unshift(selector);
        return segments.join(" > ");
      }
    }
    if (d.tag === "html") break;
    segments.unshift(segmentFor(d));
    if (d.tag === "body") break;
  }
  return segments.join(" > ");
}
function labelFrom(text2, attributes) {
  if (text2) return { label: text2, labelSource: "text" };
  const order = ["value", "aria-label", "alt", "placeholder", "title"];
  for (const key of order) {
    const value = attributes[key];
    if (value) return { label: value, labelSource: key };
  }
  return { label: "", labelSource: "none" };
}
function sanitizeAttributes(raw) {
  const out = {};
  if (typeof raw !== "object" || raw === null) return out;
  const record2 = raw;
  const isSecret = typeof record2.type === "string" && record2.type.trim().toLowerCase() === "password";
  for (const key of CAPTURE_ATTRS) {
    if (isSecret && key === "value") continue;
    const value = sanitizeLine(record2[key], MAX_ATTR_LENGTH);
    if (value) out[key] = value;
  }
  return out;
}
function sanitizeDescriptor(raw) {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw;
  if (typeof r.tag !== "string") return null;
  const d = { tag: r.tag.slice(0, 60) };
  if (typeof r.id === "string") d.id = r.id.slice(0, MAX_IDENT_LENGTH);
  if (typeof r.testAttr === "string") d.testAttr = r.testAttr.slice(0, 60);
  if (typeof r.testValue === "string") d.testValue = r.testValue.slice(0, MAX_IDENT_LENGTH);
  if (r.idUnique === true) d.idUnique = true;
  if (r.testUnique === true) d.testUnique = true;
  if (typeof r.nthOfType === "number" && Number.isInteger(r.nthOfType) && r.nthOfType >= 1) {
    d.nthOfType = r.nthOfType;
  }
  if (typeof r.ofTypeCount === "number" && Number.isInteger(r.ofTypeCount) && r.ofTypeCount >= 1) {
    d.ofTypeCount = r.ofTypeCount;
  }
  return d;
}
function parseCapture(raw, url) {
  if (typeof raw !== "object" || raw === null) return null;
  const payload = raw;
  if (payload.v !== 1) return null;
  if (!Array.isArray(payload.path) || payload.path.length === 0) return null;
  const path = [];
  for (const entry of payload.path.slice(0, MAX_PATH_DEPTH)) {
    const d = sanitizeDescriptor(entry);
    if (!d) break;
    path.push(d);
  }
  if (path.length === 0) return null;
  const selector = computeSelector(path);
  if (!selector) return null;
  const attributes = sanitizeAttributes(payload.attributes);
  const text2 = sanitizeLine(payload.text, MAX_LABEL_LENGTH);
  const { label: label2, labelSource } = labelFrom(text2, attributes);
  return {
    selector,
    tag: safeTag(path[0].tag) === "*" ? "" : path[0].tag,
    label: label2,
    labelSource,
    url: sanitizeLine(url, MAX_URL_LENGTH),
    attributes
  };
}
function composeAgentContext(capture, instruction = "") {
  const parts = [];
  if (capture.url) parts.push(`on ${capture.url}`);
  parts.push(`element \`${capture.selector}\``);
  if (capture.tag) parts.push(`<${capture.tag}>`);
  if (capture.label) {
    const word = capture.labelSource === "text" ? "text" : capture.labelSource;
    parts.push(`${word} "${capture.label}"`);
  }
  const context = `[browser: ${parts.join(", ")}]`;
  const lead = sanitizeLine(instruction, 600);
  return sanitizeLine(lead ? `${lead} ${context}` : context, MAX_CONTEXT_LENGTH);
}
const TEST_ATTRS = [
  "data-testid",
  "data-test-id",
  "data-test",
  "data-qa",
  "data-cy",
  "data-automation-id"
];
const ATTR_KEYS = ["aria-label", "alt", "placeholder", "title", "role", "type", "name", "href"];
const GUEST_DOM_HELPERS_SOURCE = `
  var TERMINALDECK_TEST_ATTRS = ${JSON.stringify(TEST_ATTRS)}
  var TERMINALDECK_ATTR_KEYS = ${JSON.stringify(ATTR_KEYS)}
  var TERMINALDECK_MAX_DEPTH = 64
  var TERMINALDECK_MAX_TEXT = 300
  var TERMINALDECK_MAX_ATTR = 300
  var TERMINALDECK_MAX_IDENT = 200

  function terminaldeckFlatten(value, max) {
    if (typeof value !== 'string') return ''
    // Cut first, collapse second. textContent on a real page is megabytes, and
    // an unbounded collapse would hang the page on the very interaction being
    // recorded.
    var raw = value.length > max * 8 ? value.slice(0, max * 8) : value
    var flat = raw.replace(/\\s+/g, ' ').trim()
    return flat.length > max ? flat.slice(0, max) : flat
  }

  function terminaldeckPrintable(value) {
    return !/[\\u0000-\\u001f\\u007f]/.test(value)
  }

  function terminaldeckUnique(selector) {
    try {
      return document.querySelectorAll(selector).length === 1
    } catch (err) {
      return false
    }
  }

  function terminaldeckCssString(value) {
    return '"' + value.replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"') + '"'
  }

  function terminaldeckDescribe(el) {
    var d = { tag: typeof el.localName === 'string' ? el.localName : '' }

    var id = el.getAttribute('id')
    if (typeof id === 'string' && id !== '' && id.length <= TERMINALDECK_MAX_IDENT && terminaldeckPrintable(id)) {
      d.id = id
      d.idUnique = terminaldeckUnique('#' + CSS.escape(id))
    }

    for (var i = 0; i < TERMINALDECK_TEST_ATTRS.length; i++) {
      var name = TERMINALDECK_TEST_ATTRS[i]
      var value = el.getAttribute(name)
      if (typeof value === 'string' && value !== '' && value.length <= TERMINALDECK_MAX_IDENT && terminaldeckPrintable(value)) {
        d.testAttr = name
        d.testValue = value
        d.testUnique = terminaldeckUnique('[' + name + '=' + terminaldeckCssString(value) + ']')
        break
      }
    }

    var count = 1
    var index = 1
    var parent = el.parentElement
    if (parent) {
      var kids = parent.children
      count = 0
      for (var j = 0; j < kids.length; j++) {
        var kid = kids[j]
        // :nth-of-type counts by element type, which is local name plus
        // namespace — an <a> in SVG is not an <a> in HTML.
        if (kid.localName === el.localName && kid.namespaceURI === el.namespaceURI) {
          count++
          if (kid === el) index = count
        }
      }
      if (count < 1) count = 1
    }
    d.ofTypeCount = count
    d.nthOfType = index
    return d
  }

  function terminaldeckSecretField(el) {
    // The property wins where it exists — a page can set input.type without
    // touching the attribute — and the attribute covers the fake-DOM case.
    var type = typeof el.type === 'string' && el.type !== '' ? el.type : el.getAttribute('type')
    if (typeof type !== 'string') return false
    var kind = type.toLowerCase()
    // \`file\` belongs here with \`password\`, and was missing. Its value is a path
    // on the user's own disk — /Users/<name>/… names them before it names
    // anything else — and it is the one attribute value \`labelFrom\` reaches for
    // first, so an unnamed file input was captured *as* its path and carried
    // that into the line handed to an agent. Neither field's value is the
    // page's to report, and neither can be replayed from one anyway.
    return kind === 'password' || kind === 'file'
  }

  function terminaldeckAttributes(el) {
    var out = {}
    for (var i = 0; i < TERMINALDECK_ATTR_KEYS.length; i++) {
      var name = TERMINALDECK_ATTR_KEYS[i]
      var value = el.getAttribute(name)
      if (typeof value === 'string' && value !== '') out[name] = terminaldeckFlatten(value, TERMINALDECK_MAX_ATTR)
    }
    // What a control currently holds, which its attribute does not track. Never
    // for a password or file field: that value would be shown in the step list
    // and pasted into a prompt that is written to disk.
    if (typeof el.value === 'string' && el.value !== '' && !terminaldeckSecretField(el)) {
      out.value = terminaldeckFlatten(el.value, TERMINALDECK_MAX_ATTR)
    }
    return out
  }

  function terminaldeckDescribeElement(el) {
    var path = []
    var node = el
    var depth = 0
    while (node && node.nodeType === 1 && depth < TERMINALDECK_MAX_DEPTH) {
      path.push(terminaldeckDescribe(node))
      node = node.parentElement
      depth++
    }
    return {
      v: 1,
      path: path,
      text: terminaldeckFlatten(el.textContent, TERMINALDECK_MAX_TEXT),
      attributes: terminaldeckAttributes(el)
    }
  }
`;
const GUEST_RECORD_CHANNEL = "terminaldeck-browser:set-record";
const GUEST_STEP_CHANNEL = "terminaldeck-browser:step";
const GUEST_RECORD_FILENAME = "browser-record-preload.js";
const NOTABLE_KEYS$1 = ["Enter", "Escape", "Tab"];
const GUEST_RECORD_SOURCE = `'use strict'
/* Generated by Deck from src/main/browser-record-preload.ts. Do not edit — it is overwritten on launch. */
;(function () {
  var ipc = require('electron').ipcRenderer

  var CH_RECORD = ${JSON.stringify(GUEST_RECORD_CHANNEL)}
  var CH_STEP = ${JSON.stringify(GUEST_STEP_CHANNEL)}
  var NOTABLE_KEYS = ${JSON.stringify(NOTABLE_KEYS$1)}
  var MAX_VALUE = 200
${GUEST_DOM_HELPERS_SOURCE}

  var active = false
  var badge = null
  var accent = ''

  /*
   * System colours, not literals. The guest is a different document and cannot
   * read tokens.css, so the badge is drawn in CSS's own \`Canvas\`/\`CanvasText\`
   * — which follow the page's colour scheme — and only takes a real colour when
   * the renderer hands one over, having read it from tokens.css itself.
   *
   * That goes for the shadow too. A literal black one was here first, and it is
   * exactly the bug this comment warns about one line up: invisible against a
   * dark page, which is where the badge most needs its edge. \`color-mix\` keeps
   * it on the system colour, so it inverts with the page.
   */
  var BADGE_STYLE =
    'position:fixed;right:12px;bottom:12px;z-index:2147483647;pointer-events:none;' +
    'display:flex;align-items:center;gap:6px;padding:5px 9px;border-radius:6px;' +
    'font:600 11px/1.2 -apple-system,BlinkMacSystemFont,Segoe UI,system-ui,sans-serif;' +
    'letter-spacing:0.06em;background:Canvas;color:CanvasText;' +
    'border:1px solid CanvasText;' +
    'box-shadow:0 1px 4px color-mix(in srgb, CanvasText 25%, transparent);'

  function ensureBadge() {
    // isConnected, not a null check: a single-page app can replace the whole
    // document, and a detached badge would silently stop being shown while
    // recording carried on.
    if (badge && badge.isConnected) return badge
    var box = document.createElement('div')
    box.setAttribute('data-terminaldeck-recording', '')
    box.setAttribute('aria-hidden', 'true')
    box.style.cssText = BADGE_STYLE
    var dot = document.createElement('span')
    dot.style.cssText =
      'width:8px;height:8px;border-radius:50%;background:' + (accent || 'CanvasText') + ';'
    var text = document.createTextNode('RECORDING')
    box.appendChild(dot)
    box.appendChild(text)
    if (document.documentElement) document.documentElement.appendChild(box)
    badge = box
    return box
  }

  function removeBadge() {
    if (badge && badge.parentNode) badge.parentNode.removeChild(badge)
    badge = null
  }

  function ours(el) {
    // Our own badge, and the inspector's overlay, are not part of the page.
    return !!(el.closest && el.closest('[data-terminaldeck-recording],[data-terminaldeck-inspector]'))
  }

  function inspecting() {
    // The inspector swallows clicks so the user can point at an element without
    // driving the page. Those clicks are not part of any flow, and this overlay
    // is the one signal both scripts can see, sharing a DOM but not a scope.
    return document.querySelector('[data-terminaldeck-inspector]') !== null
  }

  function targetOf(event) {
    var el = event.target
    if (!el || el.nodeType !== 1) return null
    if (ours(el)) return null
    return el
  }

  function send(kind, el, extra) {
    // Re-assert the badge on every step rather than only when recording starts.
    // \`ensureBadge\` checks isConnected, but nothing was calling it again, so a
    // page that removed our node — a framework reconciling documentElement, or a
    // site doing it on purpose — got a recorder with no visible sign of itself.
    // The check is a cheap identity test on a node we already hold.
    ensureBadge()
    var payload = { v: 1, kind: kind, target: terminaldeckDescribeElement(el) }
    if (extra) {
      for (var key in extra) {
        if (Object.prototype.hasOwnProperty.call(extra, key)) payload[key] = extra[key]
      }
    }
    ipc.send(CH_STEP, payload)
  }

  function onClick(event) {
    if (inspecting()) return
    var el = targetOf(event)
    if (!el) return
    send('click', el)
  }

  function onChange(event) {
    if (inspecting()) return
    var el = targetOf(event)
    if (!el) return
    var tag = typeof el.localName === 'string' ? el.localName : ''
    if (tag !== 'input' && tag !== 'textarea' && tag !== 'select') return

    var type = typeof el.type === 'string' ? el.type.toLowerCase() : ''
    if (type === 'password') {
      // The step still exists — a replay has to know a password was entered —
      // but the value never leaves the page.
      send('type', el, { secret: true })
      return
    }
    if (type === 'checkbox' || type === 'radio') {
      send('check', el, { checked: el.checked === true })
      return
    }
    if (type === 'file') {
      // File pickers cannot be replayed and the path is the user's disk.
      send('type', el, { secret: true })
      return
    }
    if (tag === 'select') {
      var option = el.options && el.selectedIndex >= 0 ? el.options[el.selectedIndex] : null
      send('select', el, {
        value: terminaldeckFlatten(option ? option.textContent : el.value, MAX_VALUE)
      })
      return
    }
    send('type', el, { value: terminaldeckFlatten(el.value, MAX_VALUE) })
  }

  function onKeyDown(event) {
    if (inspecting()) return
    if (NOTABLE_KEYS.indexOf(event.key) === -1) return
    var el = targetOf(event)
    if (!el) return
    send('press', el, { key: event.key })
  }

  function onSubmit(event) {
    if (inspecting()) return
    var el = targetOf(event)
    if (!el) return
    send('submit', el)
  }

  // Capture phase so a page that stops propagation on its own handlers cannot
  // hide what the user did; passive so the recorder can never delay or cancel
  // the interaction it is watching.
  var EVENTS = [
    ['click', onClick],
    ['change', onChange],
    ['keydown', onKeyDown],
    ['submit', onSubmit]
  ]
  var OPTIONS = { capture: true, passive: true }

  function enable(nextAccent) {
    accent = typeof nextAccent === 'string' ? nextAccent : ''
    if (active) {
      ensureBadge()
      return
    }
    active = true
    for (var i = 0; i < EVENTS.length; i++) {
      document.addEventListener(EVENTS[i][0], EVENTS[i][1], OPTIONS)
    }
    ensureBadge()
  }

  function disable() {
    if (!active) return
    active = false
    for (var i = 0; i < EVENTS.length; i++) {
      document.removeEventListener(EVENTS[i][0], EVENTS[i][1], OPTIONS)
    }
    removeBadge()
  }

  ipc.on(CH_RECORD, function (event, options) {
    var on = options !== null && typeof options === 'object' ? options.on === true : options === true
    var nextAccent =
      options !== null && typeof options === 'object' && typeof options.accent === 'string'
        ? options.accent
        : ''
    if (on) enable(nextAccent)
    else disable()
  })
})()
`;
function writeRecordPreload(userDataDir) {
  node_fs.mkdirSync(userDataDir, { recursive: true });
  const target2 = node_path.join(userDataDir, GUEST_RECORD_FILENAME);
  node_fs.rmSync(target2, { force: true });
  node_fs.writeFileSync(target2, GUEST_RECORD_SOURCE, { encoding: "utf8", mode: 384, flag: "wx" });
  node_fs.chmodSync(target2, 384);
  return target2;
}
const COLOUR = /^(#[0-9a-fA-F]{3,8}|rgba?\([0-9.,\s%/]{3,64}\))$/;
function safeAccent(value) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  return COLOUR.test(trimmed) ? trimmed : "";
}
const ISOLATED_PREFIX = "terminaldeck-tab-";
const sessions = /* @__PURE__ */ new Map();
let recordPreloadPath = null;
function isIsolationKey(value) {
  return typeof value === "string" && new RegExp(`^${ISOLATED_PREFIX}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`).test(
    value
  );
}
function newIsolationKey() {
  return `${ISOLATED_PREFIX}${node_crypto.randomUUID()}`;
}
function harden(ses) {
  ses.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  ses.setPermissionCheckHandler(() => false);
  ses.on("will-download", (event) => event.preventDefault());
  if (recordPreloadPath === null) recordPreloadPath = writeRecordPreload(electron.app.getPath("userData"));
  ses.registerPreloadScript({ type: "frame", filePath: recordPreloadPath });
  return ses;
}
function isolatedSession(key) {
  if (!isIsolationKey(key)) return null;
  const existing = sessions.get(key);
  if (existing) return existing;
  const ses = harden(electron.session.fromPartition(key));
  sessions.set(key, ses);
  return ses;
}
function isIsolatedGuestSession(candidate) {
  for (const ses of sessions.values()) {
    if (ses === candidate) return true;
  }
  return false;
}
function isolatedSessionCount() {
  return sessions.size;
}
async function disposeIsolatedSession(key) {
  if (!isIsolationKey(key)) return;
  const ses = sessions.get(key);
  sessions.delete(key);
  if (!ses) return;
  try {
    await ses.clearStorageData();
  } catch {
  }
}
function registerBrowserIsolationIpc(ipcMain) {
  ipcMain.handle("browser-isolation:key", () => newIsolationKey());
  ipcMain.handle("browser-isolation:dispose", (_event, key) => disposeIsolatedSession(key));
  ipcMain.handle("browser-isolation:count", () => isolatedSessionCount());
}
const GUEST_PARTITION$1 = "persist:terminaldeck-browser";
const tabs = /* @__PURE__ */ new Map();
const watchedHosts = /* @__PURE__ */ new WeakSet();
let guestPreloadPath = null;
let guestSession$1 = null;
function preloadPath() {
  if (guestPreloadPath === null) guestPreloadPath = writeGuestPreload(electron.app.getPath("userData"));
  return guestPreloadPath;
}
function hardenedGuestSession() {
  if (guestSession$1) return guestSession$1;
  const ses = electron.session.fromPartition(GUEST_PARTITION$1);
  ses.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  ses.setPermissionCheckHandler(() => false);
  ses.on("will-download", (event) => event.preventDefault());
  guestSession$1 = ses;
  return ses;
}
function liveContents(tab) {
  const wc = tab.view.webContents;
  return wc && !wc.isDestroyed() ? wc : null;
}
function stateOf$1(tab) {
  const wc = liveContents(tab);
  const url = wc ? wc.getURL() : "";
  return {
    id: tab.id,
    url: url === BLANK_URL ? "" : url,
    label: shortLabel(url),
    title: wc ? wc.getTitle() : "",
    loading: wc ? wc.isLoading() : false,
    canGoBack: wc ? wc.navigationHistory.canGoBack() : false,
    canGoForward: wc ? wc.navigationHistory.canGoForward() : false,
    inspecting: tab.inspecting,
    error: tab.error
  };
}
function push$1(tab) {
  if (tab.host.isDestroyed()) return;
  tab.host.send("browser:state-changed", stateOf$1(tab));
}
function fail(tab, message) {
  tab.error = message;
  push$1(tab);
}
function sanitizeBounds(raw) {
  const r = typeof raw === "object" && raw !== null ? raw : {};
  const num2 = (value) => typeof value === "number" && Number.isFinite(value) ? Math.round(value) : 0;
  return {
    x: num2(r.x),
    y: num2(r.y),
    width: Math.max(0, num2(r.width)),
    height: Math.max(0, num2(r.height))
  };
}
function applyLayout(tab) {
  if (!liveContents(tab)) return;
  tab.view.setBounds(tab.bounds);
  tab.view.setVisible(tab.visible && tab.bounds.width > 0 && tab.bounds.height > 0);
}
function tellGuest(tab) {
  liveContents(tab)?.send(GUEST_INSPECT_CHANNEL, tab.inspecting);
}
function destroyTab(tab) {
  tabs.delete(tab.id);
  if (!tab.window.isDestroyed()) {
    try {
      tab.window.contentView.removeChildView(tab.view);
    } catch {
    }
  }
  liveContents(tab)?.close();
}
function destroyTabsFor(host) {
  for (const tab of [...tabs.values()]) {
    if (tab.host === host) destroyTab(tab);
  }
}
function requireTab(id2) {
  const tab = typeof id2 === "string" ? tabs.get(id2) : void 0;
  if (!tab) throw new Error("browser: no such tab");
  return tab;
}
function navigate(tab, input) {
  const result = normalizeUrl(input);
  if (!result.ok) {
    tab.error = result.reason;
    return stateOf$1(tab);
  }
  const wc = liveContents(tab);
  if (!wc) return stateOf$1(tab);
  tab.error = null;
  void wc.loadURL(result.url).catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    const still = liveContents(tab);
    if (still && still.getURL() === "") fail(tab, `Could not load that page: ${message}`);
  });
  return stateOf$1(tab);
}
function wireGuestEvents(tab) {
  const wc = tab.view.webContents;
  const refuse2 = (url) => {
    fail(tab, `Blocked a navigation to ${shortLabel(url) || "another scheme"} — only http and https open here.`);
  };
  wc.on("will-navigate", (event, url) => {
    if (isNavigationAllowed(url)) return;
    event.preventDefault();
    refuse2(url);
  });
  wc.on("will-frame-navigate", (details) => {
    if (isNavigationAllowed(details.url)) return;
    details.preventDefault();
    refuse2(details.url);
  });
  wc.on("will-redirect", (event, url) => {
    if (isNavigationAllowed(url)) return;
    event.preventDefault();
    refuse2(url);
  });
  wc.setWindowOpenHandler(({ url }) => {
    fail(tab, `Blocked a pop-up to ${shortLabel(url)}.`);
    return { action: "deny" };
  });
  wc.on("did-start-loading", () => push$1(tab));
  wc.on("did-stop-loading", () => push$1(tab));
  wc.on("page-title-updated", () => push$1(tab));
  wc.on("did-navigate", () => {
    tab.error = null;
    push$1(tab);
  });
  wc.on("did-navigate-in-page", (_event, _url, isMainFrame) => {
    if (isMainFrame) push$1(tab);
  });
  wc.on("dom-ready", () => {
    tellGuest(tab);
    push$1(tab);
  });
  wc.on("did-fail-load", (_event, errorCode2, errorDescription, _url, isMainFrame) => {
    if (!isMainFrame || errorCode2 === -3) return;
    fail(tab, `${errorDescription || "The page failed to load"} (${errorCode2})`);
  });
  wc.on("render-process-gone", (_event, details) => {
    fail(tab, `The page crashed (${details.reason}).`);
  });
  wc.on("unresponsive", () => fail(tab, "The page stopped responding."));
  wc.once("destroyed", () => {
    tabs.delete(tab.id);
  });
}
function isFromMainFrame$1(event, wc) {
  try {
    const frame2 = event.senderFrame;
    return frame2 !== null && frame2 === wc.mainFrame;
  } catch {
    return false;
  }
}
function tabForSender(event) {
  for (const tab of tabs.values()) {
    const wc = liveContents(tab);
    if (!wc || wc.id !== event.sender.id) continue;
    return isFromMainFrame$1(event, wc) ? tab : null;
  }
  return null;
}
function registerBrowserIpc(ipcMain) {
  ipcMain.handle("browser:create", (event, options) => {
    const window = electron.BrowserWindow.fromWebContents(event.sender);
    if (!window) throw new Error("browser: no window to attach to");
    const opts = typeof options === "object" && options !== null ? options : {};
    const view = new electron.WebContentsView({
      webPreferences: {
        // An `isolationKey` means this tab was opened as Isolated and gets its
        // own in-memory partition — see `browser-isolation.ts`. A session is
        // fixed at construction and cannot be swapped afterwards, which is why
        // the choice has to be made here rather than bolted on later.
        preload: preloadPath(),
        session: isolatedSession(opts.isolationKey) ?? hardenedGuestSession(),
        contextIsolation: true,
        nodeIntegration: false,
        nodeIntegrationInSubFrames: false,
        sandbox: true,
        webSecurity: true,
        allowRunningInsecureContent: false,
        experimentalFeatures: false,
        webviewTag: false,
        spellcheck: false,
        safeDialogs: true,
        // A guest alert() would block the app's own window until dismissed.
        disableDialogs: true,
        autoplayPolicy: "user-gesture-required"
      }
    });
    view.setBackgroundColor("#ffffff");
    const tab = {
      id: node_crypto.randomUUID(),
      view,
      host: event.sender,
      window,
      bounds: sanitizeBounds(opts.bounds),
      visible: opts.visible !== false,
      inspecting: false,
      error: null
    };
    tabs.set(tab.id, tab);
    window.contentView.addChildView(view);
    applyLayout(tab);
    wireGuestEvents(tab);
    if (!watchedHosts.has(event.sender)) {
      watchedHosts.add(event.sender);
      event.sender.once("destroyed", () => destroyTabsFor(event.sender));
    }
    if (typeof opts.url === "string" && opts.url.trim() !== "") return navigate(tab, opts.url);
    view.webContents.loadURL(BLANK_URL).catch(() => void 0);
    return stateOf$1(tab);
  });
  ipcMain.handle(
    "browser:navigate",
    (_event, id2, url) => navigate(requireTab(id2), url)
  );
  ipcMain.handle("browser:reload", (_event, id2) => {
    const tab = requireTab(id2);
    tab.error = null;
    liveContents(tab)?.reload();
    return stateOf$1(tab);
  });
  ipcMain.handle("browser:stop", (_event, id2) => {
    const tab = requireTab(id2);
    liveContents(tab)?.stop();
    return stateOf$1(tab);
  });
  ipcMain.handle("browser:back", (_event, id2) => {
    const tab = requireTab(id2);
    const history = liveContents(tab)?.navigationHistory;
    if (history?.canGoBack()) history.goBack();
    return stateOf$1(tab);
  });
  ipcMain.handle("browser:forward", (_event, id2) => {
    const tab = requireTab(id2);
    const history = liveContents(tab)?.navigationHistory;
    if (history?.canGoForward()) history.goForward();
    return stateOf$1(tab);
  });
  ipcMain.handle("browser:inspect", (_event, id2, enabled) => {
    const tab = requireTab(id2);
    tab.inspecting = enabled === true;
    tellGuest(tab);
    return stateOf$1(tab);
  });
  ipcMain.handle("browser:state", (_event, id2) => {
    const tab = typeof id2 === "string" ? tabs.get(id2) : void 0;
    return tab ? stateOf$1(tab) : null;
  });
  ipcMain.handle("browser:close", (_event, id2) => {
    const tab = typeof id2 === "string" ? tabs.get(id2) : void 0;
    if (tab) destroyTab(tab);
  });
  ipcMain.on("browser:bounds", (_event, id2, bounds) => {
    const tab = typeof id2 === "string" ? tabs.get(id2) : void 0;
    if (!tab) return;
    tab.bounds = sanitizeBounds(bounds);
    applyLayout(tab);
  });
  ipcMain.on("browser:visible", (_event, id2, visible) => {
    const tab = typeof id2 === "string" ? tabs.get(id2) : void 0;
    if (!tab) return;
    tab.visible = visible === true;
    applyLayout(tab);
  });
  ipcMain.on(GUEST_ELEMENT_CHANNEL, (event, payload) => {
    const tab = tabForSender(event);
    if (!tab || !tab.inspecting) return;
    const wc = liveContents(tab);
    if (!wc) return;
    const capture = parseCapture(payload, wc.getURL());
    if (!capture) return;
    const message = { ...capture, context: composeAgentContext(capture) };
    if (!tab.host.isDestroyed()) tab.host.send("browser:element", tab.id, message);
  });
  ipcMain.on(GUEST_CANCEL_CHANNEL, (event) => {
    const tab = tabForSender(event);
    if (!tab) return;
    tab.inspecting = false;
    push$1(tab);
  });
}
const BROWSERS = [
  {
    id: "chrome",
    name: "Chrome",
    darwin: "Library/Application Support/Google/Chrome",
    linux: ".config/google-chrome",
    win32: "Google/Chrome/User Data"
  },
  {
    id: "chrome-canary",
    name: "Chrome Canary",
    darwin: "Library/Application Support/Google/Chrome Canary"
  },
  { id: "arc", name: "Arc", darwin: "Library/Application Support/Arc/User Data" },
  {
    id: "edge",
    name: "Edge",
    darwin: "Library/Application Support/Microsoft Edge",
    linux: ".config/microsoft-edge",
    win32: "Microsoft/Edge/User Data"
  },
  {
    id: "brave",
    name: "Brave",
    darwin: "Library/Application Support/BraveSoftware/Brave-Browser",
    linux: ".config/BraveSoftware/Brave-Browser",
    win32: "BraveSoftware/Brave-Browser/User Data"
  },
  {
    id: "vivaldi",
    name: "Vivaldi",
    darwin: "Library/Application Support/Vivaldi",
    linux: ".config/vivaldi",
    win32: "Vivaldi/User Data"
  },
  {
    id: "chromium",
    name: "Chromium",
    darwin: "Library/Application Support/Chromium",
    linux: ".config/chromium",
    win32: "Chromium/User Data"
  }
];
const EXCLUDED_PROFILE_DIRS = /* @__PURE__ */ new Set(["System Profile", "Guest Profile"]);
function candidateProfileDirs() {
  const names = ["Default"];
  for (let i = 1; i <= 40; i += 1) names.push(`Profile ${i}`);
  return names;
}
function compareProfileIds(a, b) {
  if (a === "Default") return -1;
  if (b === "Default") return 1;
  return a.localeCompare(b, void 0, { numeric: true });
}
function userDataDirFor(def, platform = process.platform, home = node_os.homedir(), localAppData = process.env.LOCALAPPDATA) {
  if (platform === "darwin") return node_path.join(home, def.darwin);
  if (platform === "win32") return def.win32 && localAppData ? node_path.join(localAppData, def.win32) : null;
  return def.linux ? node_path.join(home, def.linux) : null;
}
const LOCAL_TLDS = [".local", ".localhost", ".test", ".internal", ".lan"];
function isLoopback(host) {
  if (host === "localhost" || host === "::1" || host === "0.0.0.0") return true;
  return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host);
}
function isPrivateLan(host) {
  const parts = host.split(".");
  if (parts.length !== 4 || !parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)) return false;
  const [a, b] = parts.map(Number);
  if (a === 10) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  return a === 169 && b === 254;
}
function isIpish(host) {
  return /^[\d.]+$/.test(host) || host.includes(":");
}
function bareHost(hostname) {
  const host = hostname.toLowerCase();
  return host.startsWith("[") && host.endsWith("]") ? host.slice(1, -1) : host;
}
function classifyLocalUrl(raw) {
  if (typeof raw !== "string" || raw.length === 0) return null;
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    return null;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
  const host = bareHost(parsed.hostname);
  if (!host) return null;
  const port = parsed.port ? Number(parsed.port) : null;
  parsed.username = "";
  parsed.password = "";
  const reason = isLoopback(host) ? "loopback" : LOCAL_TLDS.some((tld) => host.endsWith(tld)) ? "local-tld" : isPrivateLan(host) ? "private-lan" : port !== null && !host.includes(".") && !isIpish(host) ? "named-host-port" : null;
  if (!reason) return null;
  return { url: parsed.toString(), host, port, reason };
}
function errorCode(err) {
  return err?.code ?? "UNKNOWN";
}
function isBlocked(err) {
  const code = errorCode(err);
  return code === "EPERM" || code === "EACCES";
}
function exists(path) {
  try {
    node_fs.statSync(path);
    return true;
  } catch {
    return false;
  }
}
function parseProfileNames(raw) {
  const out = {};
  if (typeof raw !== "object" || raw === null) return out;
  const profile = raw.profile;
  if (typeof profile !== "object" || profile === null) return out;
  const cache2 = profile.info_cache;
  if (typeof cache2 !== "object" || cache2 === null) return out;
  for (const [dir, value] of Object.entries(cache2)) {
    if (!dir || dir === "__proto__") continue;
    if (typeof value !== "object" || value === null) continue;
    const name = value.name;
    if (typeof name === "string" && name.trim()) out[dir] = name.trim();
  }
  return out;
}
function looksLikeProfile(dir) {
  return exists(node_path.join(dir, "Preferences"));
}
function detectBrowsers() {
  const out = [];
  for (const def of BROWSERS) {
    const userDataDir = userDataDirFor(def);
    if (!userDataDir || !exists(userDataDir)) continue;
    let names = {};
    let access = "ok";
    let note;
    try {
      names = parseProfileNames(JSON.parse(node_fs.readFileSync(node_path.join(userDataDir, "Local State"), "utf8")));
    } catch (err) {
      if (isBlocked(err)) access = "blocked";
      else if (errorCode(err) !== "ENOENT") note = `Could not read Local State (${errorCode(err)}).`;
    }
    let dirs;
    try {
      dirs = node_fs.readdirSync(userDataDir, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name);
    } catch (err) {
      if (isBlocked(err)) access = "blocked";
      dirs = candidateProfileDirs();
    }
    if (access === "blocked") {
      note = "macOS is blocking access to this browser’s data. Grant Full Disk Access to import from it.";
    }
    const profiles = [];
    for (const dir of dirs) {
      if (EXCLUDED_PROFILE_DIRS.has(dir)) continue;
      const path = node_path.join(userDataDir, dir);
      if (!looksLikeProfile(path)) continue;
      profiles.push({
        browserId: def.id,
        browserName: def.name,
        id: dir,
        name: names[dir] ?? dir,
        path,
        access
      });
    }
    profiles.sort((a, b) => compareProfileIds(a.id, b.id));
    if (profiles.length === 0 && access !== "blocked") continue;
    out.push({
      id: def.id,
      name: def.name,
      userDataDir,
      access: profiles.length === 0 && access === "ok" ? "missing" : access,
      note,
      profiles
    });
  }
  return out;
}
const CHROME_EPOCH_OFFSET_MS = 116444736e5;
function chromeTimeToUnixMs(value) {
  const micros = typeof value === "string" ? Number(value) : typeof value === "number" ? value : NaN;
  if (!Number.isFinite(micros) || micros <= 0) return null;
  const ms = Math.round(micros / 1e3) - CHROME_EPOCH_OFFSET_MS;
  return ms > 0 && ms < Date.now() + 864e5 ? ms : null;
}
function collectBookmarkUrls(raw, maxNodes = 5e4) {
  const found = [];
  if (typeof raw !== "object" || raw === null) return found;
  const roots = raw.roots;
  if (typeof roots !== "object" || roots === null) return found;
  const stack = [];
  for (const [key, value] of Object.entries(roots)) {
    if (typeof value === "object" && value !== null) {
      stack.push({ node: value, folder: prettyRoot(key), isRoot: true });
    }
  }
  let visited = 0;
  while (stack.length > 0 && visited < maxNodes) {
    const { node, folder, isRoot } = stack.pop();
    visited += 1;
    if (typeof node.url === "string") {
      const local = classifyLocalUrl(node.url);
      if (local) {
        found.push({
          ...local,
          title: typeof node.name === "string" && node.name.trim() ? node.name.trim() : null,
          folder,
          addedAt: chromeTimeToUnixMs(node.date_added)
        });
      }
      continue;
    }
    if (Array.isArray(node.children)) {
      const name = !isRoot && typeof node.name === "string" && node.name ? node.name : null;
      const next = name ? `${folder}/${name}` : folder;
      for (const child of node.children) {
        if (typeof child === "object" && child !== null) {
          stack.push({ node: child, folder: next, isRoot: false });
        }
      }
    }
  }
  return found;
}
function prettyRoot(key) {
  const named = {
    bookmark_bar: "Bookmarks bar",
    other: "Other bookmarks",
    synced: "Mobile bookmarks"
  };
  return named[key] ?? key;
}
async function defaultOpener(file) {
  const mod = await import("better-sqlite3");
  const candidate = mod.default ?? mod;
  const Database = candidate;
  return new Database(file, { readonly: true, fileMustExist: true });
}
const HISTORY_SQL = "SELECT url, title, last_visit_time, visit_count FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 4000";
const DB_SIDECARS = ["-journal", "-wal", "-shm"];
function snapshotDatabase(source) {
  const dir = node_fs.mkdtempSync(node_path.join(node_os.tmpdir(), "terminaldeck-browser-"));
  const file = node_path.join(dir, "db.sqlite");
  const dispose = () => node_fs.rmSync(dir, { recursive: true, force: true });
  try {
    node_fs.copyFileSync(source, file);
    for (const suffix of DB_SIDECARS) {
      const sidecar = `${source}${suffix}`;
      if (exists(sidecar)) node_fs.copyFileSync(sidecar, `${file}${suffix}`);
    }
  } catch (err) {
    dispose();
    throw err;
  }
  return { file, dispose };
}
async function readHistoryRows(file, open2 = defaultOpener) {
  const snapshot2 = snapshotDatabase(file);
  try {
    const db = await open2(snapshot2.file);
    try {
      return db.prepare(HISTORY_SQL).all();
    } finally {
      db.close();
    }
  } finally {
    snapshot2.dispose();
  }
}
function scanSessionBlob(buffer, limit = 500) {
  const text2 = buffer.toString("latin1");
  const pattern = /https?:\/\/[A-Za-z0-9\-._~:/?#[\]@!$&'()*+,;=%]{1,2000}/g;
  const seen = /* @__PURE__ */ new Set();
  const out = [];
  for (const match of text2.matchAll(pattern)) {
    const url = match[0].replace(/[.,;:'!]+$/, "");
    if (url.length < 12 || seen.has(url)) continue;
    seen.add(url);
    out.push(url);
    if (out.length >= limit) break;
  }
  return out;
}
function sessionStamp(name) {
  const digits = /_(\d+)$/.exec(name)?.[1] ?? "";
  return digits.replace(/^0+(?=\d)/, "");
}
function compareStamps(a, b) {
  if (a.length !== b.length) return a.length - b.length;
  return a < b ? -1 : a > b ? 1 : 0;
}
function listSessionFiles(profilePath) {
  const dir = node_path.join(profilePath, "Sessions");
  let entries2;
  try {
    entries2 = node_fs.readdirSync(dir);
  } catch {
    return [];
  }
  return entries2.filter((name) => name.startsWith("Session_") || name.startsWith("Tabs_")).sort(
    (a, b) => compareStamps(sessionStamp(b), sessionStamp(a)) || b.localeCompare(a, void 0, { numeric: true })
  ).slice(0, 4).map((name) => node_path.join(dir, name));
}
const DEFAULT_SOURCES = ["bookmark", "history", "session"];
const DEFAULT_LIMIT = 200;
const MAX_SESSION_BYTES = 32 * 1024 * 1024;
function problem(browserId, profileId, source, err) {
  const code = errorCode(err);
  const message = isBlocked(err) ? "macOS is blocking access. Grant Full Disk Access to import from this browser." : code === "ENOENT" ? "Nothing to read here." : `${code}: ${err instanceof Error ? err.message : String(err)}`;
  return { browserId, profileId, source, message };
}
function normaliseSources(value) {
  if (!Array.isArray(value)) return DEFAULT_SOURCES;
  return value.filter(
    (item) => DEFAULT_SOURCES.includes(item)
  );
}
async function scanProfile(profile, requested = DEFAULT_SOURCES, options = {}) {
  const sources = normaliseSources(requested);
  const urls = [];
  const problems = [];
  const base = { browserId: profile.browserId, profileId: profile.id };
  if (sources.includes("bookmark")) {
    try {
      const raw = JSON.parse(node_fs.readFileSync(node_path.join(profile.path, "Bookmarks"), "utf8"));
      for (const hit of collectBookmarkUrls(raw)) {
        urls.push({
          ...base,
          url: hit.url,
          host: hit.host,
          port: hit.port,
          title: hit.title,
          source: "bookmark",
          reason: hit.reason,
          detail: hit.folder,
          lastSeen: hit.addedAt
        });
      }
    } catch (err) {
      if (errorCode(err) !== "ENOENT") problems.push(problem(profile.browserId, profile.id, "bookmark", err));
    }
  }
  if (sources.includes("history")) {
    try {
      for (const row of await readHistoryRows(node_path.join(profile.path, "History"), options.openDatabase)) {
        if (typeof row.url !== "string") continue;
        const local = classifyLocalUrl(row.url);
        if (!local) continue;
        const visits = typeof row.visit_count === "number" ? row.visit_count : null;
        urls.push({
          ...base,
          url: local.url,
          host: local.host,
          port: local.port,
          title: typeof row.title === "string" && row.title.trim() ? row.title.trim() : null,
          source: "history",
          reason: local.reason,
          detail: visits === null ? null : `${visits} visit${visits === 1 ? "" : "s"}`,
          lastSeen: chromeTimeToUnixMs(row.last_visit_time)
        });
      }
    } catch (err) {
      if (errorCode(err) !== "ENOENT") problems.push(problem(profile.browserId, profile.id, "history", err));
    }
  }
  if (sources.includes("session")) {
    for (const file of listSessionFiles(profile.path)) {
      try {
        if (node_fs.statSync(file).size > MAX_SESSION_BYTES) continue;
        for (const raw of scanSessionBlob(node_fs.readFileSync(file))) {
          const local = classifyLocalUrl(raw);
          if (!local) continue;
          urls.push({
            ...base,
            url: local.url,
            host: local.host,
            port: local.port,
            title: null,
            source: "session",
            reason: local.reason,
            detail: "Open tab",
            lastSeen: null,
            approximate: true
          });
        }
      } catch (err) {
        if (errorCode(err) !== "ENOENT") {
          problems.push(problem(profile.browserId, profile.id, "session", err));
        }
      }
    }
  }
  return { urls, problems };
}
function dedupeUrls(urls) {
  const rank2 = { bookmark: 3, history: 2, session: 1 };
  const best = /* @__PURE__ */ new Map();
  for (const candidate of urls) {
    const key = candidate.url;
    const current = best.get(key);
    if (!current) {
      best.set(key, { ...candidate });
      continue;
    }
    const candidateWins = rank2[candidate.source] > rank2[current.source];
    const winner = { ...candidateWins ? candidate : current };
    const loser = candidateWins ? current : candidate;
    winner.title = winner.title ?? loser.title;
    winner.lastSeen = winner.lastSeen ?? loser.lastSeen;
    if (!candidate.approximate || !current.approximate) delete winner.approximate;
    best.set(key, winner);
  }
  return [...best.values()].sort((a, b) => {
    if (a.source !== b.source) return rank2[b.source] - rank2[a.source];
    if (a.lastSeen !== b.lastSeen) return (b.lastSeen ?? 0) - (a.lastSeen ?? 0);
    return a.url.localeCompare(b.url);
  });
}
async function scanForDevUrls(request = {}, options = {}) {
  const asked = typeof request === "object" && request !== null ? request : {};
  const browsers = options.browsers ?? detectBrowsers();
  const sources = normaliseSources(asked.sources);
  const wanted = Number(asked.limit);
  const limit = Number.isFinite(wanted) ? Math.max(1, Math.min(Math.floor(wanted), 2e3)) : DEFAULT_LIMIT;
  const urls = [];
  const problems = [];
  for (const browser of browsers) {
    if (asked.browserId && browser.id !== asked.browserId) continue;
    for (const profile of browser.profiles) {
      if (asked.profileId && profile.id !== asked.profileId) continue;
      const found = await scanProfile(profile, sources, options);
      urls.push(...found.urls);
      problems.push(...found.problems);
    }
  }
  return { urls: dedupeUrls(urls).slice(0, limit), problems };
}
function registerChromeImportIpc(ipcMain) {
  ipcMain.handle("chrome-import:browsers", () => detectBrowsers());
  ipcMain.handle("chrome-import:scan", (_e, request = {}) => scanForDevUrls(request));
}
const run$2 = node_util.promisify(node_child_process.execFile);
const AGENT_PURPOSE = {
  claude: "Run Claude Code sessions",
  codex: "Run OpenAI Codex sessions",
  gemini: "Run Gemini CLI sessions"
};
const AGENT_URL = {
  claude: "https://docs.anthropic.com/en/docs/claude-code",
  codex: "https://github.com/openai/codex",
  gemini: "https://github.com/google-gemini/gemini-cli"
};
async function which(bin, PATH, platform = currentPlatform()) {
  const spec = lookupSpec(platform, bin);
  try {
    const { stdout } = await run$2(spec.command, spec.args, {
      env: withPath(process.env, PATH, platform),
      timeout: 4e3
    });
    return firstLookupPath(stdout);
  } catch {
    return null;
  }
}
async function version(bin, PATH, resolved = null, platform = currentPlatform()) {
  const shim = isWindows(platform) && resolved !== null && /\.(cmd|bat)$/i.test(resolved);
  try {
    const { stdout } = await run$2(shim ? resolved : bin, ["--version"], {
      env: withPath(process.env, PATH, platform),
      timeout: 4e3,
      encoding: "utf8",
      shell: shim
    });
    return stdout.trim().split("\n")[0]?.slice(0, 60) || void 0;
  } catch {
    return void 0;
  }
}
async function agentAuth(id2, _PATH, platform = currentPlatform()) {
  if (id2 === "claude") {
    try {
      const credentials = node_path.join(node_os.homedir(), ".claude", ".credentials.json");
      if (node_fs.existsSync(credentials) && node_fs.statSync(credentials).size > 0) return "ready";
    } catch {
      return "unknown";
    }
    if (platform === "darwin") {
      try {
        await run$2("security", ["find-generic-password", "-s", "Claude Code-credentials"], {
          timeout: 3e3
        });
        return "ready";
      } catch {
        return "installed-not-authed";
      }
    }
    return "installed-not-authed";
  }
  return "ready";
}
async function checkPrerequisites() {
  const PATH = await loginPath();
  const tools = [];
  for (const id2 of ["claude", "codex", "gemini"]) {
    const spec = PROVIDERS[id2];
    const found = await which(spec.bin, PATH);
    if (!found) {
      tools.push({
        id: id2,
        label: spec.label,
        state: "missing",
        purpose: AGENT_PURPOSE[id2] ?? spec.label,
        remedy: `Install ${spec.label}, then reopen this window.`,
        url: AGENT_URL[id2],
        required: false
      });
      continue;
    }
    const state = await agentAuth(id2);
    tools.push({
      id: id2,
      label: spec.label,
      state,
      version: await version(spec.bin, PATH, found),
      purpose: AGENT_PURPOSE[id2] ?? spec.label,
      remedy: state === "installed-not-authed" ? `Installed but not signed in. Start a session and run \`${spec.bin}\` — it will walk you through signing in.` : void 0,
      url: AGENT_URL[id2],
      required: false
    });
  }
  for (const [bin, label2, purpose] of [
    ["git", "Git", "Branch and change tracking"],
    ["gh", "GitHub CLI", "Pull requests and issues"]
  ]) {
    const found = await which(bin, PATH);
    tools.push({
      id: bin,
      label: label2,
      state: found ? "ready" : "missing",
      version: found ? await version(bin, PATH, found) : void 0,
      purpose,
      remedy: found ? void 0 : `Optional. Without it, the ${label2} panel stays empty.`,
      url: bin === "gh" ? "https://cli.github.com" : "https://git-scm.com",
      required: false
    });
  }
  const agents = tools.filter((t) => ["claude", "codex", "gemini"].includes(t.id));
  return {
    tools,
    canRunSessions: agents.some((t) => t.state === "ready"),
    // Distinguish "you have nothing" from "you have it, just sign in" — those
    // need completely different instructions.
    needsLogin: !agents.some((t) => t.state === "ready") && agents.some((t) => t.state === "installed-not-authed")
  };
}
function registerPrerequisitesIpc(ipcMain) {
  ipcMain.handle("prereq:check", () => checkPrerequisites());
}
const GUEST_PARTITION = "persist:terminaldeck-browser";
let recorderPreloadId = null;
function guestSession() {
  return electron.session.fromPartition(GUEST_PARTITION);
}
function registerRecorderPreload() {
  if (recorderPreloadId !== null) return;
  const filePath = writeRecordPreload(electron.app.getPath("userData"));
  recorderPreloadId = guestSession().registerPreloadScript({ type: "frame", filePath });
}
function summarizeCookie(cookie) {
  const value = typeof cookie.value === "string" ? cookie.value : "";
  return {
    name: cookie.name,
    domain: cookie.domain ?? "",
    path: cookie.path ?? "/",
    secure: cookie.secure === true,
    httpOnly: cookie.httpOnly === true,
    session: cookie.session === true,
    expiresAt: typeof cookie.expirationDate === "number" ? cookie.expirationDate : null,
    valueBytes: Buffer.byteLength(value, "utf8")
  };
}
function cookieRemovalUrl(cookie) {
  const host = cookie.domain.replace(/^\./, "");
  const scheme = cookie.secure ? "https" : "http";
  const path = cookie.path.startsWith("/") ? cookie.path : `/${cookie.path}`;
  return `${scheme}://${host}${path}`;
}
function groupCookies(cookies) {
  const byDomain = /* @__PURE__ */ new Map();
  for (const cookie of cookies) {
    const key = cookie.domain || "(no domain)";
    const list = byDomain.get(key);
    if (list) list.push(cookie);
    else byDomain.set(key, [cookie]);
  }
  return [...byDomain.entries()].map(([domain, list]) => ({
    domain,
    cookies: [...list].sort((a, b) => a.name.localeCompare(b.name)),
    persistent: list.filter((c) => !c.session).length
  })).sort((a, b) => b.cookies.length - a.cookies.length || a.domain.localeCompare(b.domain));
}
function storageOrigins(domain) {
  if (typeof domain !== "string") return [];
  const trimmed = domain.trim().replace(/^\./, "");
  if (!trimmed) return [];
  const explicit = /^https?:\/\//.test(trimmed);
  try {
    const secure = new URL(explicit ? trimmed : `https://${trimmed}`).origin;
    if (explicit) return [secure];
    const plain = new URL(`http://${trimmed}`).origin;
    return plain === secure ? [secure] : [secure, plain];
  } catch {
    return [];
  }
}
const ALL_STORAGES = [
  "cookies",
  "filesystem",
  "indexdb",
  "localstorage",
  "shadercache",
  "websql",
  "serviceworkers",
  "cachestorage"
];
function registerBrowserSessionIpc(ipcMain) {
  registerRecorderPreload();
  ipcMain.handle("browser-session:info", async () => {
    const ses = guestSession();
    const cookies = await ses.cookies.get({});
    const storagePath = ses.getStoragePath() ?? "";
    return {
      partition: GUEST_PARTITION,
      persistent: ses.isPersistent(),
      storagePath,
      // A partition directory is created on first use, so "not there yet" is
      // the honest answer for a fresh install rather than an error.
      storageExists: storagePath !== "" && node_fs.existsSync(storagePath),
      cookieCount: cookies.length,
      domainCount: new Set(cookies.map((c) => c.domain ?? "")).size,
      cacheBytes: await ses.getCacheSize()
    };
  });
  ipcMain.handle("browser-session:cookies", async () => {
    const cookies = await guestSession().cookies.get({});
    return groupCookies(cookies.map(summarizeCookie));
  });
  ipcMain.handle("browser-session:clear-cookies", async (_event, domain) => {
    const ses = guestSession();
    const wanted = typeof domain === "string" && domain.trim() !== "" ? domain.trim() : null;
    const cookies = await ses.cookies.get(wanted ? { domain: wanted } : {});
    let removed = 0;
    for (const cookie of cookies) {
      const summary = summarizeCookie(cookie);
      try {
        await ses.cookies.remove(cookieRemovalUrl(summary), summary.name);
        removed++;
      } catch {
      }
    }
    await ses.cookies.flushStore();
    return { removed };
  });
  ipcMain.handle("browser-session:clear-storage", async (_event, domain) => {
    const ses = guestSession();
    const origins = storageOrigins(domain);
    if (domain !== void 0 && domain !== null && origins.length === 0) {
      throw new Error("browser-session: that is not a site this can clear");
    }
    if (origins.length === 0) {
      await ses.clearStorageData({ storages: [...ALL_STORAGES] });
    } else {
      for (const origin of origins) {
        await ses.clearStorageData({ origin, storages: [...ALL_STORAGES] });
      }
    }
    await ses.cookies.flushStore();
    return { origins };
  });
  ipcMain.handle("browser-session:clear-cache", async () => {
    await guestSession().clearCache();
  });
}
const SETTINGS_FILE_VERSION = 1;
const MAX_KEYS = 500;
const MAX_KEY_LENGTH = 128;
const MAX_STRING_LENGTH = 4096;
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function sanitizeValues(raw) {
  const out = {};
  if (!isRecord(raw)) return out;
  let kept = 0;
  for (const [key, value] of Object.entries(raw)) {
    if (kept >= MAX_KEYS) break;
    if (key === "__proto__" || key === "" || key.length > MAX_KEY_LENGTH) continue;
    if (typeof value === "boolean") out[key] = value;
    else if (typeof value === "number" && Number.isFinite(value)) out[key] = value;
    else if (typeof value === "string") out[key] = value.slice(0, MAX_STRING_LENGTH);
    else continue;
    kept += 1;
  }
  return out;
}
function applyPatch(current, patch) {
  const next = { ...current };
  if (!isRecord(patch)) return next;
  for (const [key, value] of Object.entries(patch)) {
    if (key === "__proto__" || key === "" || key.length > MAX_KEY_LENGTH) continue;
    if (value === null || value === void 0) {
      delete next[key];
      continue;
    }
    const cleaned = sanitizeValues({ [key]: value });
    if (key in cleaned) next[key] = cleaned[key];
  }
  return sanitizeValues(next);
}
function settingsFile() {
  return node_path.join(electron.app.getPath("userData"), "settings.json");
}
let cache = null;
let carriedForward = {};
let backupBeforeWrite = false;
function load() {
  if (cache) return cache;
  cache = {};
  carriedForward = {};
  backupBeforeWrite = false;
  let text2;
  try {
    text2 = node_fs.readFileSync(settingsFile(), "utf8");
  } catch (cause) {
    backupBeforeWrite = cause?.code !== "ENOENT";
    return cache;
  }
  let raw;
  try {
    raw = JSON.parse(text2);
  } catch {
    backupBeforeWrite = true;
    return cache;
  }
  if (!isRecord(raw)) {
    backupBeforeWrite = true;
    return cache;
  }
  const values = isRecord(raw.values) ? raw.values : raw;
  cache = sanitizeValues(values);
  for (const [key, value] of Object.entries(raw)) {
    if (key !== "version" && key !== "values") carriedForward[key] = value;
  }
  const version2 = raw.version;
  if (typeof version2 === "number" && version2 > SETTINGS_FILE_VERSION) backupBeforeWrite = true;
  return cache;
}
function persist(values) {
  const file = settingsFile();
  node_fs.mkdirSync(node_path.dirname(file), { recursive: true });
  if (backupBeforeWrite) {
    try {
      node_fs.renameSync(file, `${file}.bak-${Date.now()}`);
    } catch {
    }
    backupBeforeWrite = false;
  }
  const payload = { ...carriedForward, version: SETTINGS_FILE_VERSION, values };
  const tmp = `${file}.tmp`;
  node_fs.writeFileSync(tmp, JSON.stringify(payload, null, 2), "utf8");
  node_fs.renameSync(tmp, file);
}
function getStoredSettings() {
  return { version: SETTINGS_FILE_VERSION, values: { ...load() } };
}
function patchStoredSettings(patch) {
  const next = applyPatch(load(), patch);
  persist(next);
  cache = next;
  return { version: SETTINGS_FILE_VERSION, values: { ...next } };
}
function resetStoredSettings() {
  const empty = {};
  carriedForward = {};
  persist(empty);
  cache = empty;
  return { version: SETTINGS_FILE_VERSION, values: {} };
}
function storedValue(key) {
  return load()[key];
}
function configPaths() {
  const userData2 = electron.app.getPath("userData");
  const entries2 = [
    {
      key: "userData",
      label: "App data",
      purpose: "Everything below lives in here.",
      path: userData2,
      kind: "folder"
    },
    {
      key: "settings",
      label: "Settings",
      purpose: "The options in this window.",
      path: node_path.join(userData2, "settings.json"),
      kind: "file"
    },
    {
      key: "state",
      label: "Projects and preferences",
      purpose: "Your project list, theme, default agent and window size.",
      path: node_path.join(userData2, "state.json"),
      kind: "file"
    },
    {
      key: "profiles",
      label: "Profiles",
      purpose: "The list of agent profiles. Logins themselves live in the OS keychain.",
      path: node_path.join(userData2, "profiles.json"),
      kind: "file"
    },
    {
      key: "profilesDir",
      label: "Profile folders",
      purpose: "One config directory per profile this app created.",
      path: node_path.join(userData2, "profiles"),
      kind: "folder"
    },
    {
      key: "logs",
      label: "Logs",
      purpose: "Crash and diagnostic logs written by the runtime.",
      path: electron.app.getPath("logs"),
      kind: "folder"
    }
  ];
  return entries2.map((entry) => ({ ...entry, exists: node_fs.existsSync(entry.path) }));
}
async function openConfigPath(key) {
  const entry = configPaths().find((candidate) => candidate.key === key);
  if (!entry) return { opened: false, path: null, message: "No such location." };
  if (entry.kind === "folder" && !entry.exists) {
    try {
      node_fs.mkdirSync(entry.path, { recursive: true });
    } catch {
      return { opened: false, path: entry.path, message: "That folder does not exist yet." };
    }
  }
  if (entry.kind === "file") {
    if (!node_fs.existsSync(entry.path)) {
      return {
        opened: false,
        path: entry.path,
        message: "That file has not been written yet."
      };
    }
    electron.shell.showItemInFolder(entry.path);
    return { opened: true, path: entry.path, message: "Revealed in your file manager." };
  }
  const error = await electron.shell.openPath(entry.path);
  return error ? { opened: false, path: entry.path, message: error } : { opened: true, path: entry.path, message: "Opened." };
}
function readPackageJson() {
  try {
    const raw = JSON.parse(node_fs.readFileSync(node_path.join(electron.app.getAppPath(), "package.json"), "utf8"));
    return isRecord(raw) ? raw : {};
  } catch {
    return {};
  }
}
function repositoryUrl(field) {
  const raw = typeof field === "string" ? field : isRecord(field) && typeof field.url === "string" ? field.url : null;
  if (!raw) return null;
  const shorthand = /^(?:github:)?([\w.-]+)\/([\w.-]+)$/.exec(raw.trim());
  if (shorthand) return `https://github.com/${shorthand[1]}/${shorthand[2]}`;
  const cleaned = raw.trim().replace(/^git\+/, "").replace(/\.git$/, "").replace(/^git:\/\//, "https://").replace(/^ssh:\/\/git@/, "https://").replace(/^git@([^:]+):/, "https://$1/");
  return /^https?:\/\//.test(cleaned) ? cleaned : null;
}
function updateChannel() {
  const packaged = electron.app.isPackaged;
  const feed = packaged ? node_path.join(process.resourcesPath, "app-update.yml") : node_path.join(electron.app.getAppPath(), "dev-app-update.yml");
  let feedPresent = false;
  try {
    feedPresent = node_fs.statSync(feed).isFile();
  } catch {
    feedPresent = false;
  }
  const verdict = updateSupport(
    {
      platform: process.platform,
      isPackaged: packaged,
      execPath: process.execPath,
      feedConfigPath: feed
    },
    node_fs.existsSync
  );
  return {
    packaged,
    feedPresent,
    checkable: verdict.supported,
    // The unsupported sentence is the updater's own, printed verbatim. A
    // paraphrase here would be a second copy of a message that changes.
    detail: verdict.supported ? "This build is code-signed and carries a release feed, so it could install an update — but nothing in this build checks for one yet. Download new versions from Releases." : verdict.reason
  };
}
function aboutInfo$1() {
  const pkg = readPackageJson();
  return {
    name: BRAND.name,
    tagline: BRAND.tagline,
    version: electron.app.getVersion(),
    electron: process.versions.electron ?? "",
    chromium: process.versions.chrome ?? "",
    node: process.versions.node ?? "",
    platform: process.platform,
    arch: process.arch,
    license: typeof pkg.license === "string" ? pkg.license : null,
    repository: repositoryUrl(pkg.repository),
    homepage: typeof pkg.homepage === "string" ? pkg.homepage : null,
    updates: updateChannel()
  };
}
const BROWSER_PERSIST_KEY = "browser.persistSession";
async function clearBrowsingData() {
  try {
    const guest = electron.session.fromPartition(GUEST_PARTITION);
    await guest.clearStorageData();
    await guest.clearCache();
    await guest.clearAuthCache?.();
    return { cleared: true, message: "Cookies, storage and cache for the browser tab are gone." };
  } catch (error) {
    return {
      cleared: false,
      message: error instanceof Error ? error.message : "Could not clear the browsing data."
    };
  }
}
async function clearBrowserDataIfNotPersisting() {
  if (storedValue(BROWSER_PERSIST_KEY) !== false) {
    return { cleared: false, message: "Browsing data is kept between runs." };
  }
  return clearBrowsingData();
}
function registerSettingsIpc(ipcMain) {
  ipcMain.handle("settings:get", () => getStoredSettings());
  ipcMain.handle(
    "settings:set",
    (_e, patch) => patchStoredSettings(patch)
  );
  ipcMain.handle("settings:reset", () => resetStoredSettings());
  ipcMain.handle("settings:paths", () => configPaths());
  ipcMain.handle("settings:open-path", (_e, key) => openConfigPath(key));
  ipcMain.handle("settings:about", () => aboutInfo$1());
  ipcMain.handle("settings:clear-browser-data", () => clearBrowsingData());
}
const NOTABLE_KEYS = ["Enter", "Escape", "Tab"];
const MAX_STEPS = 200;
const MAX_VALUE = 200;
const MAX_LABEL = 120;
const MAX_URL = 400;
const MAX_FLOW_LINE = 1200;
const CLICK_MERGE_MS = 400;
const EMPTY = {
  selector: "",
  label: "",
  tag: "",
  value: "",
  redacted: false,
  key: "",
  checked: false,
  url: ""
};
const KINDS = /* @__PURE__ */ new Set(["click", "type", "select", "check", "press", "submit"]);
function fieldLabel(capture) {
  const attrs = capture.attributes;
  const named = attrs["aria-label"] || attrs.placeholder || attrs.title || attrs.name;
  return named ? sanitizeLine(named, MAX_LABEL) : "";
}
function isSecretCapture(capture) {
  const type = (capture.attributes.type || "").toLowerCase();
  return type === "password" || type === "file";
}
function parseGuestStep(raw, url, at) {
  if (typeof raw !== "object" || raw === null) return null;
  const payload = raw;
  if (payload.v !== 1) return null;
  const kind = payload.kind;
  if (typeof kind !== "string" || !KINDS.has(kind)) return null;
  const capture = parseCapture(payload.target, url);
  if (!capture) return null;
  const step = {
    ...EMPTY,
    kind,
    selector: capture.selector,
    tag: capture.tag,
    url: capture.url,
    at,
    label: kind === "click" || kind === "submit" ? capture.label : fieldLabel(capture)
  };
  if (kind === "press") {
    const key = typeof payload.key === "string" ? payload.key : "";
    if (!NOTABLE_KEYS.includes(key)) return null;
    step.key = key;
    return step;
  }
  if (kind === "check") {
    step.checked = payload.checked === true;
    return step;
  }
  if (kind === "type" || kind === "select") {
    if (payload.secret === true || isSecretCapture(capture)) {
      step.redacted = true;
      return step;
    }
    step.value = sanitizeLine(payload.value, MAX_VALUE);
    return step;
  }
  return step;
}
function navigateStep(url, at) {
  return { ...EMPTY, kind: "navigate", url: sanitizeLine(url, MAX_URL), at };
}
function sameTarget(a, b) {
  return a.selector !== "" && a.selector === b.selector;
}
function appendStep(steps, next) {
  const last = steps.length > 0 ? steps[steps.length - 1] : null;
  if (last) {
    if ((next.kind === "type" || next.kind === "select") && last.kind === next.kind && sameTarget(last, next)) {
      return [...steps.slice(0, -1), next];
    }
    if (next.kind === "navigate" && last.kind === "navigate" && last.url === next.url) {
      return steps;
    }
    if (next.kind === "click" && last.kind === "click" && sameTarget(last, next) && next.at - last.at < CLICK_MERGE_MS) {
      return steps;
    }
  }
  if (steps.length >= MAX_STEPS) return steps;
  return [...steps, next];
}
function isFull(steps) {
  return steps.length >= MAX_STEPS;
}
function target(step) {
  const named = step.label ? `"${step.label}"` : "";
  const where = step.selector ? `\`${step.selector}\`` : step.tag ? `<${step.tag}>` : "the page";
  return named ? `${named} (${where})` : where;
}
function describeStep(step) {
  switch (step.kind) {
    case "navigate":
      return `Go to ${step.url}`;
    case "click":
      return `Click ${target(step)}`;
    case "type":
      return step.redacted ? `Type the password into ${target(step)}` : `Type "${step.value}" into ${target(step)}`;
    case "select":
      return step.redacted ? `Choose a value in ${target(step)}` : `Choose "${step.value}" in ${target(step)}`;
    case "check":
      return `${step.checked ? "Check" : "Uncheck"} ${target(step)}`;
    case "press":
      return `Press ${step.key} in ${target(step)}`;
    case "submit":
      return `Submit ${target(step)}`;
  }
}
function formatFlow(steps) {
  if (steps.length === 0) return "";
  const lines2 = steps.map((step, index) => `${index + 1}. ${describeStep(step)}`);
  if (isFull(steps)) lines2.push(`(stopped at ${MAX_STEPS} steps)`);
  return lines2.join("\n");
}
function flowLine(steps) {
  if (steps.length === 0) return "";
  const body = steps.map((step, index) => `${index + 1}) ${describeStep(step)}`).join("; ");
  return sanitizeLine(`[browser flow: ${body}]`, MAX_FLOW_LINE);
}
const views = /* @__PURE__ */ new Map();
const unclaimed = [];
let watchingCreations = false;
function isGuest(wc) {
  if (wc.isDestroyed()) return false;
  if (wc.getType() !== "window") return false;
  if (wc.getURL().startsWith("devtools://")) return false;
  return wc.session === guestSession() || isIsolatedGuestSession(wc.session);
}
function watchCreations() {
  if (watchingCreations) return;
  watchingCreations = true;
  electron.app.on("web-contents-created", (_event, contents) => {
    if (!isGuest(contents)) return;
    unclaimed.push(contents);
    contents.once("destroyed", () => {
      const index = unclaimed.indexOf(contents);
      if (index >= 0) unclaimed.splice(index, 1);
    });
  });
}
function claim() {
  for (let i = unclaimed.length - 1; i >= 0; i--) {
    if (!isGuest(unclaimed[i])) unclaimed.splice(i, 1);
  }
  return unclaimed.pop() ?? null;
}
function entryFor(tabId) {
  const entry = typeof tabId === "string" ? views.get(tabId) : void 0;
  if (!entry || entry.wc.isDestroyed()) {
    throw new Error("browser-view: that tab is not open here");
  }
  return entry;
}
function send$1(entry, channel, payload) {
  if (entry.host.isDestroyed()) return;
  entry.host.send(channel, entry.tabId, payload);
}
function stateOf(entry) {
  return {
    recording: entry.recording,
    steps: entry.steps,
    text: formatFlow(entry.steps),
    line: flowLine(entry.steps),
    truncated: isFull(entry.steps)
  };
}
function pushRecording(entry) {
  send$1(entry, "browser-view:recording", stateOf(entry));
}
function record(entry, step) {
  if (!entry.recording || !step) return;
  const next = appendStep(entry.steps, step);
  if (next === entry.steps) return;
  entry.steps = next;
  pushRecording(entry);
}
function tellGuestRecording(entry) {
  if (entry.wc.isDestroyed()) return;
  entry.wc.send(GUEST_RECORD_CHANNEL, { on: entry.recording, accent: entry.accent });
}
function isFromMainFrame(event, wc) {
  try {
    const frame2 = event.senderFrame;
    return frame2 !== null && frame2 === wc.mainFrame;
  } catch {
    return false;
  }
}
function progress(entry, phase, fraction) {
  send$1(entry, "browser-view:progress", { phase, fraction });
}
function attach(entry) {
  const { wc } = entry;
  const onStart = (details) => {
    if (!details.isMainFrame || details.isSameDocument) return;
    progress(entry, "navigating", 0.15);
  };
  const onDom = () => {
    progress(entry, "loading", 0.65);
    if (entry.recording) tellGuestRecording(entry);
  };
  const onStop = () => progress(entry, "done", 1);
  const onNavigate = (_event, url) => {
    record(entry, navigateStep(url, Date.now()));
  };
  wc.on("did-start-navigation", onStart);
  wc.on("dom-ready", onDom);
  wc.on("did-stop-loading", onStop);
  wc.on("did-navigate", onNavigate);
  entry.detach.push(() => {
    if (wc.isDestroyed()) return;
    wc.off("did-start-navigation", onStart);
    wc.off("dom-ready", onDom);
    wc.off("did-stop-loading", onStop);
    wc.off("did-navigate", onNavigate);
  });
  wc.once("destroyed", () => {
    views.delete(entry.tabId);
  });
}
function release(tabId) {
  const entry = views.get(tabId);
  if (!entry) return;
  if (entry.recording) {
    entry.recording = false;
    tellGuestRecording(entry);
  }
  for (const off of entry.detach) off();
  views.delete(tabId);
}
function screenshotDir() {
  return node_path.join(electron.app.getPath("pictures"), BRAND.name);
}
function stamp(now) {
  const pad = (value) => String(value).padStart(2, "0");
  return [
    now.getFullYear(),
    pad(now.getMonth() + 1),
    pad(now.getDate()),
    "-",
    pad(now.getHours()),
    pad(now.getMinutes()),
    pad(now.getSeconds())
  ].join("");
}
function screenshotName(url, now) {
  let host = "";
  try {
    host = new URL(url).host;
  } catch {
    host = "";
  }
  const safe2 = host.replace(/[^a-zA-Z0-9.-]/g, "-").replace(/^[.-]+/, "").slice(0, 48);
  return `${safe2 || "page"}-${stamp(now)}.png`;
}
const ZOOM_MIN = 0.25;
const ZOOM_MAX = 3;
function clampZoom(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return 1;
  return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, value));
}
function registerBrowserViewIpc(ipcMain) {
  watchCreations();
  ipcMain.handle("browser-view:claim", (event, tabId) => {
    if (typeof tabId !== "string" || tabId === "") return { ok: false, reason: "no tab id" };
    if (views.has(tabId)) return { ok: true };
    const wc = claim();
    if (!wc || wc.isDestroyed()) {
      return { ok: false, reason: "no unclaimed browser view — create the tab first" };
    }
    const entry = {
      tabId,
      wc,
      host: event.sender,
      recording: false,
      accent: "",
      steps: [],
      detach: []
    };
    views.set(tabId, entry);
    attach(entry);
    return { ok: true };
  });
  ipcMain.handle("browser-view:release", (_event, tabId) => {
    if (typeof tabId === "string") release(tabId);
  });
  ipcMain.handle("browser-view:zoom", (_event, tabId, factor) => {
    const entry = entryFor(tabId);
    if (factor !== null && factor !== void 0) entry.wc.setZoomFactor(clampZoom(factor));
    return entry.wc.getZoomFactor();
  });
  ipcMain.handle("browser-view:devtools", (_event, tabId) => {
    const entry = entryFor(tabId);
    if (entry.wc.isDevToolsOpened()) {
      entry.wc.closeDevTools();
      return false;
    }
    entry.wc.openDevTools({ mode: "detach" });
    return true;
  });
  ipcMain.handle("browser-view:screenshot", async (_event, tabId) => {
    const entry = entryFor(tabId);
    const image = await entry.wc.capturePage().catch(() => null);
    const size = image?.getSize();
    if (!image || !size || size.width === 0 || size.height === 0) {
      throw new Error("The page has to be on screen to capture it.");
    }
    const dir = screenshotDir();
    await promises.mkdir(dir, { recursive: true });
    const path = node_path.join(dir, screenshotName(entry.wc.getURL(), /* @__PURE__ */ new Date()));
    await promises.writeFile(path, image.toPNG());
    return { path, width: size.width, height: size.height };
  });
  ipcMain.handle("browser-view:reveal", (_event, path) => {
    if (typeof path !== "string") return;
    const full = node_path.resolve(path);
    if (!full.startsWith(screenshotDir() + node_path.sep)) return;
    electron.shell.showItemInFolder(full);
  });
  ipcMain.handle("browser-view:user-agent", (_event, tabId, ua) => {
    const entry = entryFor(tabId);
    const next = typeof ua === "string" && ua.trim() !== "" ? ua.trim() : electron.app.userAgentFallback;
    entry.wc.setUserAgent(next);
    return next;
  });
  ipcMain.handle("browser-view:record", (_event, tabId, options) => {
    const entry = entryFor(tabId);
    const opts = typeof options === "object" && options !== null ? options : {};
    const on = opts.on === true;
    const accent = safeAccent(opts.accent);
    if (accent !== "") entry.accent = accent;
    if (on && !entry.recording) {
      entry.recording = true;
      entry.steps = appendStep(entry.steps, navigateStep(entry.wc.getURL(), Date.now()));
    } else {
      entry.recording = on;
    }
    tellGuestRecording(entry);
    return stateOf(entry);
  });
  ipcMain.handle("browser-view:record-clear", (_event, tabId) => {
    const entry = entryFor(tabId);
    entry.steps = [];
    return stateOf(entry);
  });
  ipcMain.on(GUEST_STEP_CHANNEL, (event, payload) => {
    for (const entry of views.values()) {
      if (entry.wc.isDestroyed() || entry.wc.id !== event.sender.id) continue;
      if (!entry.recording) return;
      if (!isFromMainFrame(event, entry.wc)) return;
      record(entry, parseGuestStep(payload, entry.wc.getURL(), Date.now()));
      return;
    }
  });
}
const REDACTED = "[redacted]";
const USER_PLACEHOLDER = "<user>";
const SECRET_HEADERS = "authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token";
const SECRET_KEY = "[A-Za-z0-9_.\\[\\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\\[\\]-]*";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STRUCTURAL_RULES = [
  {
    // Whole key blocks, not just the header line — the body is the key.
    id: "pem",
    pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
    replace: `-----BEGIN PRIVATE KEY-----${REDACTED}-----END PRIVATE KEY-----`
  },
  {
    id: "pem-other",
    pattern: /-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----/g,
    replace: `-----BEGIN KEY-----${REDACTED}-----END KEY-----`
  },
  {
    // https://user:password@host — the host stays, it is the useful half.
    id: "url-credentials",
    pattern: /\b([a-z][a-z0-9+.-]*:\/\/)[^/\s:@]+:[^/\s@]+@/gi,
    replace: (_match, scheme) => `${scheme}${REDACTED}@`
  },
  {
    id: "header-json",
    pattern: new RegExp(`("(?:${SECRET_HEADERS})"\\s*:\\s*)"[^"]*"`, "gi"),
    replace: (_match, head) => `${head}"${REDACTED}"`
  },
  {
    id: "header-line",
    pattern: new RegExp(`\\b((?:${SECRET_HEADERS})\\s*:\\s*)[^\\r\\n"']+`, "gi"),
    replace: (_match, head) => `${head}${REDACTED}`
  },
  {
    // KEY="value" / "key": "value" — quotes preserved so the shape still reads.
    id: "assignment-quoted",
    pattern: new RegExp(`\\b(${SECRET_KEY})("?\\s*[:=]\\s*)(["'])(?:\\\\.|(?!\\3)[^\\\\])*\\3`, "gi"),
    replace: (_match, key, sep, quote) => `${key}${sep}${quote}${REDACTED}${quote}`
  },
  {
    // The lookahead keeps this off its own output: `TOKEN=[redacted]` would
    // otherwise match again — the value class accepts `[` but not `]` — and
    // every pass would add another bracket.
    id: "assignment-bare",
    pattern: new RegExp(
      `\\b(${SECRET_KEY})(\\s*[:=]\\s*)(?!\\[redacted\\])([^\\s,;)}\\]"']+)`,
      "gi"
    ),
    replace: (_match, key, sep) => `${key}${sep}${REDACTED}`
  },
  {
    // `Bearer …` survives being pulled out of its header and logged alone.
    id: "auth-scheme",
    pattern: /\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}/gi,
    replace: (_match, scheme) => `${scheme} ${REDACTED}`
  },
  {
    id: "user-assignment",
    pattern: /\b(USER|USERNAME|LOGNAME)(\s*[:=]\s*)([A-Za-z0-9._-]+)/g,
    replace: (_match, key, sep) => `${key}${sep}${USER_PLACEHOLDER}`
  }
];
const TOKEN_RULES = [
  { id: "anthropic", pattern: /\bsk-ant-[A-Za-z0-9_-]{10,}/g, replace: REDACTED },
  { id: "openai", pattern: /\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}/g, replace: REDACTED },
  { id: "github", pattern: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}/g, replace: REDACTED },
  { id: "github-pat", pattern: /\bgithub_pat_[A-Za-z0-9_]{20,}/g, replace: REDACTED },
  { id: "gitlab", pattern: /\bglpat-[A-Za-z0-9_-]{16,}/g, replace: REDACTED },
  { id: "slack", pattern: /\bxox[abprse]-[A-Za-z0-9-]{10,}/g, replace: REDACTED },
  { id: "slack-app", pattern: /\bxapp-[0-9]-[A-Za-z0-9-]{10,}/g, replace: REDACTED },
  { id: "slack-webhook", pattern: /https:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9/]+/g, replace: REDACTED },
  { id: "aws", pattern: /\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b/g, replace: REDACTED },
  { id: "google", pattern: /\bAIza[A-Za-z0-9_-]{30,}/g, replace: REDACTED },
  { id: "google-oauth", pattern: /\bya29\.[A-Za-z0-9_-]{10,}/g, replace: REDACTED },
  { id: "stripe", pattern: /\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}/g, replace: REDACTED },
  { id: "npm", pattern: /\bnpm_[A-Za-z0-9]{30,}/g, replace: REDACTED },
  { id: "digitalocean", pattern: /\bdop_v1_[a-f0-9]{40,}/g, replace: REDACTED },
  { id: "huggingface", pattern: /\bhf_[A-Za-z0-9]{20,}/g, replace: REDACTED },
  { id: "supabase", pattern: /\bsbp_[a-f0-9]{20,}/g, replace: REDACTED },
  { id: "shopify", pattern: /\bshp(?:at|ca|pa|ss)_[a-f0-9]{20,}/g, replace: REDACTED },
  { id: "sendgrid", pattern: /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}/g, replace: REDACTED },
  { id: "jwt", pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/g, replace: REDACTED }
];
function entropy(value) {
  if (value.length === 0) return 0;
  const counts = /* @__PURE__ */ new Map();
  for (const char of value) counts.set(char, (counts.get(char) ?? 0) + 1);
  let bits = 0;
  for (const count of counts.values()) {
    const p = count / value.length;
    bits -= p * Math.log2(p);
  }
  return bits;
}
function looksSecret(candidate) {
  if (candidate.length < 32) return false;
  if (UUID.test(candidate)) return false;
  if (!/[0-9]/.test(candidate) || !/[A-Za-z]/.test(candidate)) return false;
  const separators = (candidate.match(/[-_]/g) ?? []).length;
  if (separators > 2) return false;
  return entropy(candidate) >= 3;
}
const CANDIDATE = /[A-Za-z0-9+=_-]{32,}/g;
function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function foldIdentity(text2, home, username) {
  let count = 0;
  let out = text2;
  const bump = () => {
    count += 1;
    return "";
  };
  if (home) {
    out = out.replace(new RegExp(escapeRegExp(home), "g"), () => {
      bump();
      return "~";
    });
  }
  out = out.replace(/(\/Users\/|\/home\/)[A-Za-z0-9._-]+/g, (_match, prefix) => {
    bump();
    return `${prefix}${USER_PLACEHOLDER}`;
  });
  out = out.replace(/([A-Za-z]:\\Users\\)[A-Za-z0-9._-]+/gi, (_match, prefix) => {
    bump();
    return `${prefix}${USER_PLACEHOLDER}`;
  });
  if (username && username.length >= 2) {
    const name = escapeRegExp(username);
    const identity = new RegExp(
      `(?:(?<=^|[\\s/\\\\:~@])${name}(?=[/\\\\@]))|(?:(?<=[/\\\\~@])${name}(?=$|[/\\\\@\\s'"]))`,
      "gm"
    );
    out = out.replace(identity, () => {
      bump();
      return USER_PLACEHOLDER;
    });
  }
  return { text: out, count };
}
function secretsFromEnv(env = process.env) {
  const key = new RegExp(`^${SECRET_KEY}$`, "i");
  const out = [];
  for (const [name, value] of Object.entries(env)) {
    if (typeof value !== "string") continue;
    if (value.length < 8 || value.length > 4096) continue;
    if (key.test(name)) out.push(value);
  }
  return out;
}
function secretEnvNames(env = process.env) {
  const key = new RegExp(`^${SECRET_KEY}$`, "i");
  return Object.keys(env).filter((name) => key.test(name)).sort();
}
function applyRules(text2, rules) {
  let out = text2;
  let count = 0;
  for (const rule of rules) {
    out = out.replace(rule.pattern, (...args) => {
      count += 1;
      if (typeof rule.replace === "string") return rule.replace;
      const groups = args.slice(0, -2).map((g) => typeof g === "string" ? g : "");
      return rule.replace(...groups);
    });
  }
  return { text: out, count };
}
function redactWithCount(text2, options = {}) {
  if (!text2) return { text: text2 ?? "", count: 0 };
  const home = options.home ?? safeHome();
  const username = options.username ?? (home ? home.split(/[/\\]/).filter(Boolean).pop() ?? "" : "");
  let out = text2;
  let count = 0;
  const literals = [...options.extraSecrets ?? []].filter((value) => typeof value === "string" && value.length >= 6).sort((a, b) => b.length - a.length);
  for (const literal of literals) {
    out = out.replace(new RegExp(escapeRegExp(literal), "g"), () => {
      count += 1;
      return REDACTED;
    });
  }
  const structural = applyRules(out, STRUCTURAL_RULES);
  out = structural.text;
  count += structural.count;
  const tokens = applyRules(out, TOKEN_RULES);
  out = tokens.text;
  count += tokens.count;
  out = out.replace(CANDIDATE, (candidate) => {
    if (!looksSecret(candidate)) return candidate;
    count += 1;
    return REDACTED;
  });
  const folded = foldIdentity(out, home, username);
  return { text: folded.text, count: count + folded.count };
}
function redact(text2, options = {}) {
  return redactWithCount(text2, options).text;
}
function redactLines(lines2, options = {}) {
  return lines2.map((line) => redact(line, options));
}
function safeHome() {
  try {
    return node_os.homedir();
  } catch {
    return "";
  }
}
const SECRET_KEY_EXACT = new RegExp(`^${SECRET_KEY}$`, "i");
function redactValue(value, options = {}, seen = /* @__PURE__ */ new WeakSet()) {
  if (typeof value === "string") return redact(value, options);
  if (value === null || typeof value !== "object") return value;
  if (seen.has(value)) return "[circular]";
  seen.add(value);
  try {
    if (Array.isArray(value)) {
      return value.map((item) => redactValue(item, options, seen));
    }
    const out = {};
    for (const [key, item] of Object.entries(value)) {
      out[key] = SECRET_KEY_EXACT.test(key) ? REDACTED : redactValue(item, options, seen);
    }
    return out;
  } finally {
    seen.delete(value);
  }
}
const DEFAULT_MAX_BYTES = 512 * 1024;
const DEFAULT_KEEP = 2;
const MAX_LINE = 4e3;
const LEVEL_WIDTH = 5;
function stringify(data) {
  if (data === void 0) return "";
  if (typeof data === "string") return ` ${data}`;
  try {
    return ` ${JSON.stringify(data)}`;
  } catch {
    return " [unserialisable]";
  }
}
function formatLine(entry) {
  const stamp2 = new Date(entry.at).toISOString();
  const level = entry.level.toUpperCase().padEnd(LEVEL_WIDTH);
  const scope = entry.scope ? `[${entry.scope}] ` : "";
  const line = `${stamp2} ${level} ${scope}${entry.message}${stringify(entry.data)}`.replace(/\r?\n/g, " ");
  return line.length > MAX_LINE ? `${line.slice(0, MAX_LINE)}… (truncated)` : line;
}
class AppLog {
  dir;
  file;
  fileName;
  maxBytes;
  keep;
  now;
  /** Tracked in memory so a stat is not needed on every write. */
  bytes = 0;
  broken = false;
  constructor(options) {
    this.dir = options.dir;
    this.fileName = options.fileName ?? `${BRAND.id}.log`;
    this.file = node_path.join(this.dir, this.fileName);
    this.maxBytes = Math.max(options.maxBytes ?? DEFAULT_MAX_BYTES, 4096);
    this.keep = Math.max(options.keep ?? DEFAULT_KEEP, 0);
    this.now = options.now ?? Date.now;
    this.bytes = this.currentSize();
  }
  currentSize() {
    try {
      return node_fs.statSync(this.file).size;
    } catch {
      return 0;
    }
  }
  generation(index) {
    return node_path.join(this.dir, `${this.fileName}.${index}`);
  }
  /**
   * Shift generations down and start a new file. Failures are swallowed and
   * the log carries on appending — an oversized log beats a lost one.
   */
  rotate() {
    try {
      if (this.keep === 0) {
        node_fs.rmSync(this.file, { force: true });
      } else {
        node_fs.rmSync(this.generation(this.keep), { force: true });
        for (let i = this.keep - 1; i >= 1; i -= 1) {
          if (node_fs.existsSync(this.generation(i))) node_fs.renameSync(this.generation(i), this.generation(i + 1));
        }
        if (node_fs.existsSync(this.file)) node_fs.renameSync(this.file, this.generation(1));
      }
      this.bytes = 0;
    } catch {
      this.bytes = this.currentSize();
    }
  }
  write(level, scope, message, data) {
    if (this.broken) return;
    const line = `${formatLine({ at: this.now(), level, scope, message, data })}
`;
    const size = Buffer.byteLength(line);
    try {
      node_fs.mkdirSync(this.dir, { recursive: true });
      if (this.bytes + size > this.maxBytes) this.rotate();
      node_fs.appendFileSync(this.file, line, "utf8");
      this.bytes += size;
    } catch {
      this.broken = true;
    }
  }
  debug(scope, message, data) {
    this.write("debug", scope, message, data);
  }
  info(scope, message, data) {
    this.write("info", scope, message, data);
  }
  warn(scope, message, data) {
    this.write("warn", scope, message, data);
  }
  error(scope, message, data) {
    this.write("error", scope, message, data);
  }
  /**
   * The last `count` lines, oldest first.
   *
   * Walks back through the rotated generations until it has enough. A busy
   * session can rotate twice in a minute, and a tail that only read the live
   * file would show the last few seconds of a problem that started before it —
   * which is exactly the history the reader came for.
   */
  tail(count = 200) {
    const want = Number.isFinite(count) ? Math.floor(count) : 0;
    if (want <= 0) return [];
    let lines2 = this.readFileLines(this.file);
    for (let i = 1; i <= this.keep && lines2.length < want; i += 1) {
      lines2 = [...this.readFileLines(this.generation(i)), ...lines2];
    }
    return lines2.slice(-want);
  }
  readFileLines(path) {
    try {
      return node_fs.readFileSync(path, "utf8").split("\n").filter((line) => line.length > 0);
    } catch {
      return [];
    }
  }
  status() {
    const files = [];
    const candidates = [this.file, ...Array.from({ length: this.keep }, (_, i) => this.generation(i + 1))];
    for (const path of candidates) {
      try {
        files.push({ name: node_path.basename(path), bytes: node_fs.statSync(path).size });
      } catch {
      }
    }
    return {
      dir: this.dir,
      file: this.file,
      // The live file, not `files[0]` — when the live file is missing the first
      // entry is a rotated generation, and its size would be reported as the
      // current one's.
      bytes: this.currentSize(),
      files,
      maxBytes: this.maxBytes,
      keep: this.keep
    };
  }
  /** Drop everything. Used by the Debug panel before reproducing a bug. */
  clear() {
    try {
      node_fs.rmSync(this.file, { force: true });
      for (let i = 1; i <= this.keep; i += 1) node_fs.rmSync(this.generation(i), { force: true });
      this.bytes = 0;
      this.broken = false;
    } catch {
    }
  }
}
let instance = null;
function appLog() {
  if (!instance) instance = new AppLog({ dir: node_path.join(electron.app.getPath("userData"), "logs") });
  return instance;
}
const logger = {
  debug: (scope, message, data) => appLog().debug(scope, message, data),
  info: (scope, message, data) => appLog().info(scope, message, data),
  warn: (scope, message, data) => appLog().warn(scope, message, data),
  error: (scope, message, data) => appLog().error(scope, message, data)
};
function registerLogIpc(ipcMain) {
  ipcMain.handle("log:recent", (_event, limit) => {
    const log = appLog();
    const count = Math.min(Math.max(Number(limit) || 200, 1), 2e3);
    return { file: redactLines([log.file])[0], lines: redactLines(log.tail(count)) };
  });
  ipcMain.handle("log:status", () => {
    const status = appLog().status();
    return { ...status, dir: redactLines([status.dir])[0], file: redactLines([status.file])[0] };
  });
  ipcMain.handle("log:open-folder", async () => {
    const log = appLog();
    try {
      node_fs.mkdirSync(log.dir, { recursive: true });
    } catch {
    }
    return electron.shell.openPath(log.dir);
  });
  ipcMain.handle("log:clear", () => {
    appLog().clear();
  });
}
function invokeHandlers(ipcMain) {
  const internal = ipcMain._invokeHandlers;
  return internal instanceof Map ? internal : null;
}
function sendChannels(ipcMain) {
  try {
    return ipcMain.eventNames().filter((name) => typeof name === "string").filter((name) => name !== "error");
  } catch {
    return [];
  }
}
function groupChannels(channels) {
  const modules = /* @__PURE__ */ new Map();
  for (const channel of [...channels].sort()) {
    const name = channel.includes(":") ? channel.slice(0, channel.indexOf(":")) : "app";
    const list = modules.get(name) ?? [];
    list.push(channel);
    modules.set(name, list);
  }
  return [...modules.entries()].map(([name, list]) => ({ name, channels: list })).sort((a, b) => a.name.localeCompare(b.name));
}
function ipcInfo(ipcMain) {
  const handlers = invokeHandlers(ipcMain);
  const invoke = handlers ? [...handlers.keys()] : [...recordedChannels];
  const send2 = sendChannels(ipcMain);
  return {
    modules: groupChannels([.../* @__PURE__ */ new Set([...invoke, ...send2])]),
    invokeChannels: invoke.length,
    sendChannels: send2.length,
    instrumented
  };
}
const MAX_RECORDS = 500;
const records = [];
const recordedChannels = /* @__PURE__ */ new Set();
const wrapped = /* @__PURE__ */ new WeakSet();
const subscribers = /* @__PURE__ */ new Map();
function dropSubscriber(contents) {
  const release2 = subscribers.get(contents);
  subscribers.delete(contents);
  try {
    release2?.();
  } catch {
  }
}
let instrumented = false;
let sequence = 0;
function ignored(channel) {
  return channel.startsWith("debug:") || channel === "log:recent";
}
function push(record2) {
  records.push(record2);
  if (records.length > MAX_RECORDS) records.splice(0, records.length - MAX_RECORDS);
  for (const contents of [...subscribers.keys()]) {
    try {
      if (contents.isDestroyed()) {
        dropSubscriber(contents);
        continue;
      }
      contents.send("debug:ipc-call", record2);
    } catch {
      dropSubscriber(contents);
    }
  }
}
function errorText(error) {
  const message = error instanceof Error ? error.message : String(error);
  return redact(message).slice(0, 300);
}
function timed(channel, kind, fn) {
  const wrapper = (...args) => {
    if (ignored(channel)) return fn(...args);
    const started = performance.now();
    const finish = (ok2, error) => {
      try {
        sequence += 1;
        const message = ok2 ? void 0 : errorText(error);
        push({
          seq: sequence,
          channel,
          kind,
          at: Date.now(),
          ms: Math.round((performance.now() - started) * 10) / 10,
          ok: ok2,
          error: message
        });
        if (!ok2) logger.error("ipc", `${channel} failed`, message);
      } catch {
      }
    };
    try {
      const result = fn(...args);
      if (result instanceof Promise) {
        return result.then(
          (value) => {
            finish(true);
            return value;
          },
          (error) => {
            finish(false, error);
            throw error;
          }
        );
      }
      finish(true);
      return result;
    } catch (error) {
      finish(false, error);
      throw error;
    }
  };
  wrapped.add(wrapper);
  wrapper.listener = fn;
  return wrapper;
}
function instrumentIpc(ipcMain) {
  if (instrumented) return true;
  try {
    const handlers = invokeHandlers(ipcMain);
    if (handlers) {
      for (const [channel, handler] of handlers) {
        if (typeof handler !== "function" || wrapped.has(handler)) continue;
        recordedChannels.add(channel);
        const original = handler;
        handlers.set(channel, timed(channel, "invoke", original));
      }
    }
    const originalHandle = ipcMain.handle.bind(ipcMain);
    ipcMain.handle = ((channel, listener) => {
      recordedChannels.add(channel);
      originalHandle(channel, timed(channel, "invoke", listener));
    });
    const originalOn = ipcMain.on.bind(ipcMain);
    ipcMain.on = ((channel, listener) => {
      if (channel === "error") return originalOn(channel, listener);
      return originalOn(channel, timed(channel, "send", listener));
    });
    instrumented = true;
    return true;
  } catch {
    instrumented = false;
    return false;
  }
}
function recentIpcCalls(limit = MAX_RECORDS) {
  return records.slice(-Math.max(1, limit));
}
function clearIpcCalls() {
  records.length = 0;
}
function aboutInfo() {
  return {
    name: BRAND.name,
    tagline: BRAND.tagline,
    version: safe(() => electron.app.getVersion(), "0.0.0"),
    electron: process.versions.electron ?? "n/a",
    chrome: process.versions.chrome ?? "n/a",
    node: process.versions.node,
    v8: process.versions.v8,
    platform: node_os.platform(),
    arch: node_os.arch(),
    packaged: safe(() => electron.app.isPackaged, false)
  };
}
function safe(read, fallback) {
  try {
    return read();
  } catch {
    return fallback;
  }
}
function mb(bytes2) {
  return Math.round(bytes2 / (1024 * 1024));
}
async function collectDiagnostics(options = {}) {
  const redaction = {
    ...options.redaction,
    extraSecrets: [...secretsFromEnv(), ...options.redaction?.extraSecrets ?? []]
  };
  let count = 0;
  const clean2 = (value) => {
    const result = redactWithCount(value, redaction);
    count += result.count;
    return result.text;
  };
  const about = aboutInfo();
  const log = appLog();
  const status = safe(() => log.status(), { dir: "", file: "", bytes: 0, files: [], maxBytes: 0, keep: 0 });
  const clis = options.includeClis === false ? [] : await collectClis();
  const rawPath = await safeLoginPath();
  const userData2 = safe(() => electron.app.getPath("userData"), "");
  const paths = {
    userData: userData2,
    logs: status.dir,
    state: userData2 ? node_path.join(userData2, "state.json") : "",
    temp: safe(() => electron.app.getPath("temp"), ""),
    home: safe(() => electron.app.getPath("home"), ""),
    appPath: safe(() => electron.app.getAppPath(), ""),
    exe: safe(() => electron.app.getPath("exe"), "")
  };
  const preferences = safe(
    () => redactValue(store().getPreferences(), redaction),
    {}
  );
  const bundle = {
    generatedAt: Date.now(),
    app: {
      ...about,
      locale: safe(() => electron.app.getLocale(), "unknown"),
      uptimeSeconds: Math.round(process.uptime())
    },
    system: {
      os: node_os.type(),
      release: node_os.release(),
      arch: node_os.arch(),
      memoryTotalMb: mb(node_os.totalmem()),
      memoryFreeMb: mb(node_os.freemem()),
      processRssMb: mb(process.memoryUsage().rss)
    },
    clis: clis.map((cli) => ({ ...cli, version: cli.version ? clean2(cli.version) : void 0 })),
    ipc: options.ipcMain ? ipcInfo(options.ipcMain) : { modules: [], invokeChannels: 0, sendChannels: 0, instrumented },
    paths: Object.fromEntries(Object.entries(paths).map(([key, value]) => [key, clean2(value)])),
    preferences,
    environment: {
      // Split, because the answer to "why can it not find my CLI" is read one
      // entry at a time and a single 900-character line is unreadable.
      path: rawPath.split(":").filter(Boolean).map(clean2),
      shell: clean2(process.env.SHELL ?? ""),
      term: process.env.TERM ?? "",
      lang: process.env.LANG ?? "",
      secretsPresent: secretEnvNames()
    },
    log: {
      file: clean2(status.file),
      bytes: status.bytes,
      lines: safe(() => log.tail(options.logLines ?? 200), []).map(clean2)
    },
    redaction: { count: 0 }
  };
  bundle.redaction.count = count;
  return bundle;
}
async function collectClis() {
  try {
    const prereq = await checkPrerequisites();
    return prereq.tools.map((tool) => ({
      id: tool.id,
      label: tool.label,
      state: tool.state,
      version: tool.version
    }));
  } catch {
    return [];
  }
}
async function safeLoginPath() {
  try {
    return await loginPath();
  } catch {
    return process.env.PATH ?? "";
  }
}
const CLI_STATE_LABEL = {
  ready: "ready",
  "installed-not-authed": "installed, not signed in",
  missing: "not found",
  unknown: "unknown"
};
function preferenceText(value) {
  if (value === null || typeof value !== "object") return String(value);
  try {
    return JSON.stringify(value) ?? String(value);
  } catch {
    return "[unserialisable]";
  }
}
function formatDiagnostics(bundle) {
  const lines2 = [];
  const section = (title) => {
    lines2.push("", `## ${title}`);
  };
  const row = (label2, value) => {
    lines2.push(`- ${label2}: ${value}`);
  };
  lines2.push(`# ${bundle.app.name} diagnostics`);
  lines2.push(`Generated ${new Date(bundle.generatedAt).toISOString()}`);
  lines2.push(
    `All values below were passed through redaction (${bundle.redaction.count} substitutions).`
  );
  section("App");
  row("version", bundle.app.version);
  row("packaged", bundle.app.packaged);
  row("locale", bundle.app.locale);
  row("uptime", `${bundle.app.uptimeSeconds}s`);
  section("Runtime");
  row("electron", bundle.app.electron);
  row("chrome", bundle.app.chrome);
  row("node", bundle.app.node);
  row("v8", bundle.app.v8);
  row("os", `${bundle.system.os} ${bundle.system.release} (${bundle.system.arch})`);
  row("memory", `${bundle.system.memoryFreeMb} MB free of ${bundle.system.memoryTotalMb} MB`);
  row("process rss", `${bundle.system.processRssMb} MB`);
  section("Agent CLIs");
  if (bundle.clis.length === 0) lines2.push("- not probed");
  for (const cli of bundle.clis) {
    row(cli.label, `${CLI_STATE_LABEL[cli.state]}${cli.version ? ` — ${cli.version}` : ""}`);
  }
  section("IPC");
  row("instrumented", bundle.ipc.instrumented);
  row("invoke channels", bundle.ipc.invokeChannels);
  row("send channels", bundle.ipc.sendChannels);
  for (const module2 of bundle.ipc.modules) {
    row(module2.name, `${module2.channels.length} channel${module2.channels.length === 1 ? "" : "s"}`);
  }
  section("Paths");
  for (const [key, value] of Object.entries(bundle.paths)) row(key, value);
  section("Preferences");
  for (const [key, value] of Object.entries(bundle.preferences)) row(key, preferenceText(value));
  section("Environment");
  row("shell", bundle.environment.shell);
  row("term", bundle.environment.term || "unset");
  row("lang", bundle.environment.lang || "unset");
  row(
    "secret-looking vars set",
    bundle.environment.secretsPresent.length > 0 ? bundle.environment.secretsPresent.join(", ") : "none"
  );
  lines2.push("- PATH:");
  for (const entry of bundle.environment.path) lines2.push(`  - ${entry}`);
  section(`Log (${bundle.log.file}, ${bundle.log.bytes} bytes)`);
  lines2.push("```");
  lines2.push(...bundle.log.lines.length > 0 ? bundle.log.lines : ["(empty)"]);
  lines2.push("```");
  return lines2.join("\n");
}
const MIN_LOG_LINES = 1;
const MAX_LOG_LINES = 2e3;
const DEFAULT_LOG_LINES = 200;
function requestOptions(raw) {
  const input = typeof raw === "object" && raw !== null ? raw : {};
  const asked = input.logLines === void 0 || input.logLines === null ? Number.NaN : Number(input.logLines);
  const logLines = Number.isFinite(asked) ? Math.min(Math.max(Math.floor(asked), MIN_LOG_LINES), MAX_LOG_LINES) : DEFAULT_LOG_LINES;
  return { includeClis: input.includeClis !== false, logLines };
}
function registerDiagnosticsIpc(ipcMain) {
  instrumentIpc(ipcMain);
  ipcMain.handle("debug:about", () => aboutInfo());
  ipcMain.handle(
    "debug:diagnostics",
    async (_event, options) => collectDiagnostics({ ipcMain, ...requestOptions(options) })
  );
  ipcMain.handle(
    "debug:diagnostics-text",
    async (_event, options) => formatDiagnostics(await collectDiagnostics({ ipcMain, ...requestOptions(options) }))
  );
  ipcMain.handle("debug:ipc-log", (_event, limit) => recentIpcCalls(Number(limit) || MAX_RECORDS));
  ipcMain.handle("debug:ipc-clear", () => {
    clearIpcCalls();
  });
  ipcMain.handle("debug:subscribe", (event) => {
    const contents = event.sender;
    if (subscribers.has(contents)) return true;
    const onDestroyed = () => {
      subscribers.delete(contents);
    };
    subscribers.set(contents, () => contents.removeListener("destroyed", onDestroyed));
    contents.once("destroyed", onDestroyed);
    return true;
  });
  ipcMain.handle("debug:unsubscribe", (event) => {
    dropSubscriber(event.sender);
  });
}
const NOISE = ["browser:bounds", "browser:visible"];
function traceIpc(ipcMain, exclude = NOISE) {
  const file = node_path.join(electron.app.getPath("userData"), "ipc-trace.log");
  try {
    node_fs.mkdirSync(node_path.dirname(file), { recursive: true });
  } catch {
  }
  const write = (line) => {
    try {
      node_fs.appendFileSync(file, `${(/* @__PURE__ */ new Date()).toISOString()} ${line}
`);
    } catch {
    }
  };
  write(`--- trace started, all channels except: ${exclude.join(", ")} ---`);
  const originalOn = ipcMain.on.bind(ipcMain);
  ipcMain.on = ((channel, listener) => {
    if (exclude.includes(channel)) return originalOn(channel, listener);
    return originalOn(channel, (event, ...args) => {
      const shown = args.map((a) => JSON.stringify(a)?.slice(0, 200) ?? String(a)).join(", ");
      write(`⇢ ${channel}(${shown})   [send]`);
      return listener(event, ...args);
    });
  });
  const original = ipcMain.handle.bind(ipcMain);
  ipcMain.handle = ((channel, listener) => {
    if (exclude.includes(channel)) return original(channel, listener);
    return original(channel, async (event, ...args) => {
      const shown = args.map((a) => JSON.stringify(a)?.slice(0, 200) ?? String(a)).join(", ");
      write(`→ ${channel}(${shown})`);
      try {
        const result = await listener(event, ...args);
        write(`← ${channel} ok: ${JSON.stringify(result)?.slice(0, 300) ?? "undefined"}`);
        return result;
      } catch (error) {
        write(`✗ ${channel} THREW: ${String(error).slice(0, 300)}`);
        throw error;
      }
    });
  });
}
function buildMenu(getWindow) {
  const send2 = (command) => () => {
    const window = getWindow();
    if (window && !window.isDestroyed()) window.webContents.send("menu:command", command);
  };
  const template = [
    {
      label: BRAND.name,
      submenu: [
        { label: `About ${BRAND.name}`, click: send2("app.about") },
        { type: "separator" },
        // macOS convention: Settings…, ⌘, at the top of the app menu.
        { label: "Settings…", accelerator: "CmdOrCtrl+,", click: send2("app.preferences") },
        { label: "Keyboard Shortcuts", accelerator: "CmdOrCtrl+/", click: send2("app.shortcuts") },
        { type: "separator" },
        { role: "services" },
        { type: "separator" },
        { role: "hide" },
        { role: "hideOthers" },
        { role: "unhide" },
        { type: "separator" },
        { role: "quit" }
      ]
    },
    {
      label: "File",
      submenu: [
        { label: "Open Project…", accelerator: "CmdOrCtrl+O", click: send2("project.open") },
        { type: "separator" },
        { label: "New Session", accelerator: "CmdOrCtrl+T", click: send2("session.new") },
        { label: "New Session…", accelerator: "CmdOrCtrl+Shift+T", click: send2("session.newDialog") },
        { label: "Close Session", accelerator: "CmdOrCtrl+W", click: send2("session.close") }
      ]
    },
    { role: "editMenu" },
    {
      label: "View",
      submenu: [
        { label: "Sessions", click: send2("view.terminal") },
        { label: "Project Overview", click: send2("view.overview") },
        { label: "Task Board", click: send2("view.board") },
        { label: "Browser", click: send2("view.browser") },
        { type: "separator" },
        { label: "Toggle Sidebar", accelerator: "CmdOrCtrl+B", click: send2("view.sidebar") },
        { label: "Swarm View", accelerator: "CmdOrCtrl+\\", click: send2("view.swarm") },
        { type: "separator" },
        { label: "Command Palette", accelerator: "CmdOrCtrl+K", click: send2("app.palette") },
        { label: "Quick Open", accelerator: "CmdOrCtrl+P", click: send2("app.quickOpen") },
        { label: "Search Sessions", accelerator: "CmdOrCtrl+Shift+F", click: send2("panel.search") },
        { label: "Session Inspector", accelerator: "CmdOrCtrl+Shift+I", click: send2("app.inspector") },
        { type: "separator" },
        { role: "reload" },
        { role: "toggleDevTools" },
        { role: "resetZoom" },
        { role: "zoomIn" },
        { role: "zoomOut" },
        { role: "togglefullscreen" }
      ]
    },
    { role: "windowMenu" },
    {
      role: "help",
      submenu: [
        { label: `${BRAND.name} Help`, click: send2("app.help") },
        { label: "Setup & Diagnostics", click: send2("app.setup") },
        { type: "separator" },
        {
          label: "Report an Issue",
          click: () => void electron.shell.openExternal("https://github.com/")
        }
      ]
    }
  ];
  if (process.platform !== "darwin") template.shift();
  electron.Menu.setApplicationMenu(electron.Menu.buildFromTemplate(template));
  electron.app.setAboutPanelOptions({ applicationName: BRAND.name, applicationVersion: electron.app.getVersion() });
}
const run$1 = node_util.promisify(node_child_process.execFile);
const SAFE_BIN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const PROBE_TIMEOUT_MS = 5e3;
const MAX_OUTPUT_CHARS = 240;
const MAX_OUTPUT_LINES = 3;
function clean(text2) {
  return text2.split("\n").map((line) => line.trimEnd()).filter((line) => line.trim() !== "").slice(0, MAX_OUTPUT_LINES).join("\n").slice(0, MAX_OUTPUT_CHARS);
}
function toProbeResult(bin, command, raw) {
  const output = clean(`${raw.stdout ?? ""}
${raw.stderr ?? ""}`);
  const found = raw.exitCode === 0;
  if (found) {
    return {
      command,
      output,
      exitCode: 0,
      found: true,
      line: output !== "" ? output : `${bin} is on your PATH.`
    };
  }
  const status = raw.exitCode < 0 ? "did not finish" : `exited ${raw.exitCode}`;
  return {
    command,
    output,
    exitCode: raw.exitCode,
    found: false,
    // The shell's sentence, verbatim, whenever it wrote one — `copilot not
    // found` is zsh's own wording and repeating it in our words would be a
    // second, slightly different truth.
    line: output !== "" ? output : `${bin} not found (${command} ${status}).`
  };
}
async function probeBinary(bin, PATH, shell = process.env.SHELL || "/bin/zsh", platform = currentPlatform()) {
  const windows = isWindows(platform);
  const spec = lookupSpec(platform, bin);
  const command = windows ? `${spec.command} ${bin}` : `which ${bin}`;
  if (!SAFE_BIN.test(bin)) {
    return {
      command,
      output: "",
      exitCode: -1,
      found: false,
      // Unreachable from the tables that call this; reported rather than thrown
      // so a future caller sees it on screen instead of losing the panel.
      line: `${bin} is not a name this app is willing to run a probe for.`
    };
  }
  const target2 = windows ? spec.command : shell;
  const args = windows ? spec.args : ["-c", command];
  try {
    const { stdout, stderr } = await run$1(target2, args, {
      env: withPath(process.env, PATH, platform),
      timeout: PROBE_TIMEOUT_MS,
      encoding: "utf8"
    });
    return toProbeResult(bin, command, { stdout, stderr, exitCode: 0 });
  } catch (error) {
    const failure2 = error;
    return toProbeResult(bin, command, {
      stdout: failure2.stdout,
      stderr: failure2.stderr,
      exitCode: typeof failure2.code === "number" ? failure2.code : -1
    });
  }
}
async function readVersion(bin, PATH, platform = currentPlatform()) {
  if (!SAFE_BIN.test(bin)) return void 0;
  try {
    const { stdout } = await run$1(bin, ["--version"], {
      // `{ ...process.env, PATH }` would leave Windows holding both `Path` and
      // `PATH`; see `platform/host.ts`.
      env: withPath(process.env, PATH, platform),
      timeout: PROBE_TIMEOUT_MS,
      encoding: "utf8"
    });
    return stdout.trim().split("\n")[0]?.slice(0, 60) || void 0;
  } catch {
    return void 0;
  }
}
const run = node_util.promisify(node_child_process.execFile);
const COPILOT_ID = "copilot";
const COPILOT_BIN = "copilot";
const COPILOT_LABEL = "GitHub Copilot";
const COPILOT_URL = "https://github.com/github/copilot-cli";
const COPILOT_PURPOSE = "Run GitHub Copilot CLI on this machine";
const COPILOT_DIR = ".copilot";
const CREDENTIAL_FILES = ["config.json", "hosts.json", "credentials.json", "auth.json", "apps.json"];
const TOKEN_VARS = ["GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN"];
const TIMEOUT_MS = 5e3;
function hasCopilotExtension(listing) {
  return /(^|\s)gh-copilot(\s|$)/m.test(listing) || /github\/gh-copilot/i.test(listing);
}
function signedIn(input) {
  if (TOKEN_VARS.some((name) => (input.env[name] ?? "").trim() !== "")) return true;
  if (input.copilotDir.some((name) => CREDENTIAL_FILES.includes(name))) return true;
  return input.ghAuthenticated;
}
function copilotDirEntries(home) {
  try {
    return node_fs.readdirSync(node_path.join(home, COPILOT_DIR));
  } catch {
    return [];
  }
}
async function ghAuthenticated(PATH) {
  try {
    await run("gh", ["auth", "status"], { env: { ...process.env, PATH }, timeout: TIMEOUT_MS });
    return true;
  } catch {
    return false;
  }
}
async function ghExtensions(PATH) {
  try {
    const { stdout } = await run("gh", ["extension", "list"], {
      env: { ...process.env, PATH },
      timeout: TIMEOUT_MS,
      encoding: "utf8"
    });
    return stdout;
  } catch {
    return "";
  }
}
async function detectCopilot(PATH, options = {}) {
  const home = options.home ?? node_os.homedir();
  const env = options.env ?? process.env;
  const probe2 = await probeBinary(COPILOT_BIN, PATH);
  const route = probe2.found ? "cli" : hasCopilotExtension(await ghExtensions(PATH)) ? "gh-extension" : null;
  if (route === null) {
    return {
      state: "missing",
      route: null,
      probe: probe2,
      remedy: "Install the GitHub Copilot CLI, then check again."
    };
  }
  const dir = copilotDirEntries(home);
  const authed = signedIn({ env, copilotDir: dir, ghAuthenticated: false }) || await ghAuthenticated(PATH);
  return {
    state: authed ? "ready" : "installed-not-authed",
    route,
    version: route === "cli" ? await readVersion(COPILOT_BIN, PATH) : void 0,
    probe: probe2,
    remedy: authed ? void 0 : route === "gh-extension" ? "Installed as a `gh` extension, but `gh` is not signed in. Run `gh auth login`." : "Installed, but no GitHub sign-in was found. Run `copilot` and use /login — it never happens in this window."
  };
}
function copilotToolStatus(detection) {
  return {
    id: COPILOT_ID,
    label: COPILOT_LABEL,
    state: detection.state,
    version: detection.version,
    purpose: COPILOT_PURPOSE,
    remedy: detection.remedy,
    url: COPILOT_URL,
    // Nothing in the app stops working without it, which is what `required`
    // means here — the same call `prerequisites.ts` makes for every agent CLI.
    required: false
  };
}
const SETUP_TOOL_IDS = ["claude", "codex", "gemini", COPILOT_ID];
const COPILOT_NOTE = "Detected only — this build does not start Copilot sessions yet.";
const COPILOT_HOOK_REASON = "Copilot CLI has no session-hook configuration this app can write, so there is nothing to install.";
function composeSetup(input) {
  const byId = new Map(input.prerequisites.tools.map((tool) => [tool.id, tool]));
  const copilotStatus = copilotToolStatus(input.copilot);
  const tools = SETUP_TOOL_IDS.map((id2) => {
    const status = id2 === COPILOT_ID ? copilotStatus : byId.get(id2) ?? {
      id: id2,
      label: id2,
      state: "unknown",
      purpose: "",
      required: false
    };
    const probe2 = id2 === COPILOT_ID ? input.copilot.probe : input.probes[id2];
    return {
      ...status,
      // A probe next to "Installed" reads as a contradiction — and for Copilot
      // found through `gh` it literally is one, since `which copilot` fails on a
      // machine that has the extension.
      probe: status.state === "missing" && probe2 ? { command: probe2.command, line: probe2.line } : null,
      note: id2 === COPILOT_ID ? COPILOT_NOTE : null
    };
  });
  const hooks = input.hooks.map((status) => ({
    id: status.id,
    label: status.label,
    state: status.state,
    unsupportedReason: null,
    events: HOOK_PROVIDERS[status.id].events,
    installedEvents: status.installedEvents,
    staleEvents: status.staleEvents,
    missingEvents: status.missingEvents,
    file: status.file,
    fileExists: status.fileExists,
    foreignHooks: status.foreignHooks,
    foreignOwners: status.foreignOwners,
    message: status.message,
    requirement: HOOK_PROVIDERS[status.id].requirement
  }));
  hooks.push({
    id: COPILOT_ID,
    label: COPILOT_LABEL,
    state: "unsupported",
    unsupportedReason: COPILOT_HOOK_REASON,
    events: [],
    installedEvents: [],
    staleEvents: [],
    missingEvents: [],
    file: null,
    fileExists: false,
    foreignHooks: 0,
    foreignOwners: [],
    message: COPILOT_HOOK_REASON,
    requirement: null
  });
  return {
    tools,
    // Copilot cannot start a session here, so it does not get a vote on either
    // of these; they stay exactly what `prerequisites.ts` decided.
    canRunSessions: input.prerequisites.canRunSessions,
    needsLogin: input.prerequisites.needsLogin,
    hooks,
    endpoint: { running: input.endpoint !== null, port: input.endpoint?.port ?? null },
    checkedAt: input.now ?? Date.now()
  };
}
function binFor(id2) {
  return id2 === "claude" || id2 === "codex" || id2 === "gemini" ? PROVIDERS[id2].bin : null;
}
async function readSetup() {
  const PATH = await loginPath();
  const prerequisites = await checkPrerequisites();
  const missing = prerequisites.tools.filter((tool) => tool.state === "missing" && binFor(tool.id) !== null).map((tool) => tool.id);
  const [copilot, probed] = await Promise.all([
    detectCopilot(PATH),
    Promise.all(
      missing.map(async (id2) => {
        const bin = binFor(id2);
        return [id2, await probeBinary(bin ?? id2, PATH)];
      })
    )
  ]);
  return composeSetup({
    prerequisites,
    copilot,
    probes: Object.fromEntries(probed),
    hooks: readAllStatus(defaultContext()),
    endpoint: currentHookEndpoint()
  });
}
function registerSetupIpc(ipcMain) {
  ipcMain.handle("setup:status", () => readSetup());
}
const SAFE_STORAGE_ITEMS = {
  chrome: { service: "Chrome Safe Storage", account: "Chrome" },
  "chrome-canary": { service: "Chrome Safe Storage", account: "Chrome" },
  chromium: { service: "Chromium Safe Storage", account: "Chromium" },
  arc: { service: "Arc Safe Storage", account: "Arc" },
  edge: { service: "Microsoft Edge Safe Storage", account: "Microsoft Edge" },
  brave: { service: "Brave Safe Storage", account: "Brave" },
  vivaldi: { service: "Vivaldi Safe Storage", account: "Vivaldi" }
};
const KEYCHAIN_TIMEOUT_MS = 12e4;
function classifyKeychainFailure(code, stderr, timedOut) {
  if (timedOut) return "no-answer";
  const text2 = stderr.toLowerCase();
  if (text2.includes("could not be found") || code === 44) return "not-found";
  if (text2.includes("user canceled") || text2.includes("user cancelled") || code === 128) {
    return "denied";
  }
  if (text2.includes("interaction") || text2.includes("not authorized")) return "denied";
  return "failed";
}
function keychainMessage(reason, browserName) {
  switch (reason) {
    case "not-found":
      return `macOS has no “Safe Storage” keychain item for ${browserName}, so there is no key to decrypt its cookies with. Open ${browserName} once and try again.`;
    case "denied":
      return `The keychain request was denied, so ${browserName}’s cookies stayed encrypted. Nothing was imported. Run the import again and choose Allow to let this app read the key.`;
    case "no-answer":
      return `The keychain asked for permission and nothing answered it, so the import stopped. Run it again and answer the dialog.`;
    case "unsupported":
      return `Importing cookies from ${browserName} is only implemented for macOS, where the key lives in the login keychain.`;
    case "failed":
      return `macOS refused to hand over ${browserName}’s encryption key, so nothing could be decrypted.`;
  }
}
const runSecurity = (file, args) => new Promise((resolve) => {
  node_child_process.execFile(
    file,
    [...args],
    { timeout: KEYCHAIN_TIMEOUT_MS, maxBuffer: 64 * 1024, encoding: "utf8" },
    (error, stdout, stderr) => {
      const err = error;
      const timedOut = Boolean(error && error.killed);
      const code = typeof err?.code === "number" ? err.code : error ? 1 : 0;
      resolve({ code, stdout, stderr, timedOut });
    }
  );
});
async function readSafeStorageKey(browserId, browserName, platform = process.platform, run2 = runSecurity) {
  if (platform !== "darwin") {
    return { ok: false, reason: "unsupported", detail: keychainMessage("unsupported", browserName) };
  }
  const item = SAFE_STORAGE_ITEMS[browserId];
  if (!item) {
    return { ok: false, reason: "not-found", detail: keychainMessage("not-found", browserName) };
  }
  const result = await run2("/usr/bin/security", [
    "find-generic-password",
    "-w",
    "-s",
    item.service,
    "-a",
    item.account
  ]);
  const secret = result.stdout.trim();
  if (result.code === 0 && secret !== "") return { ok: true, secret };
  const reason = classifyKeychainFailure(result.code, result.stderr, result.timedOut);
  return { ok: false, reason, detail: keychainMessage(reason, browserName) };
}
const KEY_SALT = "saltysalt";
const KEY_LENGTH = 16;
const KEY_ITERATIONS_DARWIN = 1003;
const KEY_ITERATIONS_LINUX = 1;
const COOKIE_IV = Buffer.alloc(16, " ");
function deriveCookieKey(secret, platform = process.platform) {
  const rounds = platform === "darwin" ? KEY_ITERATIONS_DARWIN : KEY_ITERATIONS_LINUX;
  return node_crypto.pbkdf2Sync(secret, KEY_SALT, rounds, KEY_LENGTH, "sha1");
}
function unpadPkcs7(block) {
  if (block.length === 0 || block.length % 16 !== 0) return null;
  const pad = block[block.length - 1];
  if (pad < 1 || pad > 16 || pad > block.length) return null;
  for (let i = block.length - pad; i < block.length; i += 1) {
    if (block[i] !== pad) return null;
  }
  return block.subarray(0, block.length - pad);
}
function stripDomainHash(plain, hostKey) {
  if (plain.length < 32) return { value: plain, bound: false };
  const digest = node_crypto.createHash("sha256").update(hostKey, "utf8").digest();
  if (!plain.subarray(0, 32).equals(digest)) return { value: plain, bound: false };
  return { value: plain.subarray(32), bound: true };
}
function decryptCookieValue(blob, key, hostKey) {
  if (blob.length === 0) return { ok: false, reason: "empty" };
  const version2 = blob.subarray(0, 3).toString("latin1");
  if (version2 !== "v10" && version2 !== "v11") return { ok: false, reason: "unsupported-version" };
  const body = blob.subarray(3);
  if (body.length === 0 || body.length % 16 !== 0) return { ok: false, reason: "malformed" };
  let plain;
  try {
    const decipher = node_crypto.createDecipheriv("aes-128-cbc", key, COOKIE_IV);
    decipher.setAutoPadding(false);
    plain = Buffer.concat([decipher.update(body), decipher.final()]);
  } catch {
    return { ok: false, reason: "bad-key" };
  }
  const unpadded = unpadPkcs7(plain);
  if (!unpadded) return { ok: false, reason: "bad-key" };
  const stripped = stripDomainHash(unpadded, hostKey);
  return { ok: true, value: stripped.value.toString("utf8"), bound: stripped.bound };
}
const CHROME_EPOCH_OFFSET_SECONDS = 11644473600;
function cookieExpiryToUnixSeconds(value) {
  const micros = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  if (!Number.isFinite(micros) || micros <= 0) return null;
  const seconds = Math.round(micros / 1e6) - CHROME_EPOCH_OFFSET_SECONDS;
  return seconds > 0 ? seconds : null;
}
function toSameSite(raw, secure) {
  switch (raw) {
    case 0:
      return secure ? "no_restriction" : "unspecified";
    case 1:
      return "lax";
    case 2:
      return "strict";
    default:
      return "unspecified";
  }
}
function toCookieSetDetails(row, value, now) {
  const hostKey = typeof row.host_key === "string" ? row.host_key.trim() : "";
  const name = typeof row.name === "string" ? row.name : "";
  if (hostKey === "" || name === "") return { ok: false, reason: "invalid" };
  const isDomainCookie = hostKey.startsWith(".");
  const host = isDomainCookie ? hostKey.slice(1) : hostKey;
  if (host === "" || /[\s/]/.test(host)) return { ok: false, reason: "invalid" };
  const secure = row.is_secure === 1 || row.is_secure === true;
  const rawPath = typeof row.path === "string" && row.path !== "" ? row.path : "/";
  const path = rawPath.startsWith("/") ? rawPath : `/${rawPath}`;
  let url;
  try {
    url = new URL(`${secure ? "https" : "http"}://${host}${path}`).toString();
  } catch {
    return { ok: false, reason: "invalid" };
  }
  const persistent = row.is_persistent === 1 || row.is_persistent === true;
  const expiresAt = persistent ? cookieExpiryToUnixSeconds(row.expires_utc) : null;
  if (expiresAt !== null && expiresAt * 1e3 <= now) return { ok: false, reason: "expired" };
  const details = {
    url,
    name,
    value,
    path,
    secure,
    httpOnly: row.is_httponly === 1 || row.is_httponly === true,
    sameSite: toSameSite(row.samesite, secure)
  };
  if (isDomainCookie) details.domain = hostKey;
  if (expiresAt !== null) details.expirationDate = expiresAt;
  return { ok: true, details };
}
function cookiesFileFor(profilePath, exists2 = node_fs.existsSync) {
  const candidates = [node_path.join(profilePath, "Network", "Cookies"), node_path.join(profilePath, "Cookies")];
  for (const candidate of candidates) {
    try {
      if (exists2(candidate)) return candidate;
    } catch {
    }
  }
  return null;
}
function listCookieSources(browsers = detectBrowsers(), exists2 = node_fs.existsSync) {
  const out = [];
  for (const browser of browsers) {
    for (const profile of browser.profiles) {
      const path = cookiesFileFor(profile.path, exists2);
      if (!path) continue;
      out.push({
        browserId: browser.id,
        browserName: browser.name,
        profileId: profile.id,
        profileName: profile.name,
        path,
        keychainItem: SAFE_STORAGE_ITEMS[browser.id] !== void 0
      });
    }
  }
  return out;
}
async function openCookieDatabase(file) {
  const mod = await import("better-sqlite3");
  const candidate = mod.default ?? mod;
  const Database = candidate;
  return new Database(file, { readonly: true, fileMustExist: true });
}
const MAX_ROWS = 2e4;
const COOKIE_SQL = `SELECT * FROM cookies LIMIT ${MAX_ROWS}`;
async function readCookieRows(file, open2 = openCookieDatabase) {
  const snapshot2 = snapshotDatabase(file);
  try {
    const db = await open2(snapshot2.file);
    try {
      return db.prepare(COOKIE_SQL).all();
    } finally {
      db.close();
    }
  } finally {
    snapshot2.dispose();
  }
}
const LEDGER_FILE = "browser-imported-cookies.json";
function emptyLedger() {
  return { version: 1, importedAt: null, source: "", entries: [] };
}
function parseLedger(raw) {
  if (typeof raw !== "object" || raw === null) return emptyLedger();
  const record2 = raw;
  const entries2 = Array.isArray(record2.entries) ? record2.entries : [];
  return {
    version: 1,
    importedAt: typeof record2.importedAt === "number" ? record2.importedAt : null,
    source: typeof record2.source === "string" ? record2.source : "",
    entries: entries2.flatMap((entry) => {
      if (typeof entry !== "object" || entry === null) return [];
      const item = entry;
      if (typeof item.name !== "string" || typeof item.domain !== "string") return [];
      return [
        {
          name: item.name,
          domain: item.domain,
          path: typeof item.path === "string" && item.path !== "" ? item.path : "/",
          secure: item.secure === true
        }
      ];
    })
  };
}
function refKey(ref) {
  return [ref.domain, ref.path, ref.name].join("\0");
}
function mergeLedger(current, added, source, at) {
  const byKey = new Map(current.entries.map((entry) => [refKey(entry), entry]));
  for (const entry of added) byKey.set(refKey(entry), entry);
  return { version: 1, importedAt: at, source, entries: [...byKey.values()] };
}
function ledgerPath() {
  return node_path.join(electron.app.getPath("userData"), LEDGER_FILE);
}
function loadLedger() {
  try {
    return parseLedger(JSON.parse(node_fs.readFileSync(ledgerPath(), "utf8")));
  } catch {
    return emptyLedger();
  }
}
function saveLedger(ledger) {
  try {
    node_fs.writeFileSync(ledgerPath(), `${JSON.stringify(ledger, null, 2)}
`, "utf8");
  } catch {
  }
}
function matchesDomain(hostKey, wanted) {
  if (wanted.length === 0) return true;
  const host = hostKey.replace(/^\./, "").toLowerCase();
  return wanted.some((domain) => host === domain || host.endsWith(`.${domain}`));
}
function normaliseDomains(raw) {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((entry) => {
    if (typeof entry !== "string") return [];
    const trimmed = entry.trim().replace(/^\./, "").toLowerCase();
    return trimmed === "" ? [] : [trimmed];
  });
}
function planImport(rows, key, wanted, now) {
  const tally = {
    imported: 0,
    skipped: 0,
    failed: 0,
    bound: 0,
    domains: /* @__PURE__ */ new Set(),
    entries: [],
    details: []
  };
  for (const row of rows) {
    const hostKey = typeof row.host_key === "string" ? row.host_key : "";
    if (hostKey === "" || !matchesDomain(hostKey, wanted)) {
      tally.skipped += 1;
      continue;
    }
    const blob = row.encrypted_value;
    let value;
    if (Buffer.isBuffer(blob) && blob.length > 0) {
      const decrypted = decryptCookieValue(blob, key, hostKey);
      if (!decrypted.ok) {
        tally.failed += 1;
        continue;
      }
      value = decrypted.value;
      if (decrypted.bound) tally.bound += 1;
    } else if (typeof row.value === "string") {
      value = row.value;
    } else {
      tally.failed += 1;
      continue;
    }
    const built = toCookieSetDetails(row, value, now);
    if (!built.ok) {
      if (built.reason === "expired") tally.skipped += 1;
      else tally.failed += 1;
      continue;
    }
    tally.details.push(built.details);
    tally.entries.push({
      name: built.details.name,
      domain: built.details.domain ?? hostKey,
      path: built.details.path,
      secure: built.details.secure
    });
    tally.domains.add(hostKey.replace(/^\./, ""));
    tally.imported += 1;
  }
  return tally;
}
function importMessage(tally, source) {
  if (tally.imported === 0 && tally.details.length > 0) {
    return `Everything in ${source} decrypted, but the browser refused all ${tally.details.length} of the cookies, so nothing was carried over.`;
  }
  if (tally.imported === 0 && tally.failed > 0) {
    return `Nothing could be decrypted from ${source}. The keychain key did not fit its cookie database — that happens when the profile was copied from another Mac.`;
  }
  if (tally.imported === 0) {
    return `${source} had no cookies worth carrying over — everything in it had already expired.`;
  }
  const parts = [
    `Imported ${tally.imported} cookie${tally.imported === 1 ? "" : "s"} across ${tally.domains.size} site${tally.domains.size === 1 ? "" : "s"} from ${source}.`
  ];
  if (tally.failed > 0) {
    parts.push(`${tally.failed} could not be read and were left behind.`);
  }
  parts.push("Tabs set to Isolated do not see them.");
  return parts.join(" ");
}
function sourceLabel(source) {
  return source.profileId === "Default" ? source.browserName : `${source.browserName} — ${source.profileName}`;
}
function pickSource(request, sources) {
  const wanted = sources.filter(
    (source) => (!request.browserId || source.browserId === request.browserId) && (!request.profileId || source.profileId === request.profileId)
  );
  return wanted[0] ?? null;
}
function failure(source, keychain, message) {
  return {
    ok: false,
    browserId: source?.browserId ?? "",
    browserName: source?.browserName ?? "",
    profileId: source?.profileId ?? "",
    imported: 0,
    skipped: 0,
    failed: 0,
    domains: 0,
    keychain,
    message
  };
}
async function importCookies(request, target2 = guestSession(), now = Date.now()) {
  const source = pickSource(request, listCookieSources());
  if (!source) {
    return failure(
      null,
      null,
      "No installed browser with a readable cookie database was found. macOS protects those files until this app has Full Disk Access."
    );
  }
  const label2 = sourceLabel(source);
  const keychain = await readSafeStorageKey(source.browserId, source.browserName);
  if (!keychain.ok) return failure(source, keychain.reason, keychain.detail);
  const key = deriveCookieKey(keychain.secret);
  let rows;
  try {
    rows = await readCookieRows(source.path);
  } catch (err) {
    const code = err?.code;
    const message = code === "EPERM" || code === "EACCES" ? `macOS is blocking access to ${label2}’s cookie database. Grant Full Disk Access to import from it.` : `${label2}’s cookie database could not be opened (${code ?? "unknown error"}).`;
    return failure(source, "ok", message);
  }
  const tally = planImport(rows, key, normaliseDomains(request.domains), now);
  key.fill(0);
  const written = [];
  for (let i = 0; i < tally.details.length; i += 1) {
    try {
      await target2.cookies.set(tally.details[i]);
      written.push(tally.entries[i]);
    } catch {
      tally.imported -= 1;
      tally.failed += 1;
    }
  }
  await target2.cookies.flushStore();
  if (written.length > 0) saveLedger(mergeLedger(loadLedger(), written, label2, now));
  return {
    ok: tally.imported > 0,
    browserId: source.browserId,
    browserName: source.browserName,
    profileId: source.profileId,
    imported: tally.imported,
    skipped: tally.skipped,
    failed: tally.failed,
    domains: tally.domains.size,
    keychain: "ok",
    message: importMessage(tally, label2)
  };
}
async function statusOf(target2) {
  const ledger = loadLedger();
  const live = /* @__PURE__ */ new Set();
  try {
    for (const cookie of await target2.cookies.get({})) {
      live.add(
        refKey({
          name: cookie.name,
          domain: cookie.domain ?? "",
          path: cookie.path ?? "/",
          secure: cookie.secure === true
        })
      );
    }
  } catch {
  }
  return {
    present: ledger.entries.filter((entry) => live.has(refKey(entry))).length,
    recorded: ledger.entries.length,
    importedAt: ledger.importedAt,
    source: ledger.source,
    supported: process.platform === "darwin"
  };
}
async function clearImported(target2) {
  const ledger = loadLedger();
  let removed = 0;
  for (const entry of ledger.entries) {
    try {
      await target2.cookies.remove(
        cookieRemovalUrl({
          name: entry.name,
          domain: entry.domain,
          path: entry.path,
          secure: entry.secure,
          httpOnly: false,
          session: false,
          expiresAt: null,
          valueBytes: 0
        }),
        entry.name
      );
      removed += 1;
    } catch {
    }
  }
  await target2.cookies.flushStore();
  saveLedger(emptyLedger());
  return { removed };
}
function registerCookieImportIpc(ipcMain) {
  ipcMain.handle("cookie-import:sources", () => listCookieSources());
  ipcMain.handle("cookie-import:status", () => statusOf(guestSession()));
  ipcMain.handle("cookie-import:run", (_event, request) => {
    const asked = typeof request === "object" && request !== null ? request : {};
    return importCookies({
      browserId: typeof asked.browserId === "string" ? asked.browserId : void 0,
      profileId: typeof asked.profileId === "string" ? asked.profileId : void 0,
      domains: normaliseDomains(asked.domains)
    });
  });
  ipcMain.handle(
    "cookie-import:clear",
    () => clearImported(guestSession())
  );
}
const isDev = !!process.env.ELECTRON_RENDERER_URL;
let mainWindow = null;
function applySecurityPolicy() {
  const policy = isDev ? "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self' ws: http://localhost:*" : "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self'";
  electron.session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        "Content-Security-Policy": [policy]
      }
    });
  });
}
function send(channel, ...args) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, ...args);
  }
}
const liveStatus = /* @__PURE__ */ new Map();
let updates = null;
const SESSION_CREATED_CHANNEL = "session:created";
const remoteSessions = new SessionFanout({
  list: () => ptys.list(),
  write: (id2, data) => ptys.write(id2, data),
  resize: (id2, cols, rows) => ptys.resize(id2, cols, rows),
  scrollback: (id2) => ptys.scrollback(id2),
  create: remoteSessionCreator({
    // Most-recently-opened first, so a phone that names nothing lands in the
    // project the user was last in rather than in a folder they have forgotten.
    // Live sessions come after: a session can be running in a folder that was
    // never added as a project, and the phone can see it in its own list, so
    // refusing to start a second one beside it would be arbitrary.
    folders: () => [
      ...store().getProjects().map((project) => project.path),
      ...ptys.list().map((session2) => session2.cwd)
    ],
    home: () => electron.app.getPath("home"),
    spawn: async (input) => {
      const meta = await startSession({
        ...input,
        // The phone does not choose an agent — it has no honest way to know
        // which are installed. The desktop's own default is the answer, and it
        // falls back to a plain shell in `startSession` when that CLI is not
        // there, exactly as the window's button does.
        provider: store().getPreferences().defaultProvider
      });
      send(SESSION_CREATED_CHANNEL, meta);
      return meta;
    }
  })
});
const ptys = new PtyManager(
  (id2, data) => {
    notePlanOutput(id2, data);
    remoteSessions.noteData(id2, data);
    send("session:data", id2, data);
  },
  (id2, exitCode) => {
    liveStatus.delete(id2);
    dropPlanSession(id2);
    remoteSessions.noteExit(id2, exitCode);
    send("session:exit", id2, exitCode);
  },
  (id2, status) => {
    liveStatus.set(id2, { status, at: Date.now() });
    remoteSessions.noteStatus(id2, status);
    send("session:status", id2, status);
  }
);
function createWindow() {
  const saved = store().getState().windowBounds;
  mainWindow = new electron.BrowserWindow({
    width: saved?.width ?? 1440,
    height: saved?.height ?? 900,
    x: saved?.x,
    y: saved?.y,
    minWidth: 720,
    minHeight: 480,
    show: false,
    title: BRAND.name,
    backgroundColor: "#0e0f13",
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "default",
    trafficLightPosition: { x: 14, y: 12 },
    webPreferences: {
      preload: node_path.join(__dirname, "../preload/index.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  mainWindow.on("ready-to-show", () => mainWindow?.show());
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
  let boundsTimer;
  const rememberBounds = () => {
    clearTimeout(boundsTimer);
    boundsTimer = setTimeout(() => {
      if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.isMaximized()) {
        store().setWindowBounds(mainWindow.getNormalBounds());
      }
    }, 400);
  };
  mainWindow.on("resize", rememberBounds);
  mainWindow.on("move", rememberBounds);
  if (isDev) {
    mainWindow.webContents.on("console-message", (event) => {
      if (event.level === "error" || event.level === "warning") {
        console.error(`[renderer] ${event.message}  (${event.sourceId}:${event.lineNumber})`);
      }
    });
    mainWindow.webContents.on(
      "did-fail-load",
      (_e, code, desc) => console.error(`[renderer] failed to load: ${desc} (${code})`)
    );
  }
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void electron.shell.openExternal(url);
    return { action: "deny" };
  });
  if (process.env.ELECTRON_RENDERER_URL) {
    void mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    void mainWindow.loadFile(node_path.join(__dirname, "../renderer/index.html"));
  }
}
async function startSession(input) {
  const path = await loginPath();
  const available = await detectProviders();
  const requested = input.provider ?? "claude";
  const provider = available[requested] ? requested : "shell";
  const spec = PROVIDERS[provider];
  const profile = resolveProfile(getState(), {
    sessionProfileId: input.profileId ?? void 0,
    projectPath: input.cwd
  });
  return ptys.create(input, {
    provider,
    command: spec.spawn.command,
    args: input.resume && spec.spawn.resumeArgs.length > 0 ? spec.spawn.resumeArgs : spec.spawn.args,
    path,
    env: sessionEnv(profile, provider)
  });
}
function registerIpc() {
  traceIpc(electron.ipcMain);
  electron.ipcMain.handle("brand:get", () => ({ name: BRAND.name, tagline: BRAND.tagline }));
  electron.ipcMain.handle("project:pick", async () => {
    if (!mainWindow) return null;
    const { canceled, filePaths } = await electron.dialog.showOpenDialog(mainWindow, {
      properties: ["openDirectory", "createDirectory"],
      title: "Open project",
      buttonLabel: "Open"
    });
    return canceled || filePaths.length === 0 ? null : filePaths[0];
  });
  electron.ipcMain.handle("providers:detect", () => detectProviders());
  electron.ipcMain.handle("projects:list", () => store().getProjects());
  electron.ipcMain.handle("projects:add", (_e, path) => store().addProject(path));
  electron.ipcMain.handle("projects:remove", (_e, path) => store().removeProject(path));
  electron.ipcMain.handle("prefs:get", () => store().getPreferences());
  electron.ipcMain.handle("prefs:set", (_e, patch) => store().setPreferences(patch));
  registerCostIpc(electron.ipcMain);
  registerGitIpc(electron.ipcMain);
  registerFsIpc(electron.ipcMain);
  registerBoardIpc(electron.ipcMain);
  registerSearchIpc(electron.ipcMain, {
    isAllowedRoot: (root) => store().getProjects().some((p) => p.path === root)
  });
  registerInsightsIpc(electron.ipcMain);
  registerChatIpc(electron.ipcMain);
  registerDevPortsIpc(electron.ipcMain);
  registerAgentControlsIpc(electron.ipcMain, ptys);
  registerPlanLimitIpc(electron.ipcMain, { write: (id2, data) => ptys.write(id2, data) });
  updates = registerUpdateIpc(electron.ipcMain, {
    updater: electronUpdater.autoUpdater,
    // Squirrel refuses an unsigned bundle, which is this build. The manual
    // path does the same job without it: read the public feed, verify the
    // archive's sha512, swap the bundle. Supplied on macOS only.
    manual: process.platform === "darwin" ? createManualStrategy({
      feedUrl: "https://github.com/asadev/terminaldeck/releases/latest/download/latest-mac.yml",
      userDataPath: electron.app.getPath("userData"),
      currentVersion: electron.app.getVersion(),
      platform: process.platform,
      exePath: electron.app.getPath("exe")
    }) : void 0,
    environment: {
      platform: process.platform,
      isPackaged: electron.app.isPackaged,
      execPath: process.execPath,
      feedConfigPath: electron.app.isPackaged ? node_path.join(process.resourcesPath, "app-update.yml") : node_path.join(electron.app.getAppPath(), "dev-app-update.yml")
    },
    broadcast: (channel, state) => send(channel, state)
  });
  registerTailnetIpc(electron.ipcMain, { certDir: node_path.join(electron.app.getPath("userData"), "tailnet-certs") });
  const remote = registerRemoteIpc(electron.ipcMain, {
    sessions: remoteSessions,
    webRoot: node_path.join(electron.app.getAppPath(), "pwa", "dist"),
    storageDir: node_path.join(electron.app.getPath("userData"), "remote"),
    // Where a photo or a file sent from a phone lands. The user's downloads
    // folder, in a folder named after the app — somewhere a person already looks,
    // rather than application support, which they never do and which an
    // uninstall takes with it. Passing it is also what advertises the capability;
    // see `RemoteEndpointOptions.uploadsDir`.
    uploadsDir: node_path.join(electron.app.getPath("downloads"), BRAND.name),
    broadcast: (channel, payload) => send(channel, payload)
  });
  electron.powerMonitor.on("resume", () => remote.server.wake());
  registerGitHubIpc(electron.ipcMain);
  registerReadinessIpc(electron.ipcMain);
  registerDashboardIpc(electron.ipcMain);
  registerSessionSearchIpc(electron.ipcMain);
  registerProfilesIpc(electron.ipcMain);
  registerDeckignoreIpc(electron.ipcMain);
  registerHooksIpc(electron.ipcMain);
  registerMcpIpc(electron.ipcMain);
  registerBrowserIpc(electron.ipcMain);
  registerChromeImportIpc(electron.ipcMain);
  registerPrerequisitesIpc(electron.ipcMain);
  registerSetupIpc(electron.ipcMain);
  registerCookieImportIpc(electron.ipcMain);
  registerBrowserIsolationIpc(electron.ipcMain);
  registerSettingsIpc(electron.ipcMain);
  registerBrowserSessionIpc(electron.ipcMain);
  registerBrowserViewIpc(electron.ipcMain);
  registerDiagnosticsIpc(electron.ipcMain);
  registerLogIpc(electron.ipcMain);
  registerAlertsIpc(electron.ipcMain, {
    liveSessions: (projectPath2) => ptys.list().filter((meta) => meta.cwd === projectPath2).map((meta) => ({
      sessionId: meta.id,
      cwd: meta.cwd,
      status: liveStatus.get(meta.id)?.status ?? "idle",
      statusSince: liveStatus.get(meta.id)?.at,
      provider: meta.provider
    })),
    defaultProvider: () => store().getPreferences().defaultProvider
  });
  electron.ipcMain.handle("session:create", (_e, input) => startSession(input));
  electron.ipcMain.on("session:write", (_e, id2, data) => ptys.write(id2, data));
  electron.ipcMain.on("session:resize", (_e, id2, cols, rows) => {
    notePlanResize(id2, cols, rows);
    ptys.resize(id2, cols, rows);
  });
  electron.ipcMain.handle("session:scrollback", (_e, id2) => ptys.scrollback(id2));
  electron.ipcMain.handle("session:kill", (_e, id2) => ptys.kill(id2));
  electron.ipcMain.handle("session:list", () => ptys.list());
}
pinUserData(electron.app);
electron.app.whenReady().then(() => {
  if (process.platform === "darwin") electron.app.setName(BRAND.name);
  applySecurityPolicy();
  registerIpc();
  void registerHookServer(electron.ipcMain).catch(
    (err) => console.error("[hook-server] failed to start, hook callbacks disabled:", err)
  );
  createWindow();
  buildMenu(() => mainWindow);
  electron.app.on("activate", () => {
    if (electron.BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});
electron.app.on("window-all-closed", () => {
  if (process.platform !== "darwin") electron.app.quit();
});
electron.app.on("before-quit", () => {
  ptys.killAll();
  stopAllGitWatches();
  updates?.stop();
  void stopHookServer();
  void clearBrowserDataIfNotPersisting();
});
