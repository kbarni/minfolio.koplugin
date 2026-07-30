# The Minfolio desktop pairing and document-sync protocol

This document specifies what the Kindle side of Minfolio's desktop-editing feature actually
does: discovery, pairing, the document channel, and the concurrent-edit rules. It is written
from the Kindle's Lua implementation only — `minfolio_pair.lua`, `minfolio_remote.lua`,
`minfolio_app.lua`, and `minfolio_sync.lua`, all in `minfolio.koplugin/`, current as of this
writing. The other half of this protocol is TypeScript, in the `kal-kaliper/minfolio`
desktop app, which is not checked out alongside this repository. Where a claim about the
desktop's behaviour cannot be verified from the Kindle-side code, it is marked as such
explicitly rather than presented as fact — this repository is not a substitute for reading
the desktop's own source, only a precise account of what the Kindle side sends, expects, and
enforces. `kindle-inbox/PROTOCOL.md` is the model this document follows.

`ARCHITECTURE.md` places `minfolio_pair.lua`/`minfolio_remote.lua`/`minfolio_app.lua` in the
module map (Tier 2 transport, Tier 3 controller); read that first if you need the "why here"
rather than the "what happens".

## Contents

1. [Discovery](#1-discovery)
2. [Pairing](#2-pairing)
3. [Starting a remote session](#3-starting-a-remote-session)
4. [The document channel](#4-the-document-channel)
5. [The on-disk file contract](#5-the-on-disk-file-contract)
6. [Concurrent-edit semantics](#6-concurrent-edit-semantics)
7. [Teardown](#7-teardown)
8. [What is not verified from this repository](#8-what-is-not-verified-from-this-repository)

## 1. Discovery

`minfolio_pair.lua` opens a UDP socket bound to `*:42771` (`M.port`) with broadcast enabled,
and from then on runs a 0.75-second tick (`M.poll` → `M.pollRequest` → `M.beacon`) for as
long as the plugin is loaded. Nothing here waits for the desktop to initiate — the Kindle is
always listening and always broadcasting once `main.lua`'s `init()` calls `Pair.start()`.

**Beacon (Kindle → LAN broadcast, unsolicited, every ~0.75s):**

```json
{ "type": "minfolio-device", "id": "<deviceId>", "label": "Kindle Minfolio" }
```

sent to `255.255.255.255:42771`. `deviceId()` reads `/proc/usid` (the Kindle's own serial),
strips everything non-alphanumeric, and falls back to the literal string `"kindle"` if that
file can't be read.

**Active discover (desktop → Kindle, unicast or broadcast to port 42771):**

```json
{ "type": "minfolio-discover", "nonce": "<opaque>" }
```

The Kindle replies unicast to the sender's source `ip:port` (from `receivefrom`, not a fixed
address):

```json
{ "type": "minfolio-device", "nonce": "<echoed>", "id": "<deviceId>", "label": "Kindle Minfolio" }
```

so a desktop that wants a fast, immediate answer doesn't have to wait up to 0.75s for the
next unsolicited beacon.

UDP datagram handling is rate-limited defensively: `M.poll()` processes at most 32 datagrams
per tick and logs a warning (throttled to once per 30s) if it hits that cap, so a flood of
unsolicited or malformed UDP traffic cannot starve the KOReader UI loop — the socket is
non-blocking (`s:settimeout(0)`) and this runs on every tick regardless of what else the user
is doing.

## 2. Pairing

A pairing request can reach the Kindle through **either of two independent channels**, and
both converge on the same confirmation prompt.

**Channel A does not currently work, and Channel B is the only functioning route.** The
Kindle's own firewall drops inbound UDP: the policy is `INPUT DROP` and the only UDP
accepted on `wlan0` is `state ESTABLISHED`, i.e. replies to conversations the Kindle
itself opened. No rule exists for port 42771. Verified on the device rather than
inferred: the Kindle's outbound beacons arrive at the desktop, the plugin's socket is
bound to `0.0.0.0:42771`, the sender is on the same subnet, and the validator accepts a
well-formed probe -- yet no `minfolio-discover` is ever answered, and a standalone
luasocket listener on a second port run directly on the device never receives the
datagram either. So the loss is below userspace. This is long-standing, not a
regression: the pre-hardening module was deployed for comparison and behaves
identically.

This is why the desktop only ever delivered pair requests over SSH, and why
`discoverKindles()` was never wired to any UI. Channel A is described below because the
code implements it and because it becomes usable the moment an `iptables` rule accepts
UDP on 42771 -- see `PAIRING_PLAN.md` §4.0, which treats that rule, and making it
survive a reboot, as a prerequisite rather than a detail.

**Channel A — UDP**, handled directly inside the discovery tick. The example address below
is from RFC 5737's documentation range, deliberately: `RELEASE_CHECKLIST.md`'s pre-release
scan greps for private-range LAN addresses, and a realistic-looking one here would trip it
on every release until whoever runs it learns to ignore the check.

```json
{ "type": "minfolio-pair-request", "code": "1234", "host": "198.51.100.7", "port": 8443,
  "fingerprint": "<sha256 hex>", "nonce": "<opaque>" }
```

**Channel B — a file dropped over the desktop's existing SSH access.** The desktop writes a
Lua table (the same five fields, `dofile`-able) to
`<MINFOLIO_REMOTE_DIR>/pair-request.lua` and touches a flag file at
`/tmp/minfolio_pair_request`; `M.pollRequest()` (also run every tick) checks for the flag,
and on finding it, deletes it and `dofile`s the descriptor. This channel exists for exactly
the case UDP broadcast doesn't reliably cover on its own (verified only as an inference from
the code's existence, not confirmed against the desktop) — the desktop already needs
passwordless SSH to the Kindle for the document channel and the remote-session worker (see
§3), so it can deliver a pairing request the same way when convenient.

Both channels call `M.showPrompt(msg)`, which does nothing at all unless every one of
`code`, `host`, `port`, `fingerprint`, and `nonce` is present. If they are, the Kindle shows a
`ConfirmBox` with the verification code rendered as plain text: **the code is the actual
security boundary here**, not the nonce — a UDP broadcast (or a compromised LAN peer) can
trigger this prompt unilaterally, but only a human comparing the code shown on the Kindle
against the code shown on the desktop's own screen decides whether to accept it.

On accept:

1. The Kindle generates a fresh per-device secret: 24 bytes from `/dev/urandom`, hex-encoded
   (48 hex characters). If `/dev/urandom` can't be opened, it falls back to
   `tostring(os.time()) .. tostring(socket.gettime())` — **not cryptographically random**,
   and worth flagging: this fallback only triggers if `/dev/urandom` is unavailable, which
   should not happen on a normal Kindle, but the code does not refuse to proceed if it does.
2. It opens a pinned-TLS connection to `cfg.host:cfg.port` (see §4 for exactly how the pin is
   checked) and sends a raw HTTP/1.1 `POST /kindle/pair` with a JSON body
   `{ "nonce": ..., "code": ..., "deviceId": ..., "secret": ... }`.
3. **This POST's response is never read.** `M.post` returns `true` as soon as the request
   bytes have been written to the socket; it does not parse an HTTP status line or a body.
   "Desktop paired" is shown, and the secret is persisted, purely on the strength of the TLS
   connection and cert-pin check having succeeded and the write not erroring — there is no
   application-level acknowledgement from the desktop in this exchange.
4. The secret is written to `<STATE_DIR>/pairing.lua` as `return { secret = "<hex>" }\n`.

**Nothing in this repository reads `pairing.lua` back.** No Kindle-side Lua file references
`MINFOLIO_PAIR_PATH` for reading, only for this one write. The most plausible explanation —
that the desktop, which already has passwordless SSH to the Kindle for other purposes, reads
this file directly over SSH to learn the secret for subsequent authentication — is not
verified from this repository and is recorded here only as a plausible inference, not a
finding.

## 3. Starting a remote session

Nothing in `minfolio_pair.lua` or `minfolio_app.lua` spawns the sync worker
(`minfolio_sync.lua`/`.sh`) or writes the launch flag described below — both are external
actions the desktop takes over its existing SSH access, inferred from `minfolio_sync.sh`'s
own comment ("Keep KOReader's Lua search paths out of the **desktop SSH command**") and from
`ARCHITECTURE.md`'s [kshell launch contract](ARCHITECTURE.md#the-kshell-launch-contract)
section, not verified against the desktop's own source. What is verified, from
`minfolio_app.lua`, is everything that happens once the Kindle side is triggered:

1. The desktop is assumed to have already written a session descriptor (a `dofile`-able Lua
   table) somewhere reachable, and to write `remote:<descriptor-path>` into
   `/tmp/minfolio_launch` — the same launch-flag file and polling mechanism `notes` and
   `edit:PATH` use (`ARCHITECTURE.md`).
2. `main.lua`'s `pollLaunchFlag` picks this up and calls `App.remoteEdit(descriptor_path)`.
3. `App.remoteEdit` `dofile`s the descriptor and **validates it strictly** before doing
   anything else: `cfg.host` must be a string, `cfg.port` a number, `cfg.session_id` a string
   matching `^[A-Za-z0-9_-]+$`, `cfg.token` a non-empty string, `cfg.cert_fingerprint` a
   non-empty string, and — the check with real teeth — `cfg.directory` must be **exactly**
   `MINFOLIO_REMOTE_DIR .. "/" .. cfg.session_id`. A descriptor cannot point the session at an
   arbitrary directory; the directory is derived from the session id by a fixed convention,
   and a mismatch aborts with `notify("Invalid secure desktop editing session")`. Any of the
   other validations failing does the same.
4. On success, it creates `<MINFOLIO_REMOTE_DIR>/<session_id>/` and computes four paths
   inside it by the same fixed convention (`document.md` the shadow file that becomes
   `MDEdit.path`, and `outbox.md`/`inbox.md`/`revision`/`closing` — see §5). If
   `cfg.content` is a string and the shadow file doesn't already exist, it is written as the
   document's initial content — **the very first version of the document arrives embedded in
   the launch descriptor itself**, delivered over the pre-existing SSH channel, not over the
   HTTP document channel described in §4. The check against an existing shadow file means a
   duplicate or re-delivered `remote:` launch does not clobber an in-progress local shadow.
5. `App.openNote(shadow_path, cfg)` opens the editor with `cfg` as `MDEdit.remote` — from this
   point, `MDEdit:init` reads `self.remote_revision = tonumber(cfg.revision) or 0` and the
   ongoing sync described in §6 takes over.

Both `MDEdit` (via `minfolio_app.lua`, above) and the standalone `minfolio_sync.lua` worker
process independently `dofile` the **same** descriptor file and independently derive the
same four paths from `cfg.directory` by the same fixed convention. They never pass paths to
each other directly and never talk to each other except through those four files — see §5.

## 4. The document channel

Once a session is running, `minfolio_sync.lua` (the standalone worker; never loaded by
KOReader, see `ARCHITECTURE.md`) is the only thing in the Kindle-side Minfolio stack that
performs network I/O for the document itself. It speaks a small, hand-rolled HTTP/1.1 client
over a TLS socket — not a general HTTP library, so there is no redirect handling, no chunked
transfer-encoding support, and every request opens a fresh connection (`Connection: close`
is sent on every request; there is no keep-alive).

**TLS and trust.** The connection is `ssl.wrap(sock, { mode = "client", protocol = "any",
verify = "none", options = "all" })` — LuaSec's own certificate verification is explicitly
disabled (`verify = "none"`). All trust comes from a manual step performed after the
handshake completes: the leaf certificate's SHA-256 fingerprint
(`cert:digest("sha256"):lower():gsub(":", "")`) is compared, case-insensitively and with
colons stripped, against `cfg.cert_fingerprint` from the session descriptor. A mismatch
closes the connection and the request fails; there is no fallback to CA-chain trust and no
hostname check. `minfolio_remote.lua`'s `M.socket` (used by the pairing POST in §2) and
`minfolio_sync.lua`'s own `connect()` (used for the document channel) implement this
identically, independently — they are two separate pieces of code with the same pinning
logic, not a shared function, since the worker is a different process with its own
`LUA_PATH` and cannot `require("minfolio_remote")`.

**Authentication.** Every request after pairing carries `Authorization: Bearer <cfg.token>`.
The token itself is minted by the desktop and delivered inside the session descriptor
(`cfg.token`); nothing on the Kindle side generates or validates it beyond passing it through
verbatim on every request.

**Endpoints, both scoped under `/kindle/sessions/<session_id>/`:**

`GET /kindle/sessions/<id>/snapshot` — success is an HTTP status line containing ` 200 `
(the worker checks for that substring, not a parsed status code). Body:

```json
{ "content": "<full document text>", "revision": 7, "stopped": false }
```

`stopped` is optional; its absence is treated as `false`. `content` is always the **whole**
document, never a diff.

`POST /kindle/sessions/<id>/submit` — body:

```json
{ "content": "<full document text>", "baseRevision": 7 }
```

success is an HTTP status line containing ` 202 ` (Accepted — not 200; the desktop is
expected to acknowledge receipt without necessarily having merged the content yet). Also a
whole-document body, keyed to the revision the Kindle believed was current when the save
happened (`baseRevision` — see §6 and §8 for what the desktop does with a stale one, which is
not verified here).

## 5. The on-disk file contract

Four files live under `<MINFOLIO_REMOTE_DIR>/<session_id>/`, and the direction each one
flows is fixed and never reversed:

| File | Written by | Read by | Contents |
|---|---|---|---|
| `document.md` | `MDEdit` (this is `self.path` — every ordinary save writes here) | `MDEdit` (it's the editor's own file) | The shadow document, full text |
| `outbox.md` | `MDEdit:save()`, once per save, only when `self.remote` is set | `minfolio_sync.lua`'s `submit()` | Full document text pending upload |
| `inbox.md` | `minfolio_sync.lua`'s `fetch()`, only on a newer revision | `MDEdit:checkRemoteInbox()` | Full document text from a newer desktop snapshot |
| `revision` | `minfolio_sync.lua`'s `fetch()` | `MDEdit:checkRemoteInbox()` | The new revision number, as plain text |
| `closing` | `MDEdit:onCloseWidget()`, once, on close | `minfolio_sync.lua`'s main loop | The literal byte `"1"` — a marker, not data |

`outbox.md` is removed by the worker once `submit()` succeeds **and only if the file's
content is unchanged from what was just sent** (`read(cfg.outbox_path) == content`) — if a
newer local save replaced `outbox.md` while the HTTP request was in flight, that newer save
is left in place rather than being silently discarded by the just-completed upload.

## 6. Concurrent-edit semantics

This is deliberately precise, because it is the part of the protocol most likely to be
gotten wrong by a future change made without reading it first.

**The worker submits before it fetches, every loop iteration, by design.** The main loop in
`minfolio_sync.lua` is `submit(); local _, stopped = fetch(); ...; sleep(0.6)` — the file's
own comment states the reason directly: *"Sending first gives Kindle edits priority over any
remote snapshot."* A save made on the Kindle is always given the chance to leave before an
incoming desktop snapshot is even requested in that same cycle.

**`fetch()` applies an incoming snapshot only when it is strictly newer:**
`if next_revision > revision then` — a stale or duplicate snapshot (revision equal to or
older than what the worker already has) is fetched (the HTTP round trip still happens every
cycle) but not written to `inbox.md`/`revision`, and not merged into `revision`'s in-memory
value either.

**`MDEdit:checkRemoteInbox` is a second, independent gate, on the editor side.** Even after
the worker has written a newer snapshot to `inbox.md`, the editor will not apply it while
either of two conditions holds: `self._dirty` (there are local edits not yet flushed to
`outbox.md`), or `lfs.attributes(self.remote.outbox_path, "mode")` is truthy (an `outbox.md`
file currently exists on disk — a save has happened but the worker hasn't picked it up and
removed it yet). Either condition means there is Kindle-side work in flight that a
wholesale snapshot replacement would clobber, so `checkRemoteInbox` simply returns and tries
again on the next file-poll tick.

**When it does apply,** `checkRemoteInbox` replaces `self.lines` wholesale with the inbox
content, clamps the cursor into the new line/column range, clears the current selection, and
— the detail easiest to miss — **clears undo and redo outright**: `self._undo, self._redo =
{}, {}`. A remote-applied snapshot is a hard reset of the editor's edit history, not a change
merged into it; there is no way to undo past the point a remote snapshot was applied.

**Unsent Kindle content is not silently lost at teardown.** If the session ends (§7) while
`outbox.md` still holds content the desktop never accepted, the worker copies it to
`/mnt/us/.minfolio-recovery/<session_id>.md` before removing the session directory. Files in
that recovery directory older than 14 days are pruned automatically
(`find ... -mtime +14 -delete`) on every worker start and at every teardown — it is a safety
net, not a second permanent notes store.

**The desktop side, now verified.** The earlier revision of this document recorded the
desktop's merge behaviour as unverified and flagged "whether a desktop edit can be discarded
without a prompt" as an open question, on the belief that the desktop source was unavailable.
It is available (`minfolio/electron/main.cjs` and `minfolio/src/main.ts`), and the answer is
that **nothing is silently discarded on either side.**

`POST /kindle/sessions/<id>/submit` rejects a `baseRevision` only when it is out of range —
below 1, or greater than the session's current revision — returning 409 with "fetch the
latest snapshot and retry". A merely *stale* `baseRevision`, which is the interesting case, is
accepted: the submission is queued as `{ content, baseRevision }` and the renderer is
notified. The renderer then looks up that exact revision in the session's history to use as
the merge ancestor and takes one of four paths:

- **Ancestor unavailable** — it refuses to guess one (guessing would make every line added
  since that snapshot look like a Kindle deletion) and writes the Kindle's content to a
  conflict copy beside the note.
- **Kindle content equals the ancestor** — a retry or no-op; the desktop buffer stands, so an
  in-flight retry cannot yank the editor out from under someone typing.
- **Desktop content equals the ancestor** — the Kindle's content is taken wholesale.
- **Both diverged** — a three-way `merge3` against the ancestor. If it merges cleanly *and*
  the result still contains the Kindle's text, the merge becomes canonical. Otherwise the
  desktop buffer remains visible and the Kindle's full snapshot is written to a conflict copy.

So the worst case is a conflict file on disk, never a lost edit. The source comment records
that this replaced an earlier Kindle-authoritative fallback specifically to make the outcome
lossless.

The Kindle-side "priority" described above is therefore narrower than it sounds: submitting
before fetching orders the Kindle's own outbox ahead of an incoming snapshot within a single
worker tick. It does not give the Kindle authority over desktop content, because the desktop
resolves the two against a real common ancestor rather than overwriting.

One consequence worth knowing: a 409 does not lose the edit either. `submit()` removes the
outbox file only on a 202, so a rejected submission is retried on the next tick, by which
point `fetch()` has advanced `revision` to a value the desktop will accept.

## 7. Teardown

A session can end from either side, and both paths converge on the same cleanup in the
worker.

**Kindle-initiated close.** `MDEdit:onCloseWidget()` — reached whether the user closes the
note directly, switches to a different note (`edit_note` closes the previous editor first),
or `App.remoteStop` (below) forces it closed — flushes any pending autosave, then, if
`self.remote` is set, writes the literal byte `"1"` to `remote.closing_path`
(`<session_dir>/closing`). It does **not** delete the session directory or any other remote
file itself; the comment in the code is explicit about why: the session directory is "a
shared handoff owned by the desktop launcher", and a successor session's launch could already
be racing this one's teardown, so the editor only ever writes the one marker file it
exclusively owns.

**`App.remoteStop(session_id)`** is reached the same way a remote edit starts — a
`remote-stop:<session_id>` entry in `/tmp/minfolio_launch`, presumably desktop-written over
SSH (not verified here, same caveat as §3). It looks up the single active editor
(`App.active`) and calls `:saveAndClose()` on it **only if** that editor is still live and
its `remote.session_id` matches the id being stopped — a stale or duplicate `remote-stop`
targeting a session that has already ended, or a different session that has since started,
is a no-op rather than closing the wrong editor.

**Desktop-initiated stop.** The worker's `fetch()` reads a `stopped` field from the
`GET .../snapshot` JSON response (§4); `stopped == true` is a desktop-originated signal with
no corresponding write on the Kindle's file-based side.

**The worker's main loop treats both signals identically:** after each `submit()`/`fetch()`
pair, `if stopped or read(cfg.directory .. "/closing") then recover_and_cleanup(); break end`
— either `stopped` from the desktop or the `closing` file from the Kindle editor triggers the
same cleanup (recovery-copy any unsent `outbox.md`, per §6, then `rm -rf` the whole session
directory) and the worker process exits. Neither side needs to know which of the two actually
triggered it.

## 8. Cross-checked against the desktop implementation

This document was originally written from the Kindle side alone, on the belief that the
desktop source was unavailable. It is available, at `minfolio/` alongside this checkout, and
the sections above have been reconciled against it. Note that repository currently carries two
divergent copies of `main.cjs`; `package.json` names `electron/main.cjs` as the entry point and
that is the one cited throughout.

Confirmed by reading both sides:

- The desktop never reads `pairing.lua`. It already holds the secret, because the Kindle sent
  it in the `POST /kindle/pair` body and the desktop stored it in its own pairings file. The
  Kindle's copy is written so the Kindle can recognise a previously paired desktop; verified by
  the absence of any `pairing.lua` read in the desktop source.
- The desktop does launch the worker over SSH and does write the launch flag, verified in
  `minfolio/electron/main.cjs`: a single remote `sh -c` kills any previous worker, writes
  `remote-session.lua`, starts `minfolio_sync.sh` under `nohup`, records its pid, writes
  `remote:<path>` to `/tmp/minfolio_launch`, and starts KOReader if it is not already running.
  Session stop writes `remote-stop:<id>` to the same flag.

Still not verified, because it needs a running pair of devices rather than a second reading:

- The desktop's discovery and pairing UI, and whether it validates the Kindle's beacon reply
  beyond the type/nonce/id check in its listener.
- Any of it end to end. Nothing in this document has been exercised against a live desktop
  and Kindle since the Kindle side was split into modules.
