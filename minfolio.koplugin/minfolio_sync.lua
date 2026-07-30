-- SPDX-License-Identifier: AGPL-3.0-only
-- Standalone remote-session worker.  It is intentionally not loaded by
-- KOReader: blocking TLS/HTTP work must never share the editor's UI loop.
local socket = require("socket")
local ssl = require("ssl")
local json = require("rapidjson")

local descriptor = assert(arg[1], "descriptor path required")
local cfg = assert(dofile(descriptor), "invalid descriptor")
assert(type(cfg.session_id) == "string" and cfg.session_id:match("^[A-Za-z0-9_-]+$"), "invalid session id")
assert(cfg.directory == "/mnt/us/.minfolio-remote/" .. cfg.session_id, "invalid session directory")
assert(type(cfg.host) == "string" and cfg.host ~= "", "invalid desktop host")
assert(type(cfg.port) == "number" and cfg.port >= 1 and cfg.port <= 65535, "invalid desktop port")
assert(type(cfg.token) == "string" and cfg.token ~= "", "invalid session token")
assert(type(cfg.cert_fingerprint) == "string" and cfg.cert_fingerprint ~= "", "invalid certificate fingerprint")
-- Keep the descriptor transport-only. Both the worker and MDEdit derive the
-- local cache paths, so a worker started before the UI still has everything it
-- needs to send the initial Kindle save.
cfg.outbox_path = cfg.directory .. "/outbox.md"
cfg.inbox_path = cfg.directory .. "/inbox.md"
cfg.revision_path = cfg.directory .. "/revision"

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local value = f:read("*a"); f:close(); return value
end
local function atomic_write(path, value)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(value); f:close()
    return os.rename(tmp, path)
end
local function prune_recovery()
    -- Recovery is a safety net, not a second notes folder. Keep unsent copies
    -- long enough for a user to recover after a failed session, then reclaim
    -- the Kindle storage automatically.
    os.execute("find /mnt/us/.minfolio-recovery -type f -mtime +14 -delete 2>/dev/null")
end
prune_recovery()
local function connect()
    local raw = assert(socket.tcp())
    raw:settimeout(4)
    local ok = raw:connect(cfg.host, cfg.port)
    if not ok then pcall(function() raw:close() end); return nil end
    local wrapped = ssl.wrap(raw, { mode = "client", protocol = "any", verify = "none", options = "all" })
    if not wrapped then pcall(function() raw:close() end); return nil end
    wrapped:settimeout(4)
    local ok_handshake = wrapped:dohandshake()
    if not ok_handshake then pcall(function() wrapped:close() end); return nil end
    local cert = wrapped:getpeercertificate()
    local fingerprint = cert and cert:digest("sha256"):lower():gsub(":", "") or ""
    if fingerprint ~= tostring(cfg.cert_fingerprint):lower():gsub(":", "") then pcall(function() wrapped:close() end); return nil end
    return wrapped
end
local function request(method, suffix, body)
    local sock = connect()
    if not sock then return nil end
    local req = method .. " /kindle/sessions/" .. cfg.session_id .. "/" .. suffix .. " HTTP/1.1\r\n"
        .. "Host: " .. cfg.host .. "\r\nAuthorization: Bearer " .. cfg.token .. "\r\nConnection: close\r\n"
    if body then req = req .. "Content-Type: application/json\r\nContent-Length: " .. #body .. "\r\n" end
    local sent = sock:send(req .. "\r\n" .. (body or ""))
    if not sent then pcall(function() sock:close() end); return nil end
    local status = sock:receive("*l")
    local length = 0
    while true do
        local line = sock:receive("*l")
        if not line or line == "" then break end
        local n = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if n then length = tonumber(n) or 0 end
    end
    local response = length > 0 and sock:receive(length) or ""
    pcall(function() sock:close() end)
    return status, response
end

local revision = tonumber(cfg.revision) or 0
local function fetch()
    local status, body = request("GET", "snapshot")
    if not status or not status:match(" 200 ") then return false end
    local ok, snapshot = pcall(json.decode, body)
    if not ok or type(snapshot) ~= "table" or type(snapshot.content) ~= "string" then return false end
    local next_revision = tonumber(snapshot.revision) or 0
    if next_revision > revision then
        atomic_write(cfg.inbox_path, snapshot.content)
        atomic_write(cfg.revision_path, tostring(next_revision))
        revision = next_revision
    end
    return true, snapshot.stopped == true
