-- SPDX-License-Identifier: AGPL-3.0-only
-- Keyboard modifier decoding, key-name aliasing, and direction predicates for
-- minfolio.koplugin (PLAN.md §5 Tier 1). Requires KOReader: `key_mods` reads
-- `Device.input.modifiers` and `install_keyboard_aliases` patches
-- `Device.input.event_map`/`Device.input.modifiers` directly, so this module
-- requires `device`. Because it requires a real KOReader module, this cannot be
-- `require`d and executed under plain luajit -- only `loadfile`-parsed, exactly
-- like main.lua itself -- so no off-device test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 1, §10 step 4):
-- SHIFT_SYM, KEYPAD_CHAR, KEYBOARD_EVENT_MAP, keymod, shortcut_mod, word_key_mod,
-- fn_key_mod, key_mods, install_keyboard_aliases, page_up_key, page_down_key,
-- left_key, right_key, up_key, down_key.
--
-- Also relocated here (PLAN.md §5 Tier 1, §1): makeKeyboardArrowFree and
-- disableKeyboardKeyFlash, formerly MinfolioPair.makeKeyboardArrowFree/
-- .disableKeyboardKeyFlash. Despite the MinfolioPair name, neither is a pairing
-- concern -- both operate on a KOReader VirtualKeyboard instance passed in as an
-- argument. main.lua's own former comment (immediately above what was
-- MinfolioPair.trace) explained they were parked on that table only because
-- table fields do not consume the 200-local budget this refactor removes. Used
-- by both the mindmap and the editor (both still inline in main.lua as of this
-- work package). Every call site's `MinfolioPair.makeKeyboardArrowFree(...)` /
-- `MinfolioPair.disableKeyboardKeyFlash(...)` became `Keys.makeKeyboardArrowFree(...)`
-- / `Keys.disableKeyboardKeyFlash(...)`.
--
-- Required by callers as `local Keys = require("minfolio_keys")`.

local Device = require("device")

local M = {}

