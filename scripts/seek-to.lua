-- Original script from https://github.com/occivink/mpv-scripts/blob/master/scripts/seek-to.lua
local o = {
    mouse_controls = true,
    selection_color = "FFCF46",
    selection_border_color = "",
}
(require 'mp.options').read_options(o)

local assdraw = require 'mp.assdraw'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local platform = mp.get_property_native("platform")
local active = false
local cursor_position = 1
local time_scale = {60*60*10, 60*60, 60*10, 60, 10, 1, 0.1, 0.01, 0.001}

local ass_begin = mp.get_property("osd-ass-cc/0")
local ass_end = mp.get_property("osd-ass-cc/1")

local history = { {} }
for i = 1, 9 do
    history[1][i] = 0
end
local history_position = 1

-- timer to redraw periodically the message
-- to avoid leaving bindings when the seeker disappears for whatever reason
-- pretty hacky tbh
local blink_timer = nil
local timer_duration = 3
local blink_rate = 2                                    -- ( 1 / blink_rate )

local underline_on = "{\\u1}"                           -- Enable underline
local underline_off = "{\\u0}"                          -- Disable underline
local underline_forced = true                           -- Always start with underline on

local ss = "{\\fscx0}"                                  -- Scale 0 to limit additional width of the hairspace
local se = "{\\fscx100}"                                -- Reset scale
local fb = "{\\b1}"                                     -- Force bold font to even out the spacing
local hs = ss .. string.char(0xE2, 0x80, 0x8A) .. se    -- Insert 'hair space' after first digit to avoid shifting when two 1's are beside each other (11:11:11.111)

-- Convert RRGGBB to BBGGRR for user convenience
local selection_color       = string.format("{\\c&%s}", o.selection_color:gsub("(%x%x)(%x%x)(%x%x)","%3%2%1"))
local selection_border_color    = string.format("{\\3c&%s}", o.selection_border_color:gsub("(%x%x)(%x%x)(%x%x)","%3%2%1"))

function show_seeker()
    local prepend_char = {'','' .. hs,':','' .. hs,':','' .. hs,'.','' .. hs,'' .. hs}
    local str = ''

    for i = 1, 9 do
        str = str .. prepend_char[i]
        if i == cursor_position then
            if underline_forced or digit_switched then  -- Force underline into _on state on start or after switching to another digit
                underline = underline_on
                underline_forced = false
                digit_switched = false
            else
                underline = (mp.get_time() * blink_rate % 2 < 1) and underline_on or underline_off
            end
            str = str .. selection_color .. underline .. selection_border_color .. history[history_position][i] .. '{\\r}' .. fb
        else
            str = str .. history[history_position][i]
        end
    end
    local prefix = seek_from_end and "\u{21BA}" or (seek_sub and "\u{229D}" or (seek_add and "\u{2295}" or ""))
    mp.osd_message(ass_begin .. fb .. "Seek to: " .. prefix .. str .. ass_end, timer_duration)
end

