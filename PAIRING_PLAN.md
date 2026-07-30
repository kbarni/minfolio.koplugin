# Universal Kindle pairing: discovery, rediscovery, multi-device, unpair

Status: **v2**, rewritten 2026-07-30 after adversarial review by Codex and Fable.
Both returned "rework" on v1 and both were substantially right; §11 records the
response. Spans two repositories: `minfolio-kindle` (this one) and `minfolio`
(the desktop app, at `../minfolio`).

## 1. What this actually is

v1 described this as making an existing pairing feature general. That was wrong.
**Pairing was never finished.** There is a protocol on both sides and no way for a
user to reach it:

- `requestPair`, `discover`, `pairings` and `onPaired` have **zero callers**. They
  appear only in `src/folio-desktop.d.ts` and the `electron/preload.cjs` bridge.
  Nothing in the renderer ever calls them, so the six-digit code that v1 called
  "the actual security boundary" is returned to nobody and displayed nowhere.
- The Kindle has no pairing menu. `main.lua` registers one entry, "Minfolio".
- The desktop README states the intended design outright: *"Minfolio does not use a
  separate UDP discovery or pairing step, so it shares the same reachable Kindle
  selection as the rest of the local Kindle tools."*

So the shipping mechanism is not pairing at all. It is
`docs/kindle-pairing.example.json` copied to `~/.config/minfolio/kindle.json`
(`{host, user, identityFile}`), plus "connect with SSH once to trust its host key".
A generic path exists and is documented; it simply requires SSH key auth, prior
host-key trust, and knowing the Kindle's address.

That means this is a **feature build**, not a repair, and the user interface is on
the critical path rather than a non-goal. v1's "Not a UI redesign" was doing load-
bearing work it had not earned.

## 2. Goals and non-goals

**Goals**

1. Pair any desktop with any Kindle with no pre-existing SSH access, no key
   installation, no config file, and no knowledge of the Kindle's address.
2. Survive an address change without user intervention.
3. Let a Kindle hold several paired desktops and distinguish them.
4. Unpair from either side, and have it actually revoke access.

**Non-goals**

- **Concurrent sessions from two desktops.** Pairing records may be plural; exactly
  one *session* may be live per Kindle. See §5.5 for the three chokepoints that make
  anything else a separate project.
- No change to the merge semantics, which were verified lossless.
- No defence against an adversary with physical or USB access to the Kindle, or with
  root SSH to it. Stated explicitly in §7 rather than left implied.

**A non-goal v1 got wrong.** v1 promised "no change to the document channel". That
is not achievable: the channel currently runs over an SSH reverse tunnel to
`127.0.0.1:38444`. Removing SSH moves it to a direct LAN address, which changes the
descriptor's host and port and exposes the HTTPS server to the LAN for real. §4.5
listed what SSH is for and omitted the largest item — it *is* the transport.

## 3. Verified findings

