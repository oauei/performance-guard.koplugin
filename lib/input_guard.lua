-- lib/input_guard.lua
-- Anti-ANR Input Throttling and Stale Gesture Coalescing

local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local InputGuard = {
    enabled = true,
    initialized = false,
    stall_threshold = 1.2, -- 1.2s frame render delay indicates a stall
    catchup_window = 0.4,   -- 400ms window after stall to coalesce queued input flurry
    post_focus_window = 0.5,-- 500ms after focus regain to drop stale gestures (ANR loop breaker)
    last_loop_time = 0,
    stall_recovery_until = 0,
    ignore_gestures_until = 0,
    pending_gesture = nil,
    pending_timer = nil,
    orig_sendEvent = nil,
}

local function isCoalescableGesture(event)
    if not event or not event.name then return false end
    local name = event.name
    return name == "Tap" or name == "Swipe" or name == "MultiSwipe" or name == "Touch"
end

function InputGuard.init(plugin_instance)
    if InputGuard.initialized then return end

    InputGuard.plugin = plugin_instance
    InputGuard.last_loop_time = time.now()

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
                if isCoalescableGesture(event) then
                    logger.info("[PerformanceGuard] Discarded stale gesture during post-focus ANR recovery window: " .. tostring(event.name))
                    return true -- Consumed
                end
            end

            -- 2. Check for main loop render / decode stall
            local delta = now - InputGuard.last_loop_time
            if delta > InputGuard.stall_threshold then
                logger.warn(string.format("[PerformanceGuard] Main loop stall detected: %.2fs (threshold: %.2fs)", delta, InputGuard.stall_threshold))
                InputGuard.stall_recovery_until = now + InputGuard.catchup_window
            end
            InputGuard.last_loop_time = now

            -- 3. If in stall recovery window, coalesce navigation gestures
            if now < InputGuard.stall_recovery_until and isCoalescableGesture(event) then
                logger.info(string.format("[PerformanceGuard] Coalescing queued gesture '%s' during stall recovery", tostring(event.name)))
                InputGuard.pending_gesture = event

                if InputGuard.pending_timer then
                    UIManager:unschedule(InputGuard.pending_timer)
                    InputGuard.pending_timer = nil
                end

                InputGuard.pending_timer = function()
                    InputGuard.pending_timer = nil
                    if InputGuard.pending_gesture then
                        local g = InputGuard.pending_gesture
                        InputGuard.pending_gesture = nil
                        logger.info(string.format("[PerformanceGuard] Dispatching single coalesced gesture '%s'", tostring(g.name)))
                        pcall(InputGuard.orig_sendEvent, self_ui, g)
                    end
                end

                UIManager:scheduleIn(0.05, InputGuard.pending_timer)
                return true -- Consumed intermediate duplicate
            end

            return InputGuard.orig_sendEvent(self_ui, event)
        end
    end

    InputGuard.initialized = true
    logger.info("[PerformanceGuard] InputGuard initialized successfully")
end

function InputGuard.onFocusChanged(has_focus)
    if has_focus then
        local now = time.now()
        InputGuard.ignore_gestures_until = now + InputGuard.post_focus_window
        InputGuard.last_loop_time = now
        logger.info("[PerformanceGuard] Window focus regained: ignoring stale buffered inputs for 500ms to break ANR loop")
    end
end

function InputGuard.onResume()
    local now = time.now()
    InputGuard.ignore_gestures_until = now + InputGuard.post_focus_window
    InputGuard.last_loop_time = now
    logger.info("[PerformanceGuard] Application resumed: refreshing input guard watchdog")
end

function InputGuard.enable()
    InputGuard.enabled = true
    InputGuard.last_loop_time = time.now()
end

function InputGuard.disable()
    InputGuard.enabled = false
    if InputGuard.pending_timer then
        UIManager:unschedule(InputGuard.pending_timer)
        InputGuard.pending_timer = nil
    end
    InputGuard.pending_gesture = nil
end

function InputGuard.isEnabled()
    return InputGuard.enabled
end

return InputGuard
