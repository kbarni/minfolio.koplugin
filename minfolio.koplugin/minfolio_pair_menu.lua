-- SPDX-License-Identifier: AGPL-3.0-only
-- The Kindle pairing menu for minfolio.koplugin (PAIRING_PLAN.md WP 3):
-- arm/disarm with the remaining window, the Kindle-generated verification
-- code, which channel is in play, and a paired-desktops list with delete.
-- Requires KOReader's UI stack (`ui/widget/menu`, `ui/widget/confirmbox`,
-- `ui/widget/infomessage`, `ui/font`, `device`, `ui/uimanager`) throughout, so
-- this cannot be `require`d and executed under plain luajit -- only
-- `loadfile`-parsed, exactly like main.lua and minfolio_pair.lua themselves --
-- so no off-device test suite is included. The logic it displays
-- (minfolio_pair.lua's arming state machine, minfolio_pairing_store.lua's
-- keyed store) is tested independently; this module is presentation only.
--
-- Deliberately does NOT use KOReader's stock main-menu `sub_item_table`/
-- `sub_item_table_func` mechanism: neither sibling plugin in this toolchain
-- (kshell.koplugin, kinbox.koplugin) uses it anywhere, so there is no local
-- precedent that the top-level `registerToMainMenu` menu actually honours
-- it, and no device available this session to check. Instead this builds
-- its own popout `Menu` widget exactly the way minfolio_chrome.lua's
-- `show_controls` already does (item_table + a custom onMenuSelect) --
-- that mechanism is a real, already-shipped feature of this same plugin, so
-- copying its shape is evidence-based rather than a second guess about
-- what the stock menu accepts. main.lua wires a single new top-level entry
-- (menu_items.minfolio_pairing) straight to M.open() below; the existing
-- "Minfolio" entry and its one-tap "open notes" behaviour are untouched.
--
-- Text is rebuilt (M._buildItems) and pushed back into the visible menu via
-- `menu:switchItemTable` -- also proven in this codebase, at the same call
-- site in minfolio_chrome.lua -- after every state-changing action (arm,
-- disarm, delete), so the remaining-window countdown and paired-desktop
-- list are current as of the last thing the user did. This deliberately
-- does NOT also tick on a timer while the menu merely sits open: an
-- unverified-on-device repeating repaint is a worse risk than a countdown
-- that is accurate as of the last tap rather than the last second -- see
-- this work's own report for the tradeoff.
--
-- Required by callers as `local PairMenu = require("minfolio_pair_menu")`.

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local Device = require("device")
local Screen = Device.screen
local _ = require("gettext")

local Pair = require("minfolio_pair")
local Store = require("minfolio_pairing_store")
local Config = require("minfolio_config")
local Chrome = require("minfolio_chrome")

local M = {}

local function channel_label(channel)
    if channel == "udp+ssh" then
        return _("UDP direct + SSH file drop")
    elseif channel == "ssh-only" then
        return _("SSH file drop only (firewall rule unavailable)")
    end
    return _("not armed yet")
end

-- Deleting here removes only the LOCAL record (PAIRING_PLAN.md §5.7: "Kindle-
-- side deletion IS revocation once §5.2 lands" -- §5.2, the SSH-free
-- descriptor pull that would let the Kindle itself tell the desktop, is
-- explicitly out of scope for this work). Said plainly in the confirmation
-- text rather than left implied, so a user isn't misled into thinking a
-- local delete alone revokes a desktop that's currently unreachable.
local function confirm_delete(entry, refresh)
    UIManager:show(ConfirmBox:new{
        text = _("Remove pairing for ") .. entry.label .. _("?\n\n")
            .. _("This deletes the record on THIS Kindle only. If the desktop is "
                .. "unreachable it will still consider itself paired until it is told "
                .. "separately -- a pending revocation, not a completed one."),
        ok_text = _("Remove"),
        ok_callback = function()
            local store = Store.load(Config.MINFOLIO_PAIR_PATH)
            Store.delete(store, entry.fingerprint)
            local saved, err = Store.save(Config.MINFOLIO_PAIR_PATH, store)
            if saved then
                Chrome.notify(_("Removed ") .. entry.label)
            else
                Chrome.notify(_("Could not save after removing: ") .. tostring(err or "unknown error"))
            end
            refresh()
        end,
    })
end

local function build_items(refresh)
    local items = {}

    if Pair.isArmed() then
        items[#items + 1] = {
            text = string.format(_("Disarm pairing (%ds left, %s)"),
                Pair.armedRemainingSeconds(), channel_label(Pair.armedChannel())),
            callback = function()
                Pair.disarm()
                Chrome.notify(_("Pairing disarmed"))
                refresh()
            end,
        }
        local code = Pair.currentCode() or "------"
        items[#items + 1] = {
            text = _("Verification code: ") .. code .. _("  (tap to enlarge)"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = code,
                    face = Font:getFace("cfont", 64),
                })
            end,
        }
        items[#items + 1] = {
            text = _("Channel in play: ") .. channel_label(Pair.armedChannel()),
            callback = function() end,
        }
    else
        items[#items + 1] = {
            text = _("Arm pairing (opens a 120s window)"),
            callback = function()
                local ok, _code, channel, err = Pair.arm()
                if ok then
                    Chrome.notify(_("Pairing armed: ") .. channel_label(channel))
                else
                    Chrome.notify(_("Could not arm pairing: ") .. tostring(err or "unknown error"))
                end
                refresh()
            end,
        }
        items[#items + 1] = {
            text = _("Verification code: arm pairing to generate one"),
            callback = function() end,
        }
    end

    items[#items + 1] = {
        text = _("---- Paired desktops ----"),
        callback = function() end,
    }

    local store = Store.load(Config.MINFOLIO_PAIR_PATH)
    local list = Store.list(store)
    if #list == 0 then
        items[#items + 1] = { text = _("No paired desktops yet"), callback = function() end }
    else
        for _, entry in ipairs(list) do
            items[#items + 1] = {
                text = string.format("%s  [%s]", entry.label, entry.fingerprint:sub(-12)),
                callback = function() confirm_delete(entry, refresh) end,
            }
        end
    end

    return items
end

function M.open()
    local menu
    local function refresh()
        if not menu then return end
        menu:switchItemTable(_("Minfolio Pairing"), build_items(refresh))
    end
    menu = Menu:new{
        title = _("Minfolio Pairing"),
        item_table = build_items(refresh),
        is_popout = true,
        width = math.floor(Screen:getWidth() * 0.85),
        height = math.floor(Screen:getHeight() * 0.75),
        -- Every row here manages its own state change and its own refresh()
        -- call (arm/disarm/delete), so onMenuSelect's only job is to run the
        -- tapped row's callback and leave the menu open -- there is no
        -- sub_item_table/keep distinction to make here, unlike
        -- minfolio_chrome.lua's show_controls, which this is otherwise
        -- modelled on.
        onMenuSelect = function(_self, item)
            if item.callback then item.callback() end
        end,
    }
    UIManager:show(menu)
end

return M
