-- emby-playback-reporting.lua
-- MPV to Emby 播放进度回传脚本

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local opts = {
    report_interval = 10,
    ua_string = "Hills Windows/0.2.7 (windows; 22621.ni_release.220506-1250)",
}

options.read_options(opts, "emby-playback-reporting")

-- 配置参数
local report_interval = opts.report_interval
local ua_string = opts.ua_string
local emby_server = ""
local device_id = ""
local media_source_id = ""
local play_session_id = ""
local api_key = ""
local current_file_path = ""
local last_report_time = 0
local last_position = 0
local is_paused = false
local playback_started = false
local shutdown_reported = false

-- 播放列表信息
local playlist_index = 0
local playlist_length = 1
local now_playing_queue = {}

-- 从URL中提取参数
local function extract_emby_parameters(url)
    local params = {}
    local base_url = url:match("^(.-)%?") or url
    local query_string = url:match("%?(.+)")
    if query_string then
        for key, value in query_string:gmatch("([^&=]+)=([^&=]*)") do
            params[key] = value
        end
    end
    return base_url, params
end

-- 【正常播放时】异步HTTP POST请求
local function post_json_async(url, payload)
    local json_payload = utils.format_json(payload)

    mp.command_native_async({
        name = "subprocess",
        args = {
            "curl", "-X", "POST", url,
            "-H", "Content-Type: application/json",
            "-H", "X-Emby-Token: " .. api_key,
            "-H", "User-Agent: " .. ua_string,
            "-d", json_payload,
            "--max-time", "5",
            "--silent", "--show-error", "--ssl-revoke-best-effort"
        },
        capture_stdout = true,
        capture_stderr = true
    }, function(success, result, error)
        -- 这里是回调函数
        if success then
            if result.status == 0 then
                -- curl 执行成功（网络通畅）
                if result.stdout and result.stdout ~= "" then
                    msg.debug("Emby 响应: " .. result.stdout) -- 打印服务器返回的具体内容
                end
            else
                -- curl 执行失败（非0退出码，如404/500/超时等）
                msg.warn("Curl 失败 (代码 " .. result.status .. "):")
                if result.stderr then
                    msg.warn(result.stderr) -- 打印 curl 的错误详情
                end
                if result.stdout then
                    msg.warn("服务器返回: " .. result.stdout) -- 即使报错，服务器也可能返回了错误原因 JSON
                end
            end
        else
            msg.error("启动 curl 子进程失败: " .. (error or "未知错误"))
        end
    end)
end

-- 【播放结束/关闭时】分离式进程 POST 请求
local function post_json_detached(url, payload)
    local json_payload = utils.format_json(payload)
    -- 使用 detach = true，MPV 关闭不会杀死这个 curl，也不会等待它
    mp.command_native({
        name = "subprocess",
        args = {
            "curl", "-X", "POST", url,
            "-H", "Content-Type: application/json",
            "-H", "X-Emby-Token: " .. api_key,
            "-H", "User-Agent: " .. ua_string,
            "-d", json_payload,
            "--max-time", "2", -- 超时设短一点
            "--silent", "--ssl-revoke-best-effort"
        },
        detach = true,         -- 分离进程
        capture_stdout = false, -- 分离模式下不能捕获输出
        capture_stderr = false
    })
end

-- 播放开始
local function report_playback_start()
    if not emby_server or not api_key or not play_session_id then return end

    local url = emby_server .. "/Sessions/Playing"
    local payload = {
        ItemId = media_source_id:match("mediasource_(%d+)") or media_source_id,
        MediaSourceId = media_source_id,
        PlaySessionId = play_session_id,
        CanSeek = true,
        IsPaused = false,
        IsMuted = false,
        PositionTicks = 0,
        PlaybackRate = 1,
        PlaylistLength = playlist_length,
        PlaylistIndex = playlist_index,
        NowPlayingQueue = now_playing_queue,
        PlayMethod = "DirectStream",
        RepeatMode = "RepeatNone",
        PlaybackStartTimeTicks = math.floor(os.time() * 10000000)
    }
    post_json_async(url, payload)
end

-- 播放进度
local function report_playback_progress(position, paused_flag)
    if not emby_server or not api_key or not play_session_id then return end

    local url = emby_server .. "/Sessions/Playing/Progress"
    local payload = {
        ItemId = media_source_id:match("mediasource_(%d+)") or media_source_id,
        MediaSourceId = media_source_id,
        PlaySessionId = play_session_id,
        CanSeek = true,
        IsPaused = paused_flag,
        IsMuted = false,
        PositionTicks = math.floor(position * 10000000),
        PlaybackRate = 1,
        PlaylistLength = playlist_length,
        PlaylistIndex = playlist_index,
        EventName = "TimeUpdate",
        PlayMethod = "DirectStream",
        RepeatMode = "RepeatNone"
    }
    post_json_async(url, payload)
end

-- 播放停止 (核心修改)
local function report_playback_stopped()
    if shutdown_reported then return end

    if not playback_started or not emby_server or not api_key or not play_session_id then
        return
    end

    local position = mp.get_property_number("time-pos", 0)
    if position == nil then position = last_position end

    local url = emby_server .. "/Sessions/Playing/Stopped"
    local payload = {
        ItemId = media_source_id:match("mediasource_(%d+)") or "",
        MediaSourceId = media_source_id,
        PlaySessionId = play_session_id,
        CanSeek = true,
        IsPaused = false,
        IsMuted = false,
        PositionTicks = math.floor(position * 10000000),
        PlaybackRate = 1,
        PlaylistLength = playlist_length,
        PlaylistIndex = playlist_index,
        PlayMethod = "DirectStream",
        RepeatMode = "RepeatNone"
    }

    -- 使用分离式请求，无弹窗且不会被 kill
    post_json_detached(url, payload)

    shutdown_reported = true
    playback_started = false
end

-- 定时器
local function tick()
    if not playback_started or is_paused then return end
    local current_time = mp.get_time()
    local position = mp.get_property_number("time-pos", 0)

    if position and (current_time - last_report_time) >= report_interval then
        report_playback_progress(position, is_paused)
        last_report_time = current_time
        last_position = position
    end
end

-- 暂停处理
local function on_pause_change(name, value)
    is_paused = value
    if playback_started then
        local position = mp.get_property_number("time-pos", 0)
        if position then
            report_playback_progress(position, is_paused)
            last_report_time = mp.get_time()
            last_position = position
        end
    end
end

-- 文件加载
local function on_file_loaded()
    local path = mp.get_property("path", "")
    if path:find("emby") then
        current_file_path = path
        local base_url, params = extract_emby_parameters(path)
        emby_server = base_url:match("(https?://[^/]+)")
        device_id = params.DeviceId or ""
        media_source_id = params.MediaSourceId or ""
        play_session_id = params.PlaySessionId or ""
        api_key = params.api_key or ""

        now_playing_queue = {{ Id = media_source_id:match("mediasource_(%d+)") or "", PlaylistItemId = "playlistItem0" }}

        msg.info("Emby 回传初始化: " .. media_source_id)
        shutdown_reported = false

        mp.add_timeout(0.5, function()
            report_playback_start()
            playback_started = true
        end)
    else
        playback_started = false
    end
end

local function on_unload_hook()
    if playback_started then
        msg.debug("Hook触发：汇报停止")
        report_playback_stopped()
    end
end

-- 注册事件
mp.register_event("file-loaded", on_file_loaded)
mp.observe_property("pause", "bool", on_pause_change)
mp.add_periodic_timer(1, tick)

-- 使用 Hook 替代 shutdown 事件
mp.add_hook("on_unload", 50, on_unload_hook)
