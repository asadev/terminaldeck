/**
 * Every page bigger than a socket buffer came back cut in half — on Windows only.
 */
export default {
  name: 'a file served through the phone tunnel arrives whole, every byte of it',

  fixed: '2026-08-18',

  because:
    'A phone looking at a dev server on this machine gets it through a byte pipe, and the pipe took its end of a '
    + 'stream down with a call that throws away everything Node has accepted from `write()` but not yet handed to the '
    + 'kernel. That queue is only ever non-empty once a body is larger than the socket can hold in flight — about '
    + '320 KB on this Mac, 64 KB on Windows — so on the machine it was written on nothing was ever queued and nothing '
    + 'was ever lost, while on Windows 230 KB of a 295 KB page was silently discarded. It did not look like corruption '
    + 'either: a body cut short gives the reader no end signal and no error, so the request hangs for ever and reads as '
    + 'a timeout. Both halves of the tunnel spell this close themselves, the wrong one is the shorter to write, and it '
    + 'is invisible on the platform this product is built on — which is the whole of how it shipped.',

  link: 'bf4e88c A timeout that was really a truncated download',

  async run({ expect, project }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');
    const net = await import('node:net');

    /**
     * Eight megabytes, not the megabyte the bug was reported at.
     *
     * A Mac's loopback swallows a small body whole — that is precisely why this
     * shipped — so a payload the socket can hold in flight proves nothing here.
     * Eight is more than twenty times the in-flight capacity measured on this
     * machine, which puts the queue the wrong close discards beyond any
     * platform's buffer.
     */
    const BYTES = 8 * 1024 * 1024;

    /** The two halves of the same pipe, as they are actually built. */
    const halves = [
      { what: 'the desktop', file: 'out/main/index.js' },
      { what: 'the headless host', file: 'out/headless/chunk-host.mjs' },
    ];

    /**
     * Lift every stream close out of a built bundle, with the constant it reads.
     *
     * Taken from the build rather than from `src`: a guard cannot import
     * TypeScript, and the built file is the one that gets packaged and run. Each
     * bundle holds two copies — the guest half and the tunnel half — because the
     * decision is written out twice on purpose, and twice is two chances to get
     * it wrong on one side only.
     *
     * Braces are counted rather than parsed, which is enough for six lines of
     * plain code with no string, comment or regex in them. If that ever stops
     * being true the lifted text will not compile and the expectation below says
     * so, which is the right way round: a guard that cannot read the code it
     * watches must never report that the code is fine.
     */
    const closesIn = (source) => {
      const linger = [...source.matchAll(/const (FLUSH_LINGER[\w$]*)\s*=\s*([\d_.e+]+)\s*;/g)]
        .map((found) => `const ${found[1]} = ${found[2]};`)
        .join('\n');
      const lifted = [];
      for (const found of source.matchAll(/function (flushAndClose[\w$]*)\s*\(/g)) {
        let depth = 0;
        let at = source.indexOf('{', found.index);
        for (; at < source.length; at += 1) {
          if (source[at] === '{') depth += 1;
          else if (source[at] === '}' && (depth -= 1) === 0) break;
        }
        lifted.push({
          named: found[1],
          // The real constant comes with it. Substituting a number of our own
          // would hide a linger shortened to nothing, which truncates exactly
          // the way the original bug did.
          text: `${linger}\n${source.slice(found.index, at + 1)}\nreturn ${found[1]};`,
        });
      }
      return lifted;
    };

    /**
     * Serve a large body to a reader that is not reading, close the socket the
     * given way, and count what actually arrived.
     *
     * Real sockets on this machine's loopback, because the thing under test is
     * the behaviour of a TCP socket and not anybody's bookkeeping: that `end()`
     * drains the queue and `destroy()` bins it. A fake duplex agrees with
     * whatever the author believed, which is the belief being questioned.
     */
    const arrivedThrough = async (close) => {
      const payload = Buffer.alloc(BYTES, 0x61);
      /** @type {import('node:net').Socket[]} */
      const served = [];
      const server = net.createServer((socket) => {
        served.push(socket);
        socket.write(payload);
        close(socket);
      });
      try {
        await new Promise((ready) => server.listen(0, '127.0.0.1', ready));
        const { port } = /** @type {{port: number}} */ (server.address());
        return await new Promise((settle) => {
          const reader = net.createConnection({ host: '127.0.0.1', port });
          let arrived = 0;
          let answered = false;
          const done = () => {
            if (answered) return;
            answered = true;
            settle(arrived);
          };
          // Nothing is read for a moment, on purpose: this is the paused reader
          // the bug needs. A fresh socket delivers nothing until something asks,
          // so the server's write piles up behind the socket's in-flight
          // capacity — and that pile is exactly what the wrong close throws away.
          reader.on('connect', () =>
            setTimeout(() => {
              reader.on('data', (chunk) => {
                arrived += chunk.length;
              });
            }, 250),
          );
          reader.on('end', done);
          reader.on('close', done);
          // An error settles it rather than throwing: a truncated stream ends in
          // a reset on some platforms, and that is a short answer, not a broken
          // experiment.
          reader.on('error', done);
          // A ceiling, so a socket that never settles costs one answer rather
          // than the whole guard's clock. Eight megabytes over the loopback move
          // in milliseconds; five seconds is not a wait anything depends on.
          setTimeout(done, 5_000).unref?.();
        });
      } finally {
        for (const socket of served) socket.destroy();
        server.close();
      }
    };

    /** @type {{what: string, named: string, close: (s: import('node:net').Socket) => void}[]} */
    const closes = [];
    for (const half of halves) {
      const file = path.resolve(project.paths.root, half.file);
      const source = await fsp.readFile(file, 'utf8').catch(() => null);
      await expect(`${half.what}'s half of the tunnel is built, so there is something to read`, async () => {
        return source !== null;
      });
      for (const lifted of closesIn(String(source))) {
        closes.push({
          what: half.what,
          named: lifted.named,
          close: /** @type {(s: import('node:net').Socket) => void} */ (new Function(lifted.text)()),
        });
      }
    }

    await expect('both halves still close their streams through a named helper', async () => {
      // Two per bundle: the guest half and the tunnel half. One would mean a
      // rename, an inlining, or one side quietly going its own way — all three
      // are worth a look before a release, and none of them can be answered by
      // the checks below, which can only exercise what they found.
      return closes.length >= 4;
    });

    await expect('a truncated download is something this can actually see', async () => {
      // The floor, proved before the ceiling. `destroy()` is the call that
      // shipped; if the payload were small enough for the loopback to swallow,
      // every check below would pass over a broken product — which is how the
      // original bug survived a Mac in the first place.
      const arrived = await arrivedThrough((socket) => socket.destroy());
      return arrived < BYTES;
    });

    for (const close of closes) {
      await expect(`${close.what} delivers the whole body when it closes a stream (${close.named})`, async () => {
        const arrived = await arrivedThrough(close.close);
        return arrived === BYTES;
      });
    }
  },
};