function copy_history_to_last()
    if history_position ~= #history then
        for i = 1, 9 do
            history[#history][i] = history[history_position][i]
        end
        history_position = #history
    end
end

function change_number(i)
    -- can't set above 60 minutes or seconds
    if (cursor_position == 3 or cursor_position == 5) and i >= 6 then
        return
    end
    if history[history_position][cursor_position] ~= i then
        copy_history_to_last()
        history[#history][cursor_position] = i
    end
    shift_cursor(false)
end

function shift_cursor(left)
    if left then
        cursor_position = math.max(1, cursor_position - 1)
    else
        cursor_position = math.min(cursor_position + 1, 9)
    end
    digit_switched = true
end

function current_time_as_sec(time)
    local sec = 0
    for i = 1, 9 do
        sec = sec + time_scale[i] * time[i]
    end
    return sec
end

function time_equal(lhs, rhs)
    for i = 1, 9 do
        if lhs[i] ~= rhs[i] then
            return false
        end
    end
    return true
end

function seek_to()
    copy_history_to_last()
    local seek_time = current_time_as_sec(history[history_position])
    local duration = mp.get_property_native("duration")
    local current_time = mp.get_property_native("time-pos")
    if (seek_add or seek_sub or seek_from_end) and seek_time == 0 then return end   -- Avoid jumps in certain video types that can happen even with empty timestamp
    if seek_sub then
        seek_time = math.max(0, current_time - seek_time)
    elseif seek_add then
        seek_time = current_time + seek_time
    end
    if seek_time > duration then
        mp.osd_message("The timestamp is longer than the duration of the video")
        mp.msg.warn("The timestamp is longer than the duration of the video")
        message_displayed = true
        return
    end
    local prefix = seek_from_end and "-" or ""
    mp.commandv("osd-bar", "seek", prefix .. seek_time, "absolute")
    --deduplicate consecutive timestamps
    if #history == 1 or not time_equal(history[history_position], history[#history - 1]) then
        history[#history + 1] = {}
        history_position = #history
    end
    for i = 1, 9 do
        history[#history][i] = 0
    end
end

function backspace()
    if history[history_position][cursor_position] ~= 0 then
        copy_history_to_last()
        history[#history][cursor_position] = 0
    end
    shift_cursor(true)
end

function history_move(up)
    if up then
        history_position = math.max(1, history_position - 1)
    else
        history_position = math.min(history_position + 1, #history)
    end
end

function toggle_seek_mode(mode)
    if mode == "seek_from_end" then
        seek_from_end = not seek_from_end
        seek_add, seek_sub = false, false
    elseif mode == "seek_add" then
        seek_add = not seek_add
        seek_from_end, seek_sub = false, false
    elseif mode == "seek_sub" then
        seek_sub = not seek_sub
        seek_from_end, seek_add = false, false
    end
    show_seeker()
end

local key_mappings = {
    LEFT            = function() shift_cursor(true) show_seeker() end,
    RIGHT           = function() shift_cursor(false) show_seeker() end,
    SPACE           = function() shift_cursor(false) show_seeker() end,
    UP              = function() history_move(true) show_seeker() end,
    DOWN            = function() history_move(false) show_seeker() end,
    BS              = function() backspace() show_seeker() end,
    KP_ENTER        = function() seek_to() set_inactive() end,
    ENTER           = function() seek_to() set_inactive() end,
    ESC             = function() set_inactive() end,
    ["ctrl+v"]      = function() paste_timestamp() end,
    ["KP_ADD"]      = function() toggle_seek_mode("seek_add") end,
    ["KP_SUBTRACT"] = function() toggle_seek_mode("seek_sub") end,
    ["KP_MULTIPLY"] = function() toggle_seek_mode("seek_from_end") end,
    ["-"]           = function() toggle_seek_mode("seek_sub") end,
    ["+"]           = function() toggle_seek_mode("seek_add") end,
    ["="]           = function() toggle_seek_mode("seek_from_end") end,
}

-- Mouse controls
if o.mouse_controls then
    key_mappings.WHEEL_UP       = function() shift_cursor(true) show_seeker() end
    key_mappings.WHEEL_DOWN     = function() shift_cursor(false) show_seeker() end
    key_mappings.MBTN_RIGHT     = function() backspace() show_seeker() end
    key_mappings.MBTN_RIGHT_DBL = function() return end
    key_mappings.MBTN_MID       = function() seek_to() set_inactive() end
end

for i = 0, 9 do
    local func = function() change_number(i) show_seeker() end
    key_mappings[string.format("KP%d", i)] = func
    key_mappings[string.format("%d", i)] = func
end

function set_active()
    if not mp.get_property("seekable") then return end
    -- find duration of the video and set cursor position accordingly
    local duration = mp.get_property_number("duration")
    if duration ~= nil then
        for i = 1, 9 do
            if duration > time_scale[i] then
                cursor_position = i
                break
            end
        end
    end
    for key, func in pairs(key_mappings) do
        mp.add_forced_key_binding(key, "seek-to-"..key, func, {repeatable=true})
    end
    show_seeker()
    active = true
    blink_timer = mp.add_periodic_timer(1 / blink_rate, show_seeker)
end

function set_inactive()
    if not message_displayed then
        mp.osd_message("")
    end
    if active then
        for key, _ in pairs(key_mappings) do
            mp.remove_key_binding("seek-to-"..key)
        end
        blink_timer:kill()
    end
    -- Reset timestamp back to 0 when closed after entering it manually
    for i = 1, 9 do
        history[#history][i] = 0
    end
    history_position = #history  -- This resets timestamp to 0 after it was closed while history entry was selected
    message_displayed = false
    underline_forced = true
    active = false
end

function subprocess(args)
    local cmd = {
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = true
    }
    local res = mp.command_native(cmd)
    if not res.error then
        return res.stdout
    else
        msg.error("Error getting data from clipboard")
        return
    end
end

function get_clipboard()
    local res
    if platform == "windows" then
        res = subprocess({ "powershell", "-Command", "Get-Clipboard", "-Raw" })
    elseif platform == "darwin" then
        res = subprocess({ "pbpaste" })
    elseif platform == "linux" then
        if os.getenv("WAYLAND_DISPLAY") then
            res = subprocess({ "wl-paste", "-n" })
        else
            res = subprocess({ "xclip", "-selection", "clipboard", "-out" })
        end
    end
    return res
end

function paste_timestamp()
    local clipboard = get_clipboard()
    if clipboard == nil or not clipboard:find("%d[.:]") then return end
    local is_negative = clipboard:sub(1, 1) == "-"
    local clipboard = clipboard:gsub("[\r\n]", "")

    -- Support for dot separated timestamps
    if clipboard:match("%d+%.%d+%.%d+%.?%d*") then
        local segment_count = select(2, clipboard:gsub("%.", "")) + 1
        if segment_count == 4 then
            clipboard = clipboard:gsub("(%d+)%.(%d+)%.(%d+)%.", "%1:%2:%3.")
        elseif segment_count == 3 then
            clipboard = clipboard:match("%.(%d%d%d)$") and
                        clipboard:gsub("(%d+)%.(%d+)%.", "%1:%2.") or
                        clipboard:gsub("(%d+)%.(%d+)%.(%d+)", "%1:%2:%3")
        end
    end

    local hours, minutes, seconds, milliseconds = clipboard:match("(%d+):(%d+):(%d+)%.?(%d*)")
    if not hours then
        minutes, seconds, milliseconds = clipboard:match("(%d+):(%d+)%.?(%d*)")
        if not minutes then
            seconds, milliseconds = clipboard:match("(%d+)%.?(%d*)")
            minutes = 0
        end
        hours = 0
    end

    if seconds then
        local total_seconds = tonumber(seconds)
        minutes = minutes + math.floor(total_seconds / 60)  -- Convert available seconds to minutes
        seconds = total_seconds % 60
    end
    
    if minutes then
        local total_minutes = tonumber(minutes)
        hours   = hours + math.floor(total_minutes / 60)  -- Convert available minutes to hours
        minutes = total_minutes % 60
    end

    if hours and minutes and seconds then
        milliseconds = milliseconds and (milliseconds .. string.rep("0", 3 - #milliseconds)):sub(1, 3) or 0

        local timestamp = string.format("%s%02d:%02d:%02d.%03d", is_negative and "-" or "", hours, minutes, seconds, milliseconds)   -- Format timestamp HH:MM:SS:sss
        local timestamp_time = hours * 3600 + minutes * 60 + seconds + milliseconds / 1000   -- Total time in seconds
        local duration = mp.get_property_native("duration")
        -- If the total time is greater than the duration, return without seeking
        if timestamp_time > duration then
            set_inactive()
            mp.osd_message("The timestamp is longer than the duration of the video")
            mp.msg.warn("The timestamp is longer than the duration of the video")
            return
        end

        -- Split the formatted timestamp into individual digits
        local timestamp_digits = {timestamp:match("(%d)(%d):(%d)(%d):(%d)(%d)%.(%d)(%d)(%d)")}
        -- Add the pasted timestamp to the history table
        for i = 1, 9 do
            history[#history][i] = tonumber(timestamp_digits[i])
        end
        -- Add a new entry if the current timestamp is different from the last one in the history
        if #history == 1 or not time_equal(history[history_position], history[#history - 1]) then
            history[#history + 1] = {}
            history_position = #history
        end

        set_inactive()
        mp.osd_message("Seeking to: " .. timestamp)
        mp.commandv("osd-bar", "seek", timestamp, "absolute")

    else
        set_inactive()
        mp.osd_message("No pastable timestamp found!")
        msg.warn("No pastable timestamp found!")
    end
end

mp.add_key_binding(nil, "toggle-seeker", function() if active then set_inactive() else set_active() end end)
mp.add_key_binding(nil, "paste-timestamp", paste_timestamp)