| Finding | Evidence |
|---|---|
| Pairing has no UI on either side; the IPC surface is unreachable | grep for `requestPair\|kindle.discover\|kindle.pairings\|onPaired` matches only `preload.cjs:67,75` and the `.d.ts` |
| The desktop's documented design has no pairing step | `minfolio/README.md:128-130` |
| The real setup path is an SSH config file | `minfolio/docs/kindle-pairing.example.json`, README:132-137 |
| `M.post` ignored the HTTP response, so a rejected pairing reported success | was `minfolio_pair.lua`; **fixed in `973f398`** |
| The Kindle already accepts UDP pair requests | `minfolio_pair.lua` `poll()` |
| Pair-request validation is presence-only, unbounded, unthrottled, replayable | `minfolio_pair.lua:80`, `:108` (32/tick), `:140` (0.75 s tick); nonce/expiry exist only on the desktop |
| The worker starts *before* the launch flag is written, and validates the descriptor with no pairing concept | `electron/main.cjs:1252`; `minfolio_sync.lua:8-15` |
| A failed launch wedges Kindle editing permanently and survives restart | `electron/main.cjs:1046-1055` inserts and persists with no rollback; `:1048` guard; `src/main.ts:306` clears only the renderer's map |
| SSH uses `StrictHostKeyChecking=yes` with no app-private `known_hosts` | all five call sites, `electron/main.cjs:1179,1197,1217,1255` |
| The document channel is the SSH reverse tunnel | `electron/main.cjs:1217-1219,1235-1236` |
| `localNetworkHost()` takes the first non-internal IPv4 — a VPN or bridge on a real laptop | `electron/main.cjs:1292-1300` |
| The worker never gives up: no failure counter, no backoff, exits only on `stopped` from a 200 or the `closing` file | `minfolio_sync.lua:114-127`, `:79-91` |
| `/kindle/pair` is unauthenticated, binds `0.0.0.0`, and buffers an uncapped body | `electron/main.cjs:975-986`, `:320-325`, `:1038` |
| `deviceId` is the hardware serial, broadcast in clear every 0.75 s | `minfolio_pair.lua:56-61,129-133` |
| No protocol version field anywhere | `minfolio_pair.lua`, `minfolio_sync.lua:8-15`, `electron/main.cjs:1269-1277` |
| **Inbound UDP is dropped by the Kindle's own firewall, so UDP pairing cannot work at all as designed** | `iptables -P INPUT DROP` with 7,450 packets already dropped; the only `wlan0` UDP accept is `state ESTABLISHED`. Proven end to end on the device: outbound beacons arrive on the desktop (14 in 12s), but neither a `minfolio-discover` nor a standalone luasocket listener on a second port ever receives a datagram. The pre-hardening module fails identically, so it is not a regression |
| The sibling project already solved Kindle credential storage | `kindle-utils/kindle-mirror/remote-access/v2/kindle/kindle-relay.sh:3` keeps key and config under `/var/local` "so neither is visible through the USB userstore"; `install-kindle.sh:10-16` shows `mntroot rw` / `install -m 600` / `mntroot ro` |
| The stale root `main.cjs` is untracked, not a committed duplicate | `git ls-files` lists only `electron/main.cjs` |

## 4. The pairing ceremony

### 4.0 The prerequisite that invalidates §4 as first written

The whole ceremony below assumes the Kindle can receive a UDP datagram. It cannot.
The Kindle's firewall policy is `INPUT DROP`, and the only UDP accepted on `wlan0` is
`state ESTABLISHED` -- replies to conversations the Kindle itself opened. There is no rule
for port 42771, and 7,450 packets had already been dropped when this was measured.

Verified on the device, not inferred: the Kindle's outbound beacons arrive fine (14 in 12
seconds), the plugin's socket is bound (`0.0.0.0:42771`), the sender is on the same subnet,
and the validator accepts the exact probe payload -- yet no `minfolio-discover` is ever
answered. A standalone luasocket listener on a second port, run directly on the device,
never receives the datagram either, which places the loss below userspace. The
pre-hardening module was deployed and tested for comparison and behaves identically, so
this is long-standing, not a regression.

This also explains two things that had looked like oversights: the desktop only ever
delivered pair requests over SSH, and `discoverKindles()` was never wired to any UI.
The SSH file drop was not an unfinished shortcut, it is the only channel that functions.

**Consequence.** Every UDP-based step in this plan -- the offer broadcast in §4, the
session-available nudge in §5.2, and the unpair datagram in §5.7 -- needs an `iptables`
rule accepting UDP on 42771 on `wlan0`, installed at pairing time and made persistent
across reboots, since Kindle firewall rules do not survive one. That is a firewall
modification on the user's device and a real change to what "no configuration required"
means. It must be decided before any of §4 is implemented, and it belongs in the
onboarding story of §1 rather than being discovered by a user whose pairing silently
never arrives.

v1 proposed broadcasting the nonce and code and having the user compare the code.
Both reviewers destroyed it, correctly: that puts the shared secret on the wire, so
a LAN observer could POST to `/kindle/pair` first with a secret of their own.

The obvious inversion — Kindle displays a code, user types it into the desktop —
closes that hole but not the whole race, because **the Kindle still has to learn
where to POST**, and if that comes from an unauthenticated datagram the attacker
supplies their own host, port and *fingerprint*, and the Kindle pins the attacker's
certificate and hands over everything. Moving the code does not remove the race.

