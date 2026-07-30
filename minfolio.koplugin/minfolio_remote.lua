-- SPDX-License-Identifier: AGPL-3.0-only
-- Encrypted desktop transport for minfolio.koplugin (PLAN.md §5 Tier 2):
-- opens a TLS-wrapped TCP socket with certificate-pin verification, and
-- sends a buffer to completion. Transport only -- no pairing, discovery, or
-- session logic; that is `minfolio_pair.lua`, which requires this module.
-- Requires KOReader's `socket` (LuaSocket); `ssl` (LuaSec) is deliberately a
-- function-local `pcall(require, "ssl")` inside `M.socket` rather than a
-- top-level require, exactly as it was in main.lua, since a missing LuaSec
-- install must fail one connection attempt, not the whole module load. This
-- cannot be `require`d and executed under plain luajit -- only `loadfile`-
-- parsed, exactly like main.lua itself -- so no off-device test suite is
-- included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 2, §10 step 6):
-- MinfolioRemote.socket, MinfolioRemote.sendAll.
--
-- MinfolioRemote was a bare global before this move (main.lua:2007 in the
-- original 5,755-line file, forced by the 200-local ceiling this refactor
-- removes -- see PLAN.md §1/§6.4). It is now M.socket/M.sendAll. Confirmed
-- by repo-wide grep (including minfolio_sync.lua/.sh, a separate process
-- with its own LUA_PATH) that nothing outside main.lua read it as a global.
-- `MinfolioRemote.edit`/`.stop` -- the other half of that global, session
-- control rather than transport -- moved to `minfolio_app.lua` as
-- `App.remoteEdit`/`.remoteStop` in the prior step (PLAN.md §5 Tier 3, §10
-- step 5); they are not here.
--
-- Required by callers as `local Remote = require("minfolio_remote")`.

local socket = require("socket")

local M = {}

function M.socket(cfg, timeout)
    local sock, err = socket.tcp()
    if not sock then return nil, err end
    sock:settimeout(timeout or 1)
    local ok, cerr = sock:connect(cfg.host, cfg.port)
    if not ok then pcall(function() sock:close() end); return nil, cerr end
    local ok_ssl, ssl = pcall(require, "ssl")
    if not ok_ssl then pcall(function() sock:close() end); return nil, "LuaSec missing" end
    local wrapped, werr = ssl.wrap(sock, { mode = "client", protocol = "any", verify = "none", options = "all" })
    if not wrapped then pcall(function() sock:close() end); return nil, werr end
    wrapped:settimeout(timeout or 1)
    while true do
        local hs_ok, hs_err = wrapped:dohandshake()
        if hs_ok then break end
        if hs_err ~= "wantread" and hs_err ~= "wantwrite" then pcall(function() wrapped:close() end); return nil, hs_err end
    end
    local cert = wrapped:getpeercertificate()
    local fpr = cert and cert:digest("sha256"):lower():gsub(":", "") or nil
    if not fpr or fpr ~= tostring(cfg.cert_fingerprint or ""):lower():gsub(":", "") then
        pcall(function() wrapped:close() end); return nil, "desktop certificate pin mismatch"
    end
    return wrapped
end

function M.sendAll(sock, data)
    local pos = 1
    while pos <= #data do
        local sent, err = sock:send(data, pos)
        if not sent then return false, err end
        pos = sent + 1
    end
    return true
end

return M
