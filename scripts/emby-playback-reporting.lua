-- emby-playback-reporting.lua
-- MPV to Emby 播放进度回传脚本（支持自定义 User-Agent）

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

-- 播放列表信息（目前只支持单文件播放）
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

-- 异步HTTP POST请求（用于正常播放时）
local function post_json_async(url, payload)
    local json_payload = utils.format_json(payload)
    msg.debug("异步POST " .. url .. " payload: " .. json_payload)
    
    mp.command_native_async({
        name = "subprocess",
        args = {
            "curl", "-X", "POST", url,
            "-H", "Content-Type: application/json",
            "-H", "X-Emby-Token: " .. api_key,
            "-H", "User-Agent: " .. ua_string,
            "-d", json_payload,
            "--max-time", "5",
            "--silent", "--show-error","--ssl-revoke-best-effort"
        },
        capture_stdout = true,
        capture_stderr = true
    }, function(success, result, error)
        if success and result.status == 0 then
            msg.debug("异步请求成功")
        else
            msg.debug("异步请求失败: " .. (result.stderr or error or "未知错误"))
        end
    end)
end

-- 播放开始
local function report_playback_start()
    if not emby_server or not api_key or not play_session_id then 
        msg.debug("缺少必要参数，跳过播放开始报告")
        return 
    end

    local url = emby_server .. "/Sessions/Playing"

    local payload = {
        ItemId = media_source_id:match("mediasource_(%d+)") or "",
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

-- 播放进度（播放中/暂停/跳转）
local function report_playback_progress(position, paused_flag)
    if not emby_server or not api_key or not play_session_id then return end

    local url = emby_server .. "/Sessions/Playing/Progress"

    local payload = {
        ItemId = media_source_id:match("mediasource_(%d+)") or "",
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

-- 播放停止（异步版本，用于播放结束或MPV关闭）
local function report_playback_stopped()
    if shutdown_reported then
        msg.debug("已经报告过关闭，跳过重复报告")
        return
    end
    
    if not playback_started or not emby_server or not api_key or not play_session_id then 
        msg.debug("播放未开始或缺少必要参数，跳过停止报告")
        return 
    end

    local position = mp.get_property_number("time-pos", 0)
    if position == nil then
        position = last_position
    end

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

    msg.debug("异步报告播放停止，位置: " .. position .. "秒")
    post_json_async(url, payload)
    shutdown_reported = true
    playback_started = false
end

-- 定期回传播放进度
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

-- 暂停/恢复
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

-- 文件加载初始化
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

        -- 构建播放列表
        now_playing_queue = {
            {
                Id = media_source_id:match("mediasource_(%d+)") or "",
                PlaylistItemId = "playlistItem0"
            }
        }

        msg.info("检测到Emby流媒体，初始化回传功能")
        msg.debug(string.format("服务器: %s, 媒体源: %s, 会话: %s", 
                                emby_server, media_source_id, play_session_id))

        -- 重置关闭状态
        shutdown_reported = false
        
        mp.add_timeout(0.5, function()
            report_playback_start()
            playback_started = true
        end)
    else
        msg.debug("非Emby流媒体，跳过回传功能")
        playback_started = false
    end
end

-- 文件结束（播放完成）
local function on_file_ended()
    msg.debug("文件播放结束")
    report_playback_stopped()
end

-- 播放结束
local function on_shutdown()
    msg.debug("MPV关闭，异步报告播放停止")
    report_playback_stopped()
end

-- 注册事件和定时器
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", on_file_ended)
mp.register_event("shutdown", on_shutdown)
mp.observe_property("pause", "bool", on_pause_change)
mp.add_periodic_timer(1, tick)