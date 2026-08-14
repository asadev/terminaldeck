# What keeping every host connected costs

Multi-host makes a deliberate, reversible choice: **every paired machine holds
its socket from launch**, rather than connecting when it is picked out of the
switcher. This document says what that costs, how the cost was measured, and
what would make it the wrong call.

The short version: **the design is worth keeping.** Three paired machines cost
**43.2 kB an hour** of keepalive and **no extra radio wake-ups at all** over one
machine, because there is one timer for N hosts rather than N timers. The bit
that would have been expensive is the bit that was designed out.

## Why there is a keepalive at all

A long-lived TCP connection through a carrier NAT dies silently when the mapping
is reclaimed, which happens after 30–60 seconds of silence on most mobile
networks. TCP keepalive defaults to hours and does not save it. So a phone
holding a socket has to say something regularly or it discovers the socket is
dead only when somebody types into it — and "somebody types into it" is the one
moment this app must not be wrong about.

That makes the ping load-bearing rather than laziness. Dropping it does not save
work; it loses sessions. It is the standing exception to rule 7.9.

## The measurement

`scripts/keepalive-cost.ts`, run from the repository root:

```
npx tsx scripts/keepalive-cost.ts
```

It does not add up remembered constants. It runs the **shipping code** — the
Noise IK channel from `src/shared/sealed.ts`, the relay envelope from
`src/shared/relay-wire.ts`, the frame writers from `src/shared/ws-frame.ts`, and
the message built by the protocol module's own `serialize` — and reports the
length of the buffer that would go out on the socket.

```
ping   {"t":"ping"}   12 B of JSON   → 52 B on the wire
pong   {"t":"pong"}   12 B of JSON   → 48 B on the wire
round trip: 100 B per host per tick

one shared 25s tick, 144 ticks an hour:
  hosts    kB/hour    radio windows/h shared    unshared (one timer each)
      1       14.4                       144         144
      2       28.8                       144         288
      3       43.2                       144         432
      5       72.0                       144         720
```

The 12 bytes of JSON become 52 out and 48 in like this: the sealed channel adds
a 16-byte Poly1305 tag (28), `withSealedVersion` adds one byte (29), the relay
envelope adds a type byte and a 16-byte channel id (46), and the WebSocket frame
adds a 2-byte header — plus, **outbound only**, a 4-byte mask, because a
WebSocket client always masks and a server never does. Hence the 4-byte
asymmetry between a ping and a pong carrying identical JSON.

### This corrected the numbers that were there before

The first version of these figures, written into the header comments of
`Heartbeat.swift` and `Heartbeat.kt` from memory, said a ping was 12 bytes of
JSON and a pong 14, carried to 60 and 62 on the wire, for ~53 kB an hour at three
hosts. Three of those four numbers were wrong: both messages are 12 bytes of
JSON — `{"t":"pong"}` is the whole of a pong, see `ServerMessage` in
`src/main/remote/protocol.ts` — and the real envelope overhead is 40/36 rather
than 48. The true cost is **18% lower** than the comment claimed. Both comments
now carry the measured figures and point at the script, because a constant
nobody can re-derive is a constant that rots.

## Where the cost actually is, and why it is flat

**The radio, not the CPU.** Waking a cellular radio out of its idle state costs
roughly the same whether one byte or five hundred follow it, and it holds the
radio in a high-power state for seconds afterwards — the tail. So the thing to
count is not bytes per hour, it is **wake-ups** per hour.

That is the whole reason for `Heartbeat` (`ios/TerminalDeck/Transport/Heartbeat.swift`,
`android/…/transport/Heartbeat.kt`): one timer, every socket. Every host's ping
goes out in the same turn of the run loop, into the same radio window, and the
answers come back into it. The right-hand column above is the finding:

> **Radio wake-ups per hour do not grow with the number of paired machines.**
> They are 144 at one host and 144 at five. Unshared, five hosts would have cost
> 720 — five times the wake-ups for five times nothing.

This is rule 7.10 earning its keep on a phone rather than as a style point. It is
enforced by test, not by convention: `MultiHostTests.testEveryTransportSharesOneTick`
asserts that N transports produce one ticking loop, and
`testTheTickFiresEveryMemberInOneGo` asserts that one tick beats all of them.

## What was actually observed, and what was not

Separating these two matters more than usual here, because the tempting number —
"multi-host costs X% battery" — is the one that cannot honestly be produced yet.

**Proved by test**, `ios/Tests/MultiHostTests.swift`:

- `testEveryTransportSharesOneTick` — N transports joined to the shared
  `Heartbeat` produce **one** ticking loop, and it stops when the last leaves.
- `testTheTickFiresEveryMemberInOneGo` — a single tick beats every member, so the
  pings share one turn of the run loop and therefore one radio window.

**Proved by measurement**, `scripts/keepalive-cost.ts`: the byte counts above,
taken from the shipping wire code.

**Observed on the Simulator** against two harness hosts (`scripts/remote-host.sh`
— the product's own server, relay client and `PtyManager`): both machines stayed
connected while only one was on screen, each listing its own sessions, with the
switcher reporting live state for the machine in the background. That is the
thing always-connected is bought for, and it worked.

**Not measured: a battery percentage.** The Simulator shares the Mac's network
stack and has no cellular radio, so any figure taken there would be a made-up
number with a decimal point on it. The claim this document makes is narrower and
true: the traffic is 100 bytes per host per tick, and the wake-ups — the part
that actually costs battery — are constant in the number of hosts. The device
measurement is W6's, on TestFlight, with Xcode's Energy Organizer.

## What would reverse this decision

Named now, so the trigger is not argued about later:

1. **A device-side energy log showing the heartbeat in the top few contributors.**
   Xcode's Energy Organizer on a real device over a real day is the instrument;
   it needs TestFlight builds in real hands, which is W6.
2. **More than about five paired machines being common.** 72 kB/h and 144
   wake-ups is fine; if somebody pairs fifteen machines the answer is not a
   faster timer, it is connecting the visible host eagerly and the rest lazily.
3. **A carrier that reclaims mappings faster than 25 s**, which would force the
   interval down and multiply everything above.

The reversal itself is cheap by construction, and that is deliberate: because
every host is a `HostLink`/transport that is started and stopped independently,
"connect only the current one" is a change to *when* `start()` is called, not a
change to the shape of anything. Nothing below the transport would move.

## What is not free, and is kept anyway

Each host keeps its **own sealed channel and its own keys** — one Noise IK
handshake per machine, against that machine's static key. Two machines therefore
cannot read each other's sessions even though one phone is talking to both,
because the keys were never in the same place. That costs one handshake per host
at connect time and nothing per tick, and it would have to be deliberately
dismantled to lose. It stays.

The one thing genuinely shared across hosts is the phone's **static identity** —
one key, so a machine that has approved this phone once has approved this phone,
rather than the same handset appearing twice in one Mac's device list.
