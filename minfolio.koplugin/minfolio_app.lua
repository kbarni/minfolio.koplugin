-- SPDX-License-Identifier: AGPL-3.0-only
-- The Minfolio app controller (PLAN.md §5 Tier 3, §10 step 5): owns the one
-- live editor singleton and the two entry points a remote (desktop) session
-- uses to start/stop editing, plus a small hook table the file/note browser
-- registers into at load time. `minfolio_browser` does not exist yet (a
-- later work package -- PLAN.md §5 Tier 5) -- until then, main.lua's still-
-- inline browser code (`edit_note`, `open_markdown_picker`,
-- `show_file_manager`) registers itself here as `M.hooks.open_note` /
-- `.open_picker` / `.file_manager`, and every other subsystem (the editor,
-- the plugin entry, and the remote-session entry points below) calls
-- through `M.*` instead of reaching for those names directly.
--
-- This is the fix for the dependency tangle PLAN.md §4 documents:
-- `MinfolioRemote` used to span both a low tier (pure transport, used BY
-- pairing) and a high tier (session control, which calls the browser and
-- the editor), and no single module could hold both without an upward
-- dependency. Splitting session control out into this controller, with the
-- browser/editor reaching it only through hooks/App calls, makes the
-- dependency direction strictly downward: browser -> app, edit -> app,
-- main -> app.
--
-- Requires KOReader (`libs/libkoreader-lfs`, `gettext`, and transitively
-- through `minfolio_config`/`minfolio_io`/`minfolio_chrome`), so this cannot
-- be `require`d and executed under plain luajit -- only `loadfile`-parsed,
-- exactly like main.lua itself -- so no off-device test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 3, §10 step 5):
-- `active_mdedit` (a forward-declared local, singleton-enforcement state)
-- becomes `M.active`, read/written only through `M.setActive`/`.clearActive`/
-- `.activeEditor`. `MinfolioRemote.edit`/`.stop` become `M.remoteEdit`/
-- `.remoteStop`; their bodies' calls to `edit_note(...)` and reads of
-- `active_mdedit` become `M.openNote(...)` and `M.active`, since `edit_note`
-- itself stays in main.lua's still-inline browser code (registered here as
-- `M.hooks.open_note`) while `active_mdedit` is now this module's own state,
-- not a name it has to reach out for.
--
-- Required by callers as `local App = require("minfolio_app")`.

local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Config = require("minfolio_config")
local IO = require("minfolio_io")
local Chrome = require("minfolio_chrome")

local M = {}

-- The one live MDEdit instance, if any. main.lua's edit_note() enforces the
-- singleton (opening a second note closes/reuses this one instead of
-- stacking a duplicate editor against the same on-disk file and file-poller
-- -- see its own comment for the "Reloaded from disk storm" failure mode
-- this prevents); MDEdit:onCloseWidget clears it via M.clearActive.
M.active = nil

-- Hooks the browser (still inline in main.lua as of this work package --
-- PLAN.md §5 Tier 5's `minfolio_browser` is a later extraction) registers
-- into at load time, so every other subsystem calls through M.* instead of
-- reaching for the browser's functions directly.
M.hooks = { open_note = nil, open_picker = nil, file_manager = nil }

function M.setActive(ed)
    M.active = ed
end

function M.clearActive(ed)
    if M.active == ed then M.active = nil end
end

function M.activeEditor()
    return M.active
end

-- Was edit_note's entry point; dispatches to whatever registered
-- M.hooks.open_note (main.lua's edit_note, until minfolio_browser exists).
function M.openNote(path, remote)
    if M.hooks.open_note then M.hooks.open_note(path, remote) end
end

function M.openPicker(dir)
    if M.hooks.open_picker then M.hooks.open_picker(dir) end
end

function M.openFileManager(dir)
    if M.hooks.file_manager then M.hooks.file_manager(dir) end
end

-- A remote session is deliberately dormant until the desktop explicitly
-- writes a descriptor and launches `remote:`. There is no discovery loop or
-- background connection merely because Minfolio is open.
function M.remoteEdit(descriptor_path)
    local ok, cfg = pcall(dofile, descriptor_path)
    if not ok or type(cfg) ~= "table" or type(cfg.host) ~= "string" or type(cfg.port) ~= "number" then
        Chrome.notify(_("Invalid secure desktop editing session")); return
    end
    if type(cfg.session_id) ~= "string" or not cfg.session_id:match("^[A-Za-z0-9_-]+$")
        or type(cfg.token) ~= "string" or type(cfg.cert_fingerprint) ~= "string" then
        Chrome.notify(_("Invalid secure desktop editing session")); return
    end
    lfs.mkdir(Config.STATE_DIR)
    local expected_directory = Config.MINFOLIO_REMOTE_DIR .. "/" .. cfg.session_id
    if cfg.directory ~= expected_directory then Chrome.notify(_("Invalid secure desktop editing session")); return end
    lfs.mkdir(Config.MINFOLIO_REMOTE_DIR); lfs.mkdir(cfg.directory)
    local shadow = cfg.directory .. "/document.md"
    cfg.outbox_path = cfg.directory .. "/outbox.md"
    cfg.inbox_path = cfg.directory .. "/inbox.md"
    cfg.revision_path = cfg.directory .. "/revision"
    cfg.closing_path = cfg.directory .. "/closing"
    -- The initial content arrives over the existing encrypted SSH launch command.
    -- It is written before MDEdit is constructed, so the editor never opens blank.
    if not IO.read_file(shadow) then IO.write_file(shadow, type(cfg.content) == "string" and cfg.content or "") end
    M.openNote(shadow, cfg)
end

function M.remoteStop(session_id)
    local ed = M.active
    if ed and ed.remote and ed.remote.session_id == session_id then
        ed:saveAndClose()
    end
end

return M
