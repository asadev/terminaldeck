/**
 * Drive the Machines → Servers area without Electron and without a server.
 *
 *     npx vite --config .harness/vite.config.ts --port 5219
 *     open http://localhost:5219/servers.html
 *
 * Unlike `remote.tsx`, this is not a wall of fixtures: the whole point of this
 * area is the *sequence* — add a server, land on its page, press something,
 * read what it says, go one door further in — and a fixture per state cannot
 * show that. So the bridge below is a fake one that answers the same shapes the
 * real channels answer, and everything above it is the real component.
 *
 * It answers slowly on purpose. Every one of these calls crosses the internet in
 * the real thing, and a harness that answers instantly hides every state that
 * exists only while somebody is waiting.
 *
 * The device half of the page renders its own "not in this build" notice here,
 * which is correct: there is no preload under this harness, and that is exactly
 * what the panel is supposed to say when the channels are absent.
 */
import { createRoot } from 'react-dom/client'
import { MachinesPanel } from '../src/renderer/machines/MachinesPanel'
import type { ServersBridge } from '../src/renderer/machines/servers/types'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/settings/SettingsWindow.css'
import '../src/renderer/shell/shell.css'
/* The terminal's own stylesheet, which the real window loads once in
   `main.tsx`. Without it a shell renders as an empty rectangle with a stray
   input box in the corner — which is what this harness showed until it was
   added, and is exactly the class of defect a harness exists to catch. */
import '@xterm/xterm/css/xterm.css'

const NOW = Date.now()

/** A pause, so the states that only exist while waiting are visible. */
function after<T>(value: T, ms = 600): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms))
}

interface Row {
  id: string
  name: string
  address: string
  username: string
  credential: 'password' | 'key' | 'none'
  hostKey: { algorithm: string; fingerprint: string; firstSeenAt: number }
}

const rows: Row[] = [
  {
    id: 's1',
    name: 'Shop',
    address: 'shop.example.com',
    username: 'admin',
    credential: 'key',
    hostKey: {
      algorithm: 'ssh-ed25519',
      fingerprint: 'SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0',
      firstSeenAt: NOW,
    },
  },
  {
    id: 's2',
    name: 'The little one',
    address: '203.0.113.10',
    username: 'deploy',
    credential: 'password',
    hostKey: { algorithm: 'ssh-ed25519', fingerprint: 'SHA256:2Ab9cD…', firstSeenAt: NOW },
  },
]

function fact<T>(value: T, how: string): unknown {
  return { known: 'yes', value, measuredAt: NOW - 20 * 60_000, how }
}

function cannot(why: string): unknown {
  return { known: 'cannot', measuredAt: NOW - 20 * 60_000, why }
}

/**
 * The operating system talking to itself, as `systemctl` really lists it.
 *
 * Copied from the box the servers feature was walked against on 2026-08-18.
 * Nobody here set any of these up, which is why they are the remainder — and
 * why none of them has a Stop button any more.
 */
const OS_UNITS = [
  'apparmor', 'apport', 'atd', 'blkmapd', 'chrony', 'cloud-config', 'cloud-final',
  'cloud-init', 'cloud-init-local', 'console-setup', 'cron', 'dbus', 'dmesg',
  'e2scrub_reap', 'finalrd', 'getty@tty1', 'irqbalance', 'keyboard-setup',
  'kmod-static-nodes', 'lvm2-monitor', 'multipathd', 'networkd-dispatcher',
  'open-vm-tools', 'polkit', 'rpcbind', 'rsyslog', 'setvtrgb', 'snapd',
  'snapd.apparmor', 'snapd.seeded', 'ssh', 'systemd-binfmt', 'systemd-journald',
  'systemd-journal-flush', 'systemd-logind', 'systemd-modules-load',
  'systemd-networkd', 'systemd-random-seed', 'systemd-remount-fs',
  'systemd-resolved', 'systemd-sysctl', 'systemd-sysusers', 'systemd-timesyncd',
  'systemd-tmpfiles-setup', 'systemd-udevd', 'systemd-udev-trigger',
  'systemd-user-sessions', 'ufw', 'unattended-upgrades', 'user@0', 'uuidd',
]

