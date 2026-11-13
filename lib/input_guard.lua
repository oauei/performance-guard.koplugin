-- lib/input_guard.lua
-- Anti-ANR Input Throttling and Stale Gesture Coalescing

local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local function to_seconds(fts)
    if type(fts) ~= "number" then return 0 end
    if time and time.to_s then return time.to_s(fts) end
    if fts > 100000 then return fts / 1000000 end
    return fts
end

local function to_fts(sec)
    if type(sec) ~= "number" then return 0 end
    if time and time.s then return time.s(sec) end
    return sec * 1000000
end

local InputGuard = {
    enabled = true,
    initialized = false,
    stall_threshold_s = 1.2,   -- 1.2s delay in event loop tick indicates a genuine UI stall
    catchup_window_s = 0.4,     -- 400ms window after stall to suppress queued input flurry
    post_focus_window_s = 0.5,  -- 500ms after focus regain to drop stale gestures (ANR loop breaker)
    flurry_interval_s = 0.15,   -- 150ms minimum interval between duplicate taps during stall recovery
    watchdog_interval_s = 0.25, -- 250ms event-loop watchdog heartbeat

    last_heartbeat = 0,
    stall_recovery_until = 0,
    ignore_gestures_until = 0,
    last_dispatched_tap_time = 0,
    watchdog_timer = nil,
    orig_sendEvent = nil,
}

local function isHighLevelGesture(event)
    if not event or not event.name then return false end
    local name = event.name
    return name == "Tap" or name == "Swipe" or name == "MultiSwipe"
end

local function isAnyGesture(event)
    if not event or not event.name then return false end
    local name = event.name
    return name == "Tap" or name == "Swipe" or name == "MultiSwipe" or name == "Touch"
end

function InputGuard.scheduleWatchdog()
    if not InputGuard.enabled then return end
    if InputGuard.watchdog_timer then
        UIManager:unschedule(InputGuard.watchdog_timer)
        InputGuard.watchdog_timer = nil
    end

    InputGuard.last_heartbeat = time.now()

    local function heartbeatTick()
        InputGuard.watchdog_timer = nil
        if not InputGuard.enabled then return end

        local now = time.now()
        local elapsed = to_seconds(now - InputGuard.last_heartbeat)

        -- If elapsed time significantly exceeds the 250ms scheduled interval,
        -- the main event loop was blocked by heavy processing / GC / I/O.
        if elapsed > InputGuard.stall_threshold_s then
            logger.warn(string.format("[PerformanceGuard] UI thread stall detected: %.2fs (threshold: %.2fs)",
                elapsed, InputGuard.stall_threshold_s))
            InputGuard.stall_recovery_until = now + to_fts(InputGuard.catchup_window_s)
        end

        InputGuard.last_heartbeat = now
        InputGuard.watchdog_timer = heartbeatTick
        UIManager:scheduleIn(InputGuard.watchdog_interval_s, heartbeatTick)
    end

    InputGuard.watchdog_timer = heartbeatTick
    UIManager:scheduleIn(InputGuard.watchdog_interval_s, heartbeatTick)
end

function InputGuard.init(plugin_instance)
    if InputGuard.initialized then return end

    InputGuard.plugin = plugin_instance
    InputGuard.last_heartbeat = time.now()

    if not UIManager._perf_guard_patched then
        UIManager._perf_guard_patched = true
        InputGuard.orig_sendEvent = UIManager.sendEvent

        UIManager.sendEvent = function(self_ui, event)
            if not InputGuard.enabled or not event then
                return InputGuard.orig_sendEvent(self_ui, event)
            end

            local now = time.now()

            -- 1. Check post-focus window (e.g. after clicking 'Wait' on Android ANR dialog)
            if now < InputGuard.ignore_gestures_until then
                if isAnyGesture(event) then
                    logger.info("[PerformanceGuard] Discarded stale gesture during post-focus ANR recovery window: " .. tostring(event.name))
                    return true -- Consumed
                end
            end

            -- 2. Check stall recovery window: suppress rapid duplicate flurry gestures
            -- Normal human taps are dispatched immediately with 0ms delay.
            -- Only high-level gestures (Tap/Swipe) arriving within flurry_interval_s of each
            -- other during a post-stall recovery window are suppressed.
            if now < InputGuard.stall_recovery_until and isHighLevelGesture(event) then
                local time_since_last_tap = to_seconds(now - InputGuard.last_dispatched_tap_time)
                if time_since_last_tap < InputGuard.flurry_interval_s then
                    logger.info(string.format("[PerformanceGuard] Suppressed rapid duplicate flurry '%s' (%.3fs since last tap) during stall recovery",
                        tostring(event.name), time_since_last_tap))
                    return true -- Suppress duplicate flurry gesture
                end
                InputGuard.last_dispatched_tap_time = now
            end

            -- Record tap time for non-stall conditions as well
            if isHighLevelGesture(event) then
                InputGuard.last_dispatched_tap_time = now
            end

            -- Dispatch immediately with 0ms delay to preserve widget state and menu responsiveness
            return InputGuard.orig_sendEvent(self_ui, event)
        end
    end

    InputGuard.scheduleWatchdog()
    InputGuard.initialized = true
    logger.info("[PerformanceGuard] InputGuard initialized successfully with event-loop watchdog")
end

function InputGuard.onFocusChanged(has_focus)
    if has_focus then
        local now = time.now()
        InputGuard.ignore_gestures_until = now + to_fts(InputGuard.post_focus_window_s)
        InputGuard.last_heartbeat = now -- Reset heartbeat so window focus regain doesn't trigger false stall
        logger.info("[PerformanceGuard] Window focus regained: ignoring stale buffered inputs for 500ms to break ANR loop")
    end
end

function InputGuard.onResume()
    local now = time.now()
    InputGuard.ignore_gestures_until = now + to_fts(InputGuard.post_focus_window_s)
    InputGuard.last_heartbeat = now -- Reset heartbeat so resume from standby doesn't trigger false stall
    InputGuard.scheduleWatchdog()
    logger.info("[PerformanceGuard] Application resumed: refreshed input guard watchdog")
end

function InputGuard.enable()
    InputGuard.enabled = true
    InputGuard.last_heartbeat = time.now()
    InputGuard.scheduleWatchdog()
end

function InputGuard.disable()
    InputGuard.enabled = false
    if InputGuard.watchdog_timer then
        UIManager:unschedule(InputGuard.watchdog_timer)
        InputGuard.watchdog_timer = nil
    end
end

function InputGuard.isEnabled()
    return InputGuard.enabled
end

return InputGuard