The design that closes it, with no new cryptography:

1. **Arm on the Kindle.** A "Pair with desktop" menu action opens a bounded window
   (120 s, one prompt at a time). Outside that window every `minfolio-pair-offer` is
   dropped silently and never prompted. This one change kills prompt flooding,
   blind-accept, replay-as-social-engineering, and the "which of two Kindles"
   ambiguity, for the cost of a boolean and a timer.
2. **The desktop broadcasts an offer, it does not target a device.**
   `{ v, type: "minfolio-pair-offer", host, port, fingerprint, label }`. No device
   picker, so two identically-labelled Kindles stop being a problem — the device in
   the user's hand is the one they accept on — and "no knowledge of the Kindle's
   address" becomes literally true.
3. **Both sides display the same last 12 hex characters of the desktop's certificate
   fingerprint.** This is what v1 was missing. It makes the confirmation a check on
   the identity that will actually be pinned, so a racing attacker's prompt shows
   *different* digits. It needs no hash function — the fingerprint is already in the
   datagram — which avoids depending on a SHA-256 in the KOReader UI process that
   nobody has verified exists on this device.
4. **The Kindle then displays a six-digit code which the user types into the
   desktop**, and sends it inside the pinned TLS POST. The code never appears in
   plaintext on the LAN in either direction, and it proves to the desktop that the
   POST came from the device whose screen the user is looking at — which also stops a
   rogue *Kindle* from claiming a pairing. Cap attempts per pending request at 5,
   expire in 120 s. Typing burden on the Kindle: zero.
5. **`M.post` must read the status line and persist only on 2xx** — already fixed in
   `973f398`, and a precondition for every protection above.

Residual risk: a user who blind-accepts a prompt whose digits do not match. That is
irreducible, but arming shrinks the exposure window from "always" to a window the
user deliberately opened.

**No fallback on a timer.** v1 proposed falling back to SSH if UDP was unconfirmed.
There is no delivery signal — the only confirmation is the human accepting — so the
timer would fire while the user was still reading, drop a second request with a
different nonce, and stack a second prompt. Offer SSH as an explicit user action
("No prompt on your Kindle? Try SSH"), and a manual address entry for networks that
block broadcast.

## 5. The rest of the design

### 5.1 Credential handling: delete v1's §4.2

v1 had the Kindle verify a long-lived secret carried **in the descriptor**. In phase
1 the descriptor arrives over root SSH, so the same party can read every secret out
of the store and forge a descriptor for any of them, or simply overwrite the store.
You cannot revoke a party holding root SSH by deleting a file it can read and write.
That check has negative value: it costs a store format, a migration, a new
descriptor field and a plaintext copy of the credential, and buys nothing.

The correct invariant, which is one sentence and should be written into
`PROTOCOL.md`:

> The pairing secret's only power is to claim a session that the desktop's human has
> already created. It travels only Kindle→desktop inside pinned TLS, and never
> appears in any file the desktop writes.

The short-lived capability this implies already exists — the per-session bearer
token. So the secret authenticates the *descriptor fetch*, and the token continues to
authenticate the document channel.

### 5.2 SSH-free sessions are the target, not a phase 2

Given §5.1, revocation is only real once the descriptor stops arriving over SSH. v1
made that "phase 2, for review, not necessarily for now", which would have shipped
the cost first and the benefit maybe-never. It is the single target.

```
desktop --UDP--> kindle   { v, type: "minfolio-session-available", fingerprint }
kindle:  looks up its OWN pairing record by that fingerprint; unknown -> drop silently
kindle  --TLS--> desktop  GET /kindle/session-descriptor
                          Authorization: Bearer <pairing secret>
                          pinned to the STORED fingerprint, connecting to the STORED
                          host (datagram source address is a hint only)
desktop: verifies the secret against its pairing record, returns the descriptor
kindle:  starts minfolio_sync.sh locally
```

The invariant that makes this safe, and which v1's version violated: **no credential
ever travels to an endpoint whose pin came from the same message that requested it.**
The datagram carries an identity *claim* and nothing else.

