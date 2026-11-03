/**
 * Which listening ports are not pages, and the three spellings a name arrives in.
 *
 * ## Why this is shared rather than local
 *
 * It lived in `dev-ports.ts` and applied to this computer only. On the walk of
 * 2026-08-18 the same list, drawn for a **server**, offered `:22 sshd` and
 * `:53 systemd-resolve` as pages to open — because the server's ports come from
 * `servers/reach.ts`, which had never had a filter at all. One rule, both
 * machines: `sshd` is sshd wherever it is running, and pressing it gets an
 * identification string and a closed socket either way.
 *
 * The discriminator is the **name of the program holding the port**, which both
 * scans already read from the machine. It is not an assumption about how
 * somebody has arranged theirs — the thing rule 4 forbids — and it is
 * deliberately never the port number, because a person is perfectly entitled to
 * run their own web app on 3306 while nothing they do will make `mysqld` answer
 * a browser.
 *
 * A port whose holder the machine would not name stays offered. We do not know
 * what it is, and refusing on a suspicion is the same error pointing the other
 * way.
 */

/**
 * Processes that are almost never something you want to open in a browser.
 * Everything else is offered, because guessing which frameworks a person uses
 * is exactly the assumption this module exists to avoid.
 */
export const NOT_A_DEV_SERVER = new Set([
  'rapportd',
  'sshd',
  /* Seen offered as pages on this Mac during the walk of 2026-08-18. `adb` is
     Android's debug bridge and `sharingd` is macOS's own; neither has ever
     served a page to anybody. */
  'adb',
  'sharingd',
  'launchd',
  'ControlCe',
  'Spotify',
  'Dropbox',
  'iTunes',
  'AirPlay',
  'identityservicesd',
  'remoted',
  'Google',
  'Slack',
  'Postgres',
  'postgres',
  'mysqld',
  'redis-server',
  'mongod',
  'Docker',
  // Windows equivalents. Nothing above ever appears there and nothing here ever
  // appears on macOS, so one list serves both without either platform paying for
  // the other's noise. `System` is PID 4, which holds 135, 445 and 139 on a
  // stock install — three ports offered as dev servers on the very first launch.
  'System',
  'System Idle Process',
  'svchost',
  'services',
  'lsass',
  'wininit',
  'spoolsv',
  'sqlservr',
  'MsMpEng',
  'vmware-hostd',
  'com.docker.backend',
  /*
   * Daemons found on the walked Ubuntu server, plus the rest of the protocols a
   * browser cannot speak. `systemd-resolve` is the spelling Linux prints —
   * `comm` is clamped to fifteen characters, so the unit's own
   * `systemd-resolved` never appears — and both are listed rather than one
   * being derived, because a table that has to be *computed* to be correct is a
   * table the next reader will get wrong.
   */
  'systemd-resolve',
  'systemd-resolved',
  'chronyd',
  'ntpd',
  'named',
  'dnsmasq',
  'unbound',
  'rpcbind',
  'rpc.statd',
  'smbd',
  'nmbd',
  'cupsd',
  'dovecot',
  'mariadbd',
  'memcached',
  'postmaster',
  'slapd',
])

/**
 * Does the exclusion list above cover this process, under any of the spellings
 * the operating system might have printed?
 *
 * Three, and every one of them is a real spelling seen on this machine:
 *
 *  - the name as printed — `sshd`, `node`;
 *  - the first word of it — field-mode `lsof` prints `Google Chrome` where the
 *    column output printed `Google`, and the list was written against the
 *    column output;
 *  - the first nine characters — the column output's own clamp, which is how
 *    `ControlCenter` came to be listed as `ControlCe`.
 *
 * Checking all three means switching `lsof` to field mode cannot quietly
 * *un-exclude* half the list. It did on the first attempt: Chrome's port 9333
 * reappeared as a suggested dev server the moment the names stopped being
 * truncated.
 */
export function isExcluded(name: string): boolean {
  if (NOT_A_DEV_SERVER.has(name)) return true
  const firstWord = name.split(' ')[0]
  if (firstWord !== name && NOT_A_DEV_SERVER.has(firstWord)) return true
  return name.length > 9 && NOT_A_DEV_SERVER.has(name.slice(0, 9))
}