-- KOReader's stock English keyboard devotes two bottom-row cells to cursor
-- arrows (and exposes up/down on the symbol layers of N and M).  They are easy
-- to hit accidentally in a compact editor, so make an app-local copy with no
-- arrow actions.  Do not mutate the shared layout module: other KOReader views
-- should retain their normal keyboard.
function M.makeKeyboardArrowFree(keyboard)
    local rows, removed = {}, 0
    for _, row in ipairs(keyboard.KEYS or {}) do
        local new_row = {}
        for _, keydef in ipairs(row) do
            local label = type(keydef) == "table" and keydef.label or keydef
            if label == "←" or label == "→" or label == "↑" or label == "↓" then
                removed = removed + 1
            else
                local copy = {}
                if type(keydef) == "table" then
                    for k, v in pairs(keydef) do copy[k] = v end
                    -- N/M use arrows only in the alternate layers.  Retain the
                    -- character rather than leaving an invisible, active key.
                    for k, v in ipairs(copy) do
                        if v == "↑" or v == "↓" or v == "←" or v == "→" then
                            copy[k] = copy[2] or copy[1] or ""
                        end
                    end
                else
                    copy = keydef
                end
                table.insert(new_row, copy)
            end
        end
        table.insert(rows, new_row)
    end
    if removed == 0 then return end
    -- On the English layout this exactly fills the two removed bottom-row cells.
    local last_row = rows[#rows]
    for _, keydef in ipairs(last_row or {}) do
        if type(keydef) == "table" and keydef.label == "_" then
            keydef.width = (tonumber(keydef.width) or 1) + removed
            break
        end
    end
    keyboard.KEYS = rows
    keyboard:initLayer(keyboard.keyboard_layer)
end

function M.disableKeyboardKeyFlash(keyboard)
    -- VirtualKey normally calls forceRePaint() and yieldToEPDC() for every tap
    -- when the global setting is absent (its default is enabled).  On e-ink that
    -- synchronous wait prevents the touch queue from keeping up with fast typing.
    -- Keep this local to Minfolio and reapply it whenever Shift/Symbol rebuilds
    -- the key widgets.
    local stock_init_layer = keyboard.initLayer
    function keyboard:initLayer(layer)
        stock_init_layer(self, layer)
        for _, row in ipairs(self.layout or {}) do
            for _, key in ipairs(row) do key.flash_keyboard = false end
        end
    end
    keyboard:initLayer(keyboard.keyboard_layer)
end

-- Shift map for BT-keyboard symbol keys (used by MDEdit:onKeyPress).
M.SHIFT_SYM = {
    ["1"]="!", ["2"]="@", ["3"]="#", ["4"]="$", ["5"]="%", ["6"]="^", ["7"]="&", ["8"]="*", ["9"]="(", ["0"]=")",
    ["-"]="_", ["="]="+", ["["]="{", ["]"]="}", ["\\"]="|", [";"]=":", ["'"]='"', [","]="<", ["."]=">", ["/"]="?", ["`"]="~",
}
M.KEYPAD_CHAR = {
    KP0 = "0", KP1 = "1", KP2 = "2", KP3 = "3", KP4 = "4", KP5 = "5", KP6 = "6", KP7 = "7", KP8 = "8", KP9 = "9",
    KPMinus = "-", KPPlus = "+", KPDot = ".",
}
M.KEYBOARD_EVENT_MAP = {
    [1]="Back", [2]="1", [3]="2", [4]="3", [5]="4", [6]="5", [7]="6", [8]="7", [9]="8", [10]="9", [11]="0",
    [12]="-", [13]="=", [14]="Backspace", [15]="Tab",
    [16]="Q", [17]="W", [18]="E", [19]="R", [20]="T", [21]="Y", [22]="U", [23]="I", [24]="O", [25]="P",
    [26]="[", [27]="]", [28]="Press", [29]="Ctrl",
    [30]="A", [31]="S", [32]="D", [33]="F", [34]="G", [35]="H", [36]="J", [37]="K", [38]="L", [39]=";", [40]="'",
    [41]="`", [42]="Shift", [43]="\\",
    [44]="Z", [45]="X", [46]="C", [47]="V", [48]="B", [49]="N", [50]="M", [51]=",", [52]=".", [53]="/",
    [54]="Shift", [56]="Alt", [57]=" ", [58]="CapsLock",
    [59]="F1", [60]="F2", [61]="F3", [62]="F4", [63]="F5", [64]="F6", [65]="F7", [66]="F8", [67]="F9", [68]="F10",
    [69]="NumLock", [70]="ScrollLock",
    [71]="KP7", [72]="KP8", [73]="KP9", [74]="KPMinus", [75]="KP4", [76]="KP5", [77]="KP6", [78]="KPPlus",
    [79]="KP1", [80]="KP2", [81]="KP3", [82]="KP0", [83]="KPDot", [87]="F11", [88]="F12", [96]="Press",
    [97]="Ctrl", [98]="Home", [99]="PrintScr", [100]="Alt", [102]="Home", [103]="Up", [104]="PageUp",
    [105]="Left", [106]="Right", [107]="End", [108]="Down", [109]="PageDown", [110]="Ins", [111]="Del",
    [114]="VMinus", [115]="VPlus", [116]="Power", [119]="Pause", [125]="Meta", [126]="Meta", [127]="Menu", [139]="Menu",
}
function M.keymod(mods, name)
    if not mods then return nil end
    if type(mods) == "string" then
        return mods == name or mods:lower() == name:lower()
    end
    if mods[name] or mods[name:lower()] or mods[name:upper()] then return true end
    if name == "Ctrl" then return mods.LCtrl or mods.RCtrl end
    if name == "Alt" then return mods.LAlt or mods.RAlt end
    if name == "Meta" then return mods.LMeta or mods.RMeta end
    if name == "Shift" then return mods.LShift or mods.RShift end
    for _, mod in pairs(mods) do
        if type(mod) == "string" and (mod == name or mod:lower() == name:lower()) then return true end
    end
    return nil
end
function M.shortcut_mod(mods)
    return M.keymod(mods, "Ctrl") or M.keymod(mods, "Meta") or M.keymod(mods, "Cmd")
        or M.keymod(mods, "Command") or M.keymod(mods, "Gui") or M.keymod(mods, "Super")
end
function M.word_key_mod(mods)
    return M.keymod(mods, "Alt") or M.shortcut_mod(mods)
end
function M.fn_key_mod(mods)
    return M.keymod(mods, "Fn") or M.keymod(mods, "Function") or M.keymod(mods, "Mod5")
end
function M.key_mods(key)
    local out = {}
    if Device.input and type(Device.input.modifiers) == "table" then
        for k, v in pairs(Device.input.modifiers) do out[k] = v end
    end
    if key and type(key.modifiers) == "table" then
        for k, v in pairs(key.modifiers) do out[k] = v end
    end
    if key then
        for _, name in ipairs({
            "Shift", "LShift", "RShift",
            "Ctrl", "LCtrl", "RCtrl",
            "Alt", "LAlt", "RAlt",
            "Meta", "LMeta", "RMeta",
            "Cmd", "Command", "Gui", "Super",
            "Fn", "Function", "Mod5",
        }) do
            if key[name] then out[name] = true end
        end
    end
    return out
end
function M.install_keyboard_aliases()
    local input = Device.input
    if not input then return end
    local em = input.event_map
    if em then
        for code, name in pairs(M.KEYBOARD_EVENT_MAP) do
            em[code] = name
        end
    end
    local mods = input.modifiers
    if mods then
        mods.Alt = mods.Alt or false
        mods.Ctrl = mods.Ctrl or false
        mods.Shift = mods.Shift or false
        mods.Meta = mods.Meta or false
        mods.LAlt = mods.LAlt or false
        mods.RAlt = mods.RAlt or false
        mods.LCtrl = mods.LCtrl or false
        mods.RCtrl = mods.RCtrl or false
        mods.LShift = mods.LShift or false
        mods.RShift = mods.RShift or false
        mods.LMeta = mods.LMeta or false
        mods.RMeta = mods.RMeta or false
        mods.Fn = mods.Fn or false
        mods.Function = mods.Function or false
        mods.Mod5 = mods.Mod5 or false
    end
end
function M.page_up_key(name)
    return name == "PageUp" or name == "Page_Up" or name == "PgUp" or name == "Prior"
end
function M.page_down_key(name)
    return name == "PageDown" or name == "Page_Down" or name == "PgDown" or name == "Next"
end
function M.left_key(name)
    return name == "Left" or name == "ArrowLeft" or name == "KEY_LEFT" or name == "CursorLeft"
end
function M.right_key(name)
    return name == "Right" or name == "ArrowRight" or name == "KEY_RIGHT" or name == "CursorRight"
end
function M.up_key(name)
    return name == "Up" or name == "ArrowUp" or name == "KEY_UP" or name == "CursorUp"
end
function M.down_key(name)
    return name == "Down" or name == "ArrowDown" or name == "KEY_DOWN" or name == "CursorDown"
end

return M