Cost to state plainly: SSH can wake a Kindle and launch KOReader; a datagram cannot.
So this requires KOReader to be running, and SSH remains an optional accelerator.

### 5.3 Enforcement belongs in the worker

v1 put the check in `App.remoteEdit`. The desktop's launch command starts
`minfolio_sync.sh` **before** writing `/tmp/minfolio_launch`, and the worker
independently `dofile`s the descriptor with its own validation set that has no
pairing concept. A descriptor the UI rejected would still get a worker that connects
out and uploads whatever the editor later writes. Under §5.2 the worker is started by
the Kindle itself from a descriptor the Kindle fetched, which removes the problem at
the root rather than adding a third copy of credential logic — the worker is a
separate process with its own `LUA_PATH` and cannot `require("minfolio_pair")`.

### 5.4 Storage, and an honest threat model

Move `pairing.lua` from `/mnt/us/.minfolio/` to `/var/local`, following the
convention this author's own sibling project already established for exactly this
reason. It is nearly free and converts "USB access at time T" from a permanent
network capability into nothing.

But state the exclusion rather than implying protection: **anyone with USB or
physical access to the Kindle can drop a `.lua` file into the plugins directory and
get code execution, or write `/tmp/minfolio_launch` directly.** At-rest secrecy is
therefore not the boundary that matters, and Codex's emphasis on it was the least
actionable part of its findings. Two things to test before committing: whether
`/var/local` survives a firmware update, and whether cycling `mntroot rw`/`ro` from
inside a running KOReader is safe on a pairing write.

### 5.5 Multi-device: records plural, sessions singular

Three chokepoints make concurrent sessions a separate project, not a detail:

- the launcher unconditionally `pkill`s every worker and writes one shared
  `remote-session.lua` (`electron/main.cjs:1252`);
- the reverse tunnel is a hardcoded `-R 127.0.0.1:38444` with
  `ExitOnForwardFailure=yes`, so a second desktop's session fails outright, and
  `terminateStaleKindleTunnels()` kills any local `ssh` matching that spec — so two
  Electron instances on one machine kill each other (`:1142-1156`, `:1217-1219`);
- the Kindle has one active editor singleton, and `stopKindleWorker` no-ops once
  another desktop has overwritten the shared descriptor.

So: a Kindle may hold several pairing records and must distinguish them; exactly one
session may be live. This is a stated non-goal in §2, not a limitation buried in an
acceptance criterion users will read optimistically.

### 5.6 Rediscovery, and the host-key problem v1 missed

Discovery already learns a fresh address; the fix is to use it. But feeding a newly
discovered IP into `StrictHostKeyChecking=yes` with no app-private `known_hosts`
produces an unknown-host refusal, so v1's WP D would have *broken* users who work
today through a stable alias. Capture the Kindle's host key once, at pairing, into
`<userData>/kindle_known_hosts`, and pass `-o UserKnownHostsFile=... -o
CheckHostIP=no`.

Also split `kindleSshProfile()` into `kindleSshCredentials()` and
`kindleAddress(deviceId)`. It currently conflates address with credentials and
returns two different shapes (`{target}` versus `{host,key,user}`), which is where
the churn would come from.

Use an ephemeral socket for active discovery. Note the beacon nuance, where Codex
and Fable disagreed and Fable was right: replies go to the datagram's source port, so
active discovery always resolves within a sweep; binding 42771 only adds passive
presence detection, which the "offline in this sweep" model does not need. The real
reason to use an ephemeral socket is that two desktop instances contend for the
fixed port.

Fix `localNetworkHost()` while here: choose the interface whose subnet contains the
Kindle's discovered address rather than the first non-internal IPv4, or a VPN or
Docker bridge will silently break pairing for a new user.

### 5.7 Unpair

- **Desktop**: `folio:kindle:unpair(deviceId)` deletes the record and, if the Kindle
  is reachable, asks it to drop its side over the TLS channel where the secret proves
  identity — never over an unauthenticated datagram, which would be a trivial LAN
  denial of service.
- **Kindle**: a pairing menu listing paired desktops by label and fingerprint prefix,
  with delete. Kindle-side deletion *is* revocation once §5.2 lands.