/** What the main process now answers for every one of them. See `actions.ts`. */
const NOT_YOURS_TO_STOP =
  'We can’t tell whether you set this up, so this app doesn’t offer to start or stop it. ' +
  'The terminal under Advanced can, if you know you need to.'

/** The full box: a website, a worker, a database, and the operating system. */
const SHOP = {
  cards: [
    {
      id: 'site-shop',
      kind: 'site',
      name: 'Your website',
      detail: 'Served by nginx',
      running: true,
      url: 'https://shop.example.com',
    },
    {
      id: 'app-worker',
      kind: 'app',
      name: 'Order emails',
      detail: 'Running in a container',
      running: false,
      url: null,
    },
    {
      id: 'db-main',
      kind: 'database',
      name: 'Shop records',
      detail: 'PostgreSQL, in a container',
      running: true,
      url: null,
    },
    /*
     * The remainder, at the size it really is.
     *
     * These are the unit names off the Ubuntu box this feature was walked
     * against. One token `other` card made the group look like a footnote; it
     * is fifty rows, it is the largest thing on the page by a factor of ten,
     * and until 2026-08-18 every one of them carried Restart and Stop. A
     * harness that shows one of them cannot show either the wall or the door
     * that now stands in front of it.
     */
    ...OS_UNITS.map((name) => ({
      id: `other-${name}`,
      kind: 'other' as const,
      name,
      detail: 'The server keeps this running',
      running: true,
      url: null,
    })),
  ],
  facts: {
    os: fact('Ubuntu 24.04.4 LTS', 'read the system description'),
    hostname: fact('shop-1', 'asked the machine its name'),
    user: fact('admin', 'asked who we signed in as'),
    privilege: fact('sudo-password', 'asked what this sign-in may do'),
    init: fact('systemd', 'looked for how it starts things'),
    packageManager: fact('apt-get', 'looked for the tool that installs software'),
    webServer: fact('nginx', 'looked for a web server'),
    cpus: fact(4, 'counted the processors'),
    disk: fact({ usedKb: 34_000_000, totalKb: 100_000_000 }, 'asked how full the disk is'),
    memory: fact({ totalKb: 8_000_000, freeKb: 4_700_000 }, 'read the memory figures'),
    load1: fact(0.42, 'read the load average'),
    uptimeSeconds: fact(232_603, 'asked how long it has been on'),
    listeners: fact([{}, {}, {}, {}, {}, {}, {}, {}, {}], 'asked what is listening'),
  },
  offered: {
    'site-shop': ['open', 'logs', 'restart', 'stop'],
    'app-worker': ['logs', 'start'],
    'db-main': ['logs', 'restart'],
    // Reading, and nothing that changes anything. `availableActions`.
    ...Object.fromEntries(OS_UNITS.map((name) => [`other-${name}`, ['logs']])),
  },
  absent: {
    'db-main': [
      {
        actionId: 'backup',
        because: "We can't tell what kind of database this is, so we don't know how to copy it safely.",
      },
    ],
    /* The same sentence on all fifty — which is what `group-notes.ts` hoists to
       the heading, so the page says it once rather than fifty times. */
    ...Object.fromEntries(
      OS_UNITS.map((name) => [`other-${name}`, [{ actionId: 'restart', because: NOT_YOURS_TO_STOP }]]),
    ),
  },
  how: ['asked what is listening', 'asked what the server keeps running', 'read the web server configuration'],
  cannot: [
    { what: 'Containers', why: 'This sign-in is not allowed to ask this server about its containers.' },
  ],
  measuredAt: NOW - 20 * 60_000,
}