end
local function submit()
    local content = read(cfg.outbox_path)
    if content == nil then return false end
    local body = json.encode({ content = content, baseRevision = revision })
    local status = request("POST", "submit", body)
    if not status or not status:match(" 202 ") then return false end
    -- Do not consume a newer local save that replaced this outbox while the
    -- request was in flight.
    if read(cfg.outbox_path) == content then os.remove(cfg.outbox_path) end
    return true
end

local function recover_and_cleanup()
    local pending = read(cfg.outbox_path)
    if pending ~= nil then
        os.execute("mkdir -p /mnt/us/.minfolio-recovery")
        atomic_write("/mnt/us/.minfolio-recovery/" .. cfg.session_id .. ".md", pending)
    end
    prune_recovery()
    os.execute("rm -rf " .. string.format("%q", cfg.directory))
end

-- The worker must give up. Before this, the loop was `submit(); fetch();
-- sleep(0.6)` forever, with no failure counter and no backoff -- the only
-- exits were `stopped` from a 200 snapshot or the `closing` file. A 401
-- (session deleted, desktop restarted, tunnel gone) makes fetch() return
-- false, `stopped` stays nil, and the loop spun TLS handshakes every 0.6s
-- forever, holding a wifi wake-lock and draining the battery on an abandoned
-- session with no way to stop short of killing the process by hand.
--
-- fetch() is the health signal, not submit(): fetch() runs an unconditional
-- GET every single cycle regardless of whether there is anything to upload,
-- so it is a reliable per-cycle heartbeat. submit() returning false is
-- ambiguous on its own -- most cycles have nothing new to send at all
-- (`read(cfg.outbox_path) == nil`), which must never count as a failure or
-- an idle, healthy session would back off and give up for no reason. Since
-- submit() and fetch() share the same connect()/request() machinery (same
-- host, same bearer token, same TLS pin), a broken session fails both
-- identically, so driving the counter off fetch() alone still catches every
-- realistic failure (revoked token, unreachable host, torn-down tunnel)
-- without needing a second, redundant counter for submit().
--
-- Backoff: 1s, 2s, 4s, 8s, ..., capped at 120s, resetting to the healthy
-- 0.6s cadence on the next successful fetch. Give up after 15 consecutive
-- failures (~18 minutes of retrying at these intervals) -- long enough to
-- ride out a brief wifi blip or the desktop app restarting, short enough
-- that an abandoned or revoked session stops holding the wifi wake-lock
-- within a bounded, human-scale time rather than indefinitely.
local HEALTHY_SLEEP_SECONDS = 0.6
local BACKOFF_BASE_SECONDS = 1
local BACKOFF_CAP_SECONDS = 120
local MAX_CONSECUTIVE_FAILURES = 15

local consecutive_failures = 0

while true do
    -- Sending first gives Kindle edits priority over any remote snapshot.
    submit()
    local ok, stopped = fetch()
    -- MDEdit writes this only after its final autosave. A stopped desktop may
    -- deliberately reject that last upload, so retain one recovery copy rather
    -- than spinning forever on a closed session. Either way the worker exits:
    -- no orphaned Lua processes consuming Kindle CPU or battery.
    if stopped or read(cfg.directory .. "/closing") then
        recover_and_cleanup()
        break
    end
    if ok then
        consecutive_failures = 0
        socket.sleep(HEALTHY_SLEEP_SECONDS)
    else
        consecutive_failures = consecutive_failures + 1
        if consecutive_failures >= MAX_CONSECUTIVE_FAILURES then
            -- Give up, but preserve any unsent edit exactly like a clean stop
            -- -- the recovery-copy semantics must hold on every exit path,
            -- not just the two the loop already handled.
            recover_and_cleanup()
            break
        end
        local backoff = math.min(BACKOFF_CAP_SECONDS, BACKOFF_BASE_SECONDS * (2 ^ (consecutive_failures - 1)))
        socket.sleep(backoff)
    end
end