- Revocation of an unreachable desktop is **pending revocation**, not success. A
  local delete is not a revocation.
- Unpair must tear a live session down through the existing `closing`/`stopped` path
  so the outbox is preserved to `/mnt/us/.minfolio-recovery`.

### 5.8 Robustness fixes this work depends on

- **Transactional sessions.** Roll the main-process record back and re-persist if
  `launch` rejects, and add an unconditional reap the renderer can call. Otherwise
  the first failed attempt by a new user wedges Kindle editing permanently, across
  restarts — and that is precisely the user this project is for.
- **The worker must give up.** Exit after N consecutive failed cycles with a recovery
  copy, and back off exponentially. A 401 after revocation currently spins TLS
  handshakes every 0.6 s forever, holding a wifi wake-lock.
- **Bound the network parsers.** Cap `/kindle/pair` bodies, validate every datagram
  field for type, length and range, keep a seen-nonce set with expiry on the Kindle,
  and bind the HTTPS server to loopback except while a pairing window or LAN session
  is open.
- **Protocol version field** on every datagram and on the descriptor, before anything
  else, with "ignore unknown types, absent field means v1". Two independently
  deployed artifacts are about to gain four wire changes.
- **Use a random per-install device id** rather than the hardware serial, and beacon
  only while pairing is armed or a session is live.
- **Add a label field in both directions.** Nothing currently sends a desktop name,
  and the Kindle's label is the hardcoded string "Kindle Minfolio", so two Kindles
  are indistinguishable and an unpair list would show bare hex.
- **`M.secret()` must refuse to pair** if `/dev/urandom` is unavailable, rather than
  falling back to `os.time()`. Harmless while decorative; not once load-bearing.
- **Delete `pair-request.lua` after consuming it.** `pollRequest` removes only the
  flag, so any later touch of the flag replays the old request.

## 6. Work packages

Ordering per the reviews, which found v1's graph wrong in three places.

| WP | Scope | Repo |
|---|---|---|
| 0 | Protocol version field on all datagrams and the descriptor; "absent means v1" | both |
| 1 | Pure `minfolio_pairing_store.lua`: keyed load/save/list/delete/migrate, with off-device tests. Discard-and-re-pair migration | kindle |
| 2 | Arming, bounded prompt, nonce cache, datagram validation, rate limits; `/var/local` storage; secret refusal on no entropy | kindle |
| 3 | Kindle pairing menu: arm, code display, fingerprint prefix, paired list, unpair | kindle |
| 4 | Desktop pairing UI: offer broadcast, code entry, fingerprint prefix, progress and failure states, paired list, unpair | desktop |
| 5 | `/kindle/session-descriptor` endpoint; secret verification; descriptor fetch by the Kindle; worker started locally | both |
| 6 | Transactional sessions; worker give-up and backoff; parser bounds; loopback-by-default bind | both |
| 7 | Rediscovery: app-private `known_hosts`, `kindleAddress` split, `localNetworkHost` subnet match, ephemeral discovery socket | desktop |
| 8 | Unpair both sides, acknowledged revocation, pending-revocation state, live-session teardown | both |
| 9 | Docs: `PROTOCOL.md`, both READMEs (which currently contradict each other and the code), the invariant in §5.1 | both |

0 and 1 are independent. 2 needs 1. 3 and 4 can run in parallel after 2. 5 needs
3 and 4. 6 is independent and can land any time. 8 needs 5.

## 7. Risks

| Risk | Mitigation |
|---|---|
| **Inbound UDP dropped by the Kindle firewall** | §4.0. Requires a persistent iptables rule; until then no UDP step in this plan can work |
| Broadcast blocked | manual address entry, plus SSH as an explicit user action (§4) |
| Blind-accept of a mismatched prompt | arming plus the fingerprint prefix on both screens; irreducible beyond that |
| `/var/local` does not survive a firmware update | test before committing; fall back to `/mnt/us` with the exclusion documented |
| `mntroot rw` during a pairing write destabilises a running KOReader | test; if unsafe, write the store only at arm time |
| Migration discards a working pairing | discard-and-re-pair is deliberate and unambiguous; WP 1 is pure and tested |
| Two independently deployed artifacts drift | WP 0 first |
| Scope creep into concurrent sessions | explicit non-goal, §2 and §5.5 |