/** A container: nothing to keep running, and every number belongs to somebody else. */
const LITTLE = {
  cards: [],
  facts: {
    os: fact('Alpine Linux v3.24', 'read the system description'),
    user: fact('root', 'asked who we signed in as'),
    init: fact('container-none', 'looked for how it starts things'),
    disk: cannot(
      "This is running inside a container, so these numbers would be the host computer's rather than this one's.",
    ),
    memory: cannot(
      "This is running inside a container, so these numbers would be the host computer's rather than this one's.",
    ),
    listeners: cannot('There is no way to count them on this machine.'),
  },
  offered: {},
  absent: {},
  how: ['asked what the server keeps running'],
  cannot: [{ what: 'How busy it is', why: 'These numbers would be the host computer’s.' }],
  measuredAt: NOW - 3 * 60_000,
}

const SENTENCES: Record<string, { klass: string; label: string; sentence: string; wayBack: string | null; keeps: string | null }> = {
  open: { klass: 'safe', label: 'Open', sentence: '', wayBack: null, keeps: null },
  logs: { klass: 'safe', label: 'Logs', sentence: '', wayBack: null, keeps: null },
  start: {
    klass: 'reversible',
    label: 'Start',
    sentence: "Start {name}. It'll be running again in a few seconds.",
    wayBack: 'Stop',
    keeps: null,
  },
  restart: {
    klass: 'reversible',
    label: 'Restart',
    sentence: "Restart {name}. It'll be offline for about five seconds while it starts again.",
    wayBack: 'Start',
    keeps: null,
  },
  stop: {
    klass: 'reversible',
    label: 'Stop',
    sentence:
      "Stop {name}. It'll be off until you start it again — anyone visiting will see an error.",
    wayBack: 'Start',
    keeps: null,
  },
}

let shells = 0
const listeners = new Set<(chunk: unknown) => void>()

