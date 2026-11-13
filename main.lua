-- main.lua
-- Performance Guard: Anti-ANR, Input Throttling, and SDR Storage Optimization

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local logger = require("logger")
local _ = require("gettext")

-- Determine plugin path for relative requires
local plugin_name = (...)
local plugin_dir = ""
if type(plugin_name) == "string" then
    plugin_dir = plugin_name:match("(.-)[^/%.]+$") or ""
end

local InputGuard = require(plugin_dir .. "lib/input_guard")
local SdrRedirect = require(plugin_dir .. "lib/sdr_redirect")

local PerformanceGuard = WidgetContainer:extend{
    name = "performance_guard",
    is_doc_only = false,
}

function PerformanceGuard:init()
    PerformanceGuard.instance = self

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Load settings
    local input_guard_enabled = true
    local sdr_redirect_enabled = true

    if G_reader_settings and G_reader_settings.readSetting then
        local inp_val = G_reader_settings:readSetting("perf_guard_input_enabled")
        if inp_val ~= nil then input_guard_enabled = (inp_val == true) end
        local sdr_val = G_reader_settings:readSetting("perf_guard_sdr_enabled")
        if sdr_val ~= nil then sdr_redirect_enabled = (sdr_val == true) end
    end

    InputGuard.enabled = input_guard_enabled
    InputGuard.init(self)

    SdrRedirect.enabled = sdr_redirect_enabled
    SdrRedirect.init(self)

    logger.info(string.format("[PerformanceGuard] Initialized (InputGuard: %s, SdrRedirect: %s)",
        tostring(input_guard_enabled), tostring(sdr_redirect_enabled)))
end

function PerformanceGuard:onFocusChanged(has_focus)
    InputGuard.onFocusChanged(has_focus)
end

function PerformanceGuard:onResume()
    InputGuard.onResume()
end

function PerformanceGuard:onSuspend()
    InputGuard.onSuspend()
end

function PerformanceGuard:onPause()
    InputGuard.onPause()
end

function PerformanceGuard:runMigration()
    local confirm = ConfirmBox:new{
        text = _("Scan external MicroSD storage and migrate all book .sdr metadata folders to fast internal storage?\n\nThis completely eliminates MicroSD write stalls during page turns and prevents metadata corruption."),
        ok_text = _("Migrate Now"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local notif = Notification:new{
                text = _("Scanning for metadata folders to migrate..."),
            }
            UIManager:show(notif)

            local progress_cb = function(idx, total, migrated)
                if notif and notif.setText then
                    notif:setText(string.format(_("Migrating metadata: %d / %d folders..."), idx, total))
                    UIManager:setDirty(notif, "ui")
                end
            end

            local on_complete = function(res)
                if notif then UIManager:close(notif) end
                if res.total == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No .sdr metadata folders found on external MicroSD storage.\n\nAll books are already using internal storage or have no cached metadata."),
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Migration Complete!\n\nSuccessfully migrated %d of %d metadata folders (%d files) to fast internal storage.\nFailed: %d"),
                            res.migrated, res.total, res.files, res.failed),
                    })
                end
            end

            SdrRedirect.migrateExternalSdr(progress_cb, on_complete)
        end,
    }
    UIManager:show(confirm)
end

function PerformanceGuard:addToMainMenu(menu_items)
    menu_items.performance_guard = {
        text = _("Performance Guard"),
        sorting_hint = "device",
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _("Anti-ANR Input Guard"),
                    help_text = _("Prevents Android ANR freezes and catch-up page flurries by pruning stale queued touches when page decoding causes latency."),
                    checked_func = function()
                        return InputGuard.isEnabled()
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local new_val = not InputGuard.isEnabled()
                        if new_val then
                            InputGuard.enable()
                        else
                            InputGuard.disable()
                        end
                        if G_reader_settings then
                            G_reader_settings:saveSetting("perf_guard_input_enabled", new_val)
                            pcall(function() G_reader_settings:flush() end)
                        end
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("MicroSD SDR Centralization"),
                    help_text = _("Routes book reading metadata (.sdr) from external MicroSD storage to fast internal storage, eliminating flash write latency spikes during page turns."),
                    checked_func = function()
                        return SdrRedirect.isEnabled()
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local new_val = not SdrRedirect.isEnabled()
                        if new_val then
                            SdrRedirect.enable()
                        else
                            SdrRedirect.disable()
                        end
                        if G_reader_settings then
                            G_reader_settings:saveSetting("perf_guard_sdr_enabled", new_val)
                            pcall(function() G_reader_settings:flush() end)
                        end
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("Migrate MicroSD .sdr folders to internal storage…"),
                    help_text = _("Safely copies existing .sdr folders from your MicroSD card into internal storage and removes the originals."),
                    keep_menu_open = true,
                    callback = function()
                        self:runMigration()
                    end,
                },
                {
                    text = _("Hardware: SanDisk A2 (Optimal IOPS)"),
                    help_text = _("Your MicroSD card supports Application Performance Class A2 (4000 read IOPS / 2000 write IOPS)."),
                    enabled_func = function() return false end,
                },
            }
        end,
    }
end

return PerformanceGuard