## 8. Acceptance criteria

1. A desktop with no SSH access, no key, and no config file can pair with a Kindle:
   the user arms pairing on the Kindle, both screens show the same fingerprint
   prefix, the user types the Kindle's code into the desktop, and pairing completes.
2. The Kindle accepts inbound UDP on 42771, and the rule survives a reboot.
2. Outside the armed window, a `minfolio-pair-offer` produces no prompt at all.
3. A spoofed offer carrying an attacker's host, port and fingerprint cannot cause the
   Kindle to send its secret anywhere, because the Kindle connects only to a stored
   fingerprint.
4. Moving the Kindle to a different address requires no user action, including for
   SSH host-key trust.
5. A Kindle holds two paired desktops, distinguishes them by label, and one session
   at a time is enforced with a clear message.
6. Unpairing from either side revokes: a later session attempt is refused until the
   user re-pairs. Unpairing an unreachable desktop reports pending revocation.
7. Unpair during a live session tears it down through the existing path and preserves
   any unsent edit.
8. A failed launch leaves no wedged session, before or after restart.
9. A revoked worker exits rather than spinning.
10. Both READMEs and `PROTOCOL.md` agree with each other and with the code.

## 9. Still unverified

- Whether `/var/local` survives a Kindle firmware update.
- Whether `mntroot rw`/`ro` is safe from inside a running KOReader.
- Whether any usable SHA-256 exists in the KOReader UI process. The design
  deliberately avoids needing one.
- Any of it end to end. Nothing here has been exercised against a live pair of
  devices.

## 10. Review response

Codex: **rework**. Fable: **rework**. Every finding below was checked against source
before acceptance.

| Finding | Source | Resolution |
|---|---|---|
| Broadcasting nonce+code lets a LAN observer hijack the pairing | both | ceremony redesigned, §4 |
| `M.post` never read the response, so rejection reported success | Codex | fixed in `973f398` |
| Inverting the code does not close the race, because the Kindle still learns where to POST from an unauthenticated datagram | Fable | §4.3 fingerprint prefix on both screens; §5.2 connect only to the stored pin |
| v1's secret-in-descriptor check is forgeable by the party it authenticates | Fable | §4.2 deleted, §5.1 |
| Enforcement was in the wrong process; the worker starts first | Fable | §5.3 |
| **Pairing has no UI and no work package created one** | Fable | §1 reframes the whole plan; WP 3 and 4 |
| A failed launch wedges editing permanently across restarts | Fable | §5.8, WP 6 |
| Host-key trust is per-address, so rediscovery would break SSH | Fable | §5.6 app-private `known_hosts` |
| The document channel *is* the SSH tunnel; the non-goal was impossible | Fable | §2 corrected |
| Prompt flooding is a remote UI lockup, not a nuisance | Fable | arming, §4.1 |
| Worker never gives up | Fable | §5.8 |
| No protocol versioning | Fable | WP 0, first |
| Concurrent sessions blocked at three chokepoints, not one | both | explicit non-goal, §5.5 |
| No `kindleDeviceId` threaded through session creation | Codex | WP 5 and 7 |
| Long-lived secret on USB-visible FAT | Codex | §5.4, `/var/local` per the sibling project's own precedent |
| Beacon-port claim wrong | Codex (MAJOR) / Fable (MINOR) | Fable adjudicated: active discovery always resolves within a sweep, so severity is minor; ephemeral socket adopted for the two-instance reason instead, §5.6 |
| At-rest secrecy is the boundary that matters | Codex | Fable rebutted: same access grants code execution. Exclusion stated in §5.4; storage moved anyway because it is cheap |
| Hijack is a present-day breach | Codex | Fable rebutted: the secret is inert today, so it is a false success, not a compromise. Fixed regardless |
| Stale `main.cjs` is a divergent committed copy | v1 | Fable corrected: untracked local artifact, `git ls-files` lists only `electron/main.cjs`. Just delete it |
