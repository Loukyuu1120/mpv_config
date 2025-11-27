-- net-speed.lua
-- 高精度：0.1s 高频采样 + 滑动时间窗积分 + 协议开销补偿

local mp = require 'mp'
local options = require 'mp.options'

-- === 配置区域 ===
local opts = {
    enable = true,
    integration_window = 2.0,
    overhead_compensation = 1.05,

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

-- 采样队列：存储 {time, bytes}
local samples = {} 
local is_visible = opts.enable

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
    -- 应用开销补偿
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
    
    -- 1. 计算本次微小间隔内的增量
    local delta = 0
    if last_fw_bytes then
        delta = fw_bytes - last_fw_bytes
    end
    
    -- 处理 Seek 或重置的情况 (delta 异常大或为负)
    if delta < 0 then delta = 0 end 
    
    -- 2. 存入采样队列 {时间戳, 字节增量}
    table.insert(samples, {t = t_now, b = delta})
    last_fw_bytes = fw_bytes
    last_check_time = t_now

    -- 3. 清理过期的采样 (超出 integration_window 的)
    local cutoff_time = t_now - opts.integration_window
    -- 从头开始移除，直到列表头的每一个都在窗口内
    while #samples > 0 and samples[1].t < cutoff_time do
        table.remove(samples, 1)
    end

    -- 4. 积分求和
    local total_bytes = 0
    for _, sample in ipairs(samples) do
        total_bytes = total_bytes + sample.b
    end

    -- 5. 计算有效时长
    -- 如果样本不足(刚开始)，用实际时长；如果样本满了，就是窗口时长
    local effective_duration = opts.integration_window
    if #samples > 0 then
        local earliest = samples[1].t
        local duration = t_now - earliest
        -- 防止除零，并平滑启动阶段
        if duration < opts.integration_window then
            -- 启动阶段，为了防止数字跳太大，我们假设时间至少有0.5秒
            effective_duration = math.max(duration, 0.5) 
        end
    end

    local speed = total_bytes / effective_duration
    
    -- 极小值过滤
    if speed < 1 then speed = 0 end

    draw_osd(format_speed(speed))
end

-- 状态管理
local function check_state()
    local show = should_show()
    if is_visible and show then
        if not timer or not timer:is_enabled() then
            -- 初始化
            local cache = mp.get_property_native("demuxer-cache-state", {})
            last_fw_bytes = cache["fw-bytes"] or 0
            last_check_time = mp.get_time()
            samples = {} -- 重置采样队列
            
            -- 【关键】采样频率：0.1秒
            -- 刷新频率必须很高，才能捕捉到瞬间的流量变化
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