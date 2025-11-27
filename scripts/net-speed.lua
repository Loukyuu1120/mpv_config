-- net-speed.lua
-- 高精度网速显示

local mp = require 'mp'
local options = require 'mp.options'

-- === 配置区域 ===
local opts = {
    enable = true,
    integration_window = 2.0,
    overhead_compensation = 1.05,

    -- 自动隐藏设置
    auto_hide = true,      -- 是否开启自动隐藏
    hide_timeout = 5,      -- 速度为0持续多少秒后隐藏

    -- 过滤设置
    show_network = true,
    show_local = false,
    allow_local_prefixes = "",

    -- 外观设置
    position = "top-right",
    margin_x = 20,
    margin_y = 20,
    font_face = "Segoe UI",
    font_size = 20,
    font_bold = true,
    text_color = "FFFFFF",
    border_size = 1.2,
    border_color = "000000",
    shadow_depth = 1,
    shadow_color = "000000",
    alpha = "00",
    
    units = "auto",
    decimals = 1,
    prefix_text = "",
}

options.read_options(opts, "net-speed")

-- === 状态变量 ===
local timer = nil
local last_check_time = nil
local last_fw_bytes = 0

-- 采样队列
local samples = {} 
local is_visible = opts.enable

-- 【新增】用于记录速度为0的开始时间
local zero_speed_start_time = nil 

-- === 工具函数 ===
local function split_string(str, sep)
    local result = {}
    for match in (str..sep):gmatch("(.-)"..sep) do
        if match ~= "" then table.insert(result, match) end
    end
    return result
end

local function should_show()
    local path = mp.get_property("path", "")
    if not path then return false end

    local is_network = (path:find("^https?://") or path:find("^rtmp://") or path:find("^rtsp://") or path:find("^udp://") or path:find("emby/videos"))
    if is_network and opts.show_network then return true end

    if not is_network then
        if opts.show_local then return true end
        if opts.allow_local_prefixes ~= "" then
            local prefixes = split_string(opts.allow_local_prefixes, ";")
            local norm_path = path:gsub("\\", "/")
            for _, prefix in ipairs(prefixes) do
                local norm_prefix = prefix:gsub("\\", "/")
                if norm_path:find(norm_prefix, 1, true) == 1 then return true end
            end
        end
    end
    return false
end

local function format_speed(bps)
    bps = bps * opts.overhead_compensation
    if bps < 0 then bps = 0 end
    
    local speed_str = ""
    if opts.units == "KB" then
        speed_str = string.format("%."..opts.decimals.."f KB/s", bps/1024)
    elseif opts.units == "MB" then
        speed_str = string.format("%."..opts.decimals.."f MB/s", bps/(1024*1024))
    else
        if bps < 1024 then
            speed_str = string.format("%d B/s", bps)
        elseif bps < 1024*1024 then
            speed_str = string.format("%."..opts.decimals.."f KB/s", bps/1024)
        else
            speed_str = string.format("%."..opts.decimals.."f MB/s", bps/(1024*1024))
        end
    end
    return opts.prefix_text .. speed_str
end

local function draw_osd(text)
    -- 如果传入空文本，直接清除 OSD
    if not text or text == "" then
        mp.set_osd_ass(0, 0, "")
        return
    end

    local an = 9
    if opts.position == "top-left" then an = 7
    elseif opts.position == "top-right" then an = 9
    elseif opts.position == "bottom-left" then an = 1
    elseif opts.position == "bottom-right" then an = 3
    end
    
    local function fix_color(c) 
        if #c == 6 then return c:sub(5,6)..c:sub(3,4)..c:sub(1,2) end
        return c 
    end

    local w = mp.get_property_number("osd-width", 1920)
    local h = mp.get_property_number("osd-height", 1080)
    local x, y
    if opts.position:find("right") then x = w - opts.margin_x else x = opts.margin_x end
    if opts.position:find("bottom") then y = h - opts.margin_y else y = opts.margin_y end

    local ass = string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\b%d\\bord%f\\shad%f\\1c&H%s%s&\\3c&H%s%s&\\4c&H%s%s&}%s",
        an, x, y,
        opts.font_face, opts.font_size, opts.font_bold and 1 or 0,
        opts.border_size, opts.shadow_depth,
        opts.alpha, fix_color(opts.text_color),
        opts.alpha, fix_color(opts.border_color),
        opts.alpha, fix_color(opts.shadow_color),
        text
    )
    mp.set_osd_ass(w, h, ass)
end

local function tick()
    if not is_visible then
        mp.set_osd_ass(0, 0, "")
        return
    end

    local t_now = mp.get_time()
    local demuxer_cache = mp.get_property_native("demuxer-cache-state", {})
    local fw_bytes = demuxer_cache["fw-bytes"] or 0
    
    local delta = 0
    if last_fw_bytes then
        delta = fw_bytes - last_fw_bytes
    end
    if delta < 0 then delta = 0 end 
    
    table.insert(samples, {t = t_now, b = delta})
    last_fw_bytes = fw_bytes
    last_check_time = t_now

    local cutoff_time = t_now - opts.integration_window
    while #samples > 0 and samples[1].t < cutoff_time do
        table.remove(samples, 1)
    end

    local total_bytes = 0
    for _, sample in ipairs(samples) do
        total_bytes = total_bytes + sample.b
    end

    local effective_duration = opts.integration_window
    if #samples > 0 then
        local earliest = samples[1].t
        local duration = t_now - earliest
        if duration < opts.integration_window then
            effective_duration = math.max(duration, 0.5) 
        end
    end

    local speed = total_bytes / effective_duration
    if speed < 1 then speed = 0 end

    -- === 自动隐藏逻辑的核心修改 ===
    if speed > 0 then
        -- 有速度：重置计时器，正常显示
        zero_speed_start_time = nil
        draw_osd(format_speed(speed))
    else
        -- 速度为 0
        if not zero_speed_start_time then
            -- 刚开始变成 0，记录时间
            zero_speed_start_time = t_now
        end

        -- 计算已经持续 0 速多久了
        local idle_time = t_now - zero_speed_start_time

        if opts.auto_hide and idle_time > opts.hide_timeout then
            -- 超时了，隐藏显示
            mp.set_osd_ass(0, 0, "")
        else
            -- 还没超时，显示 0 B/s 或者 0.0 KB/s
            draw_osd(format_speed(0))
        end
    end
end

-- 状态管理
local function check_state()
    local show = should_show()
    if is_visible and show then
        if not timer or not timer:is_enabled() then
            local cache = mp.get_property_native("demuxer-cache-state", {})
            last_fw_bytes = cache["fw-bytes"] or 0
            last_check_time = mp.get_time()
            samples = {} 
            zero_speed_start_time = nil -- 初始化时重置计时
            
            if timer then timer:resume()
            else timer = mp.add_periodic_timer(0.1, tick) end
        end
    else
        if timer then timer:kill() timer = nil end
        mp.set_osd_ass(0, 0, "")
    end
end

local function toggle()
    is_visible = not is_visible
    zero_speed_start_time = nil -- 手动切换时重置计时
    local msg = is_visible and "Net Speed: ON" or "Net Speed: OFF"
    mp.osd_message(msg)
    check_state()
end

mp.observe_property("current-demuxer", "string", check_state)
mp.observe_property("demuxer-cache-duration", "number", function(_, val)
    if val and val > 0 then check_state() end
end)
mp.add_key_binding(nil, "toggle", toggle)
mp.add_key_binding("Ctrl+n", "toggle-default", toggle)