const bridge: ServersBridge = {
  listServers: () => after(rows),
  lookAtServer: (id) => after({ ok: true, view: id === 's1' ? SHOP : LITTLE }, 1200),
  closeServer: () => Promise.resolve({ closed: true }),
  previewServerAction: (id, cardId, actionId) => {
    const spec = SENTENCES[actionId]
    if (spec === undefined) return Promise.resolve({ ok: false, sentence: 'no', detail: '' })
    const view = id === 's1' ? SHOP : LITTLE
    const name = view.cards.find((card) => card.id === cardId)?.name ?? 'it'
    return after(
      {
        ok: true,
        preview: {
          actionId,
          klass: spec.klass,
          label: spec.label,
          target: name,
          sentence: spec.sentence.replace('{name}', name),
          wayBack: spec.wayBack,
          keeps: spec.keeps,
        },
      },
      120,
    )
  },
  actOnServer: (_id, cardId, actionId) =>
    after(
      {
        ok: true,
        outcome: {
          done: `${SENTENCES[actionId]?.label ?? 'Did'} ${cardId}.`,
          detail: {},
          wayBack: SENTENCES[actionId]?.wayBack === null ? null : { actionId: 'start', label: 'Start' },
        },
      },
      1500,
    ),
  readServerLogs: (_id, cardId, lines) =>
    after(
      {
        ok: true,
        lines: Array.from({ length: Math.min(lines, 12) }, (_, at) => `${cardId}: line ${at + 1}`),
      },
      500,
    ),
  grantServerCopilot: (id, forMs) =>
    after({ ok: true, grant: { serverId: id, expiresAt: Date.now() + forMs, grantedAt: Date.now() } }),
  revokeServerCopilot: () => after({ revoked: true }),
  serverGrantState: () => after(null, 60),
  openServerShell: (id, cols) => {
    const shellId = `${id} ${(shells += 1)}`
    /*
     * The first frame is emitted **before** the id is answered, on purpose.
     *
     * That is what the real thing does — the far side attaches its listener the
     * moment the shell exists, while the id naming it is still on its way back
     * — and it is how the dropped-prompt defect was found here. Slowing this
     * down to be polite would hide the race the terminal now buffers against.
     */
    setTimeout(() => {
      for (const listener of listeners) {
        listener({ shellId, data: `\r\nadmin@shop-1:~$ \x1b[2mthis pane is ${cols} columns wide\x1b[0m\r\n` })
      }
    }, 400)
    return after({ ok: true, shellId }, 500)
  },
  writeToServerShell: (shellId, data) => {
    for (const listener of listeners) listener({ shellId, data })
    return Promise.resolve({ written: true })
  },
  resizeServerShell: () => Promise.resolve({ resized: true }),
  closeServerShell: () => Promise.resolve({ closed: true }),
  onServerShellOutput: (cb) => {
    listeners.add(cb)
    return () => listeners.delete(cb)
  },
  onServerShellClosed: () => () => {},
  /*
   * The keys this computer has — the list that replaced *"open the key file in
   * any text editor and paste the whole thing here"*.
   *
   * These are the shapes `keyfiles.ts` really answers, including the two that
   * matter on screen: one key that is locked, and one whose lock could not be
   * read at all, which says nothing rather than guessing.
   */
  serverKeys: () =>
    after(
      [
        { path: '/home/you/.ssh/id_ed25519', name: 'id_ed25519', what: 'A key made by OpenSSH', locked: false },
        { path: '/home/you/.ssh/hetzner', name: 'hetzner', what: 'A key made by OpenSSH', locked: true },
        { path: '/home/you/.ssh/old_rsa', name: 'old_rsa', what: 'An RSA key', locked: null },
      ],
      500,
    ),
  pickServerKey: () =>
    after({ path: '/home/you/Downloads/server.pem', name: 'server.pem', what: 'An RSA key', locked: false }, 700),
  readServerKey: () => after({ ok: true, key: '-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blb…\n-----END OPENSSH PRIVATE KEY-----\n' }, 300),
  addServer: (draft) => {
    const typed = draft as { address?: string; username?: string; name?: string; key?: string; passphrase?: string }
    // Two refusals worth seeing: a locked key with no passphrase, and an address
    // that does not exist. Everything else is added.
    if (typed.key !== undefined && typed.key !== '' && (typed.passphrase ?? '') === '') {
      return after({ ok: false, kind: 'needs-passphrase', sentence: 'That key is locked. What is its password?' }, 1400)
    }
    if ((typed.address ?? '').includes('nope')) {
      return after(
        { ok: false, kind: 'no-such-address', sentence: "We can't find a computer at that address. Check it for a typo." },
        1400,
      )
    }
    const id = `s${rows.length + 1}`
    rows.push({
      id,
      name: typed.name ?? typed.address ?? id,
      address: typed.address ?? '',
      username: typed.username ?? '',
      credential: typed.key === undefined ? 'password' : 'key',
      hostKey: { algorithm: 'ssh-ed25519', fingerprint: 'SHA256:new…', firstSeenAt: Date.now() },
    })
    return after({ ok: true, id }, 1400)
  },
  forgetServer: (id) => {
    const at = rows.findIndex((row) => row.id === id)
    if (at > -1) rows.splice(at, 1)
    return after({ ok: true })
  },
  renameServer: (id, name) => {
    const row = rows.find((entry) => entry.id === id)
    if (row) row.name = name
    return after({ ok: true })
  },
}

const host = document.getElementById('root')
if (host) {
  createRoot(host).render(
    <div
      className="panel-page"
      /* Let the page grow instead of scrolling inside itself, so a full-page
         screenshot catches everything below the fold. The real window scrolls
         this element; a harness that copied that would only ever photograph the
         first screen. */
      style={{ position: 'relative', inset: 'auto', height: 'auto', overflow: 'visible' }}
    >
      <MachinesPanel bridge={bridge} />
    </div>,
  )
}
