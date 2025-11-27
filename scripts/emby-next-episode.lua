local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local options = require "mp.options"

-- 配置选项
local opts = {
    ua_string = "Hills Windows/0.2.7 (windows; 22621.ni_release.220506-1250)",
    timeout = 10,               -- 单次请求超时时间
    device_name = "MPV-PC",     -- 自定义设备名称
    retry_delay = 30,           -- 请求失败后等待秒数
    max_retries = 3             -- 最大重试次数
}
options.read_options(opts, "emby-next-episode")

--- 参考代码https://github.com/CogentRedTester/mpv-file-browser/blob/d65bb3fb85e021c4f0f9282e8b1d6921c04189df/modules/playlist.lua#L36
--- 获取loadfile命令中options参数的正确位置
local function get_loadfile_options_arg_index()
    local command_list = mp.get_property_native('command-list', {})
    for _, command in ipairs(command_list) do
        if command.name == 'loadfile' then
            for i, arg in ipairs(command.args or {}) do
                if arg.name == 'options' then return i end
            end
        end
    end
    return 3
end

local LEGACY_LOADFILE_SYNTAX = get_loadfile_options_arg_index() == 3

--- 封装loadfile
local function legacy_loadfile_wrapper(file, flag, options)
    if LEGACY_LOADFILE_SYNTAX then
        return mp.command_native({"loadfile", file, flag, options}) ~= nil
    else
        return mp.command_native({"loadfile", file, flag, -1, options}) ~= nil
    end
end

-- URL 解码
local function url_decode(str)
    str = string.gsub(str, "+", " ")
    str = string.gsub(str, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return str
end

-- 提取URL参数
local function extract_params(url)
    local params = {}
    local query = url:match("%?(.+)")
    if query then
        for key, value in query:gmatch("([^&=]+)=([^&=]*)") do
            params[key] = url_decode(value)
        end
    end
    return params
end

-- 提取服务器地址
local function get_server_base_url(url)
    local s = url:find("/Videos/") or url:find("/Items/") or url:find("/videos/")
    if s then return url:sub(1, s - 1) end
    return url:match("^(https?://[^/?#]+)")
end

-- 解析连接参数
local function get_connection_params(path)
    local params = extract_params(path)
    local server = get_server_base_url(path)
    if not server then return nil end
    
    local current_id = params.MediaSourceId
    if not current_id then
        current_id = path:match("/videos/(%d+)/") or path:match("/Videos/(%d+)/")
    end
    if current_id and current_id:match("^mediasource_") then
        current_id = current_id:match("^mediasource_(%d+)")
    end
    
    if not current_id or not params.DeviceId or not params.api_key then return nil end
    
    return {
        server = server,
        current_id = current_id,
        device_id = params.DeviceId,
        api_key = params.api_key,
        play_session_id = params.PlaySessionId or "",
        original_params = params
    }
end

-- 核心异步请求函数
-- callback(json_result) -> 如果成功，json_result 为表；如果最终失败，json_result 为 nil
local function request_async_with_retry(url, api_key, device_id, client_info, post_data, callback, retry_count)
    retry_count = retry_count or 0

    -- 构建 HTTP 头
    local emby_auth = string.format(
        'Emby Client="%s", Device="%s", DeviceId="%s", Version="%s"',
        client_info.client or "Hills Windows",
        client_info.device_name or opts.device_name,
        device_id,
        client_info.version or "0.2.7"
    )
    
    local args = {
        "curl", "-s", "-L", url,
        "-H", "User-Agent: " .. opts.ua_string,
        "-H", "X-Emby-Token: " .. api_key,
        "-H", "X-Emby-Authorization: " .. emby_auth,
        "-H", "X-Emby-Client: " .. (client_info.client or "Hills Windows"),
        "-H", "X-Emby-Device-Name: " .. (client_info.device_name or opts.device_name),
        "-H", "X-Emby-Device-Id: " .. device_id,
        "-H", "X-Emby-Client-Version: " .. (client_info.version or "0.2.7"),
        "-H", "X-Emby-Language: zh-cn",
        "--connect-timeout", tostring(opts.timeout),
        "--max-time", tostring(opts.timeout),
        "--ssl-revoke-best-effort"
    }

    if post_data then
        table.insert(args, "-X")
        table.insert(args, "POST")
        table.insert(args, "-H")
        table.insert(args, "Content-Type: application/json")
        table.insert(args, "-d")
        table.insert(args, post_data)
    end

    msg.debug("[NextUp] Requesting: " .. url)

    -- 执行请求 (curl 本身执行是同步的，会短暂阻塞子进程，但不影响 timeout 逻辑)
    local res = mp.command_native({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    })

    local success = false
    local json_res = nil

    if res and res.status == 0 and res.stdout and res.stdout ~= "" then
        json_res = utils.parse_json(res.stdout)
        if json_res then success = true end
    end

    if success then
        -- 成功：直接回调
        if callback then callback(json_res) end
    else
        -- 失败：检查重试次数
        if retry_count < opts.max_retries then
            msg.debug(string.format("[NextUp] 请求失败，%d秒后重试 (%d/%d)...", opts.retry_delay, retry_count + 1, opts.max_retries))
            -- 关键点：使用 mp.add_timeout 进行非阻塞等待
            mp.add_timeout(opts.retry_delay, function()
                request_async_with_retry(url, api_key, device_id, client_info, post_data, callback, retry_count + 1)
            end)
        else
            msg.error("[NextUp] 最终请求失败，已放弃: " .. url)
            if callback then callback(nil) end
        end
    end
end

-- 辅助：解析标题
local function parse_title_info(json, episode_id)
    if not json then return nil end
    local title_parts = {}
    if json.SeriesName then
        local sn = json.SeriesName
        if json.ProductionYear then sn = sn .. "(" .. json.ProductionYear .. ")" end
        table.insert(title_parts, sn)
    end
    if json.ParentIndexNumber and json.IndexNumber then
        table.insert(title_parts, string.format("S%02dE%02d", json.ParentIndexNumber, json.IndexNumber))
    end
    if json.Name then table.insert(title_parts, json.Name) end
    
    local full = table.concat(title_parts, " - ")
    if full == "" then full = "Episode " .. episode_id end
    
    return { title = full }
end

-- 主逻辑
local function on_file_loaded()
    local path = mp.get_property("path", "")
    if not path:find("^http") then return end

    local conn = get_connection_params(path)
    if not conn then return end

    local client_info = { client = "Hills Windows", device_name = opts.device_name, version = "0.2.7" }

    msg.debug("[NextUp] 开始处理: " .. conn.current_id)

    -- 第一步：获取 UserId
    local url_sessions = string.format("%s/Sessions", conn.server)
    request_async_with_retry(url_sessions, conn.api_key, conn.device_id, client_info, nil, function(sessions)
        if not sessions then return end -- 失败中止
        
        local user_id = nil
        for _, s in ipairs(sessions) do
            if s.DeviceId == conn.device_id and s.UserId then user_id = s.UserId; break end
        end
        if not user_id and #sessions > 0 then user_id = sessions[1].UserId end
        
        if not user_id then 
            msg.error("[NextUp] 无法找到 UserId")
            return 
        end

        -- 第二步：获取当前集信息 & 自动设置标题
        local url_item = string.format("%s/Users/%s/Items/%s", conn.server, user_id, conn.current_id)
        request_async_with_retry(url_item, conn.api_key, conn.device_id, client_info, nil, function(current_item)
            if not current_item then return end

            -- 自动设置当前标题（如果未设置）
            local current_title_prop = mp.get_property("force-media-title")
            if not current_title_prop or current_title_prop == "" or current_title_prop == path then
                local t_info = parse_title_info(current_item, conn.current_id)
                if t_info then
                    mp.set_property("force-media-title", t_info.title)
                    mp.commandv("show-progress") 
                end
            end

            -- 检查是否需要添加下一集
            local pl_count = mp.get_property_number("playlist-count", 1)
            local pl_pos = mp.get_property_number("playlist-pos", 0)
            if pl_pos < pl_count - 1 then return end -- 已有后续，跳过
            
            if current_item.Type ~= "Episode" or not current_item.SeriesId then return end

            -- 第三步：获取下一集 ID
            local url_eps = string.format("%s/Shows/%s/Episodes?UserId=%s&Fields=Overview,Chapters,Width,Height,ProviderIds,ParentId,People,CommunityRating&EnableImageTypes=Primary,Backdrop,Thumb,Logo&ImageTypeLimit=1", conn.server, current_item.SeriesId, user_id)
            if current_item.SeasonId then url_eps = url_eps .. "&SeasonId=" .. current_item.SeasonId end

            request_async_with_retry(url_eps, conn.api_key, conn.device_id, client_info, nil, function(episodes_json)
                if not episodes_json or not episodes_json.Items then return end
                
                local next_id = nil
                for i, item in ipairs(episodes_json.Items) do
                    if item.Id == conn.current_id and i < #episodes_json.Items then
                        next_id = episodes_json.Items[i + 1].Id
                        break
                    end
                end

                if not next_id then return end -- 季终或未找到

                -- 第四步：获取下一集详细信息 (标题)
                local url_next_info = string.format("%s/Users/%s/Items/%s", conn.server, user_id, next_id)
                request_async_with_retry(url_next_info, conn.api_key, conn.device_id, client_info, nil, function(next_item_info)
                    local next_title_str = nil
                    if next_item_info then
                        local t = parse_title_info(next_item_info, next_id)
                        if t then next_title_str = t.title end
                    end

                    -- 第五步：获取播放链接
                    local url_playback = string.format("%s/Items/%s/PlaybackInfo?UserId=%s&IsPlayback=true", conn.server, next_id, user_id)
                    local post_body = [[{"DeviceProfile":{"MaxStreamingBitrate":200000000,"DirectPlayProfiles":[{"Type":"Video"},{"Type":"Audio"}],"TranscodingProfiles":[{"Type":"Video","Protocol":"hls","Context":"Streaming"}]}}]]
                    
                    request_async_with_retry(url_playback, conn.api_key, conn.device_id, client_info, post_body, function(pb_json)
                        if not pb_json or not pb_json.MediaSources or #pb_json.MediaSources == 0 then return end
                        
                        local ms = pb_json.MediaSources[1]
                        local final_url = ms.DirectStreamUrl or ms.Path
                        if not final_url then
                            final_url = string.format("%s/Videos/%s/stream?Static=true&MediaSourceId=%s", conn.server, next_id, ms.Id or "unknown")
                        end
                        if final_url:sub(1, 1) == "/" then final_url = conn.server .. final_url end

                        -- 最终：添加到播放列表
                        local options_str = nil
                        if next_title_str then
                            options_str = "force-media-title=" .. string.format("%q", next_title_str)
                        end
                        
                        legacy_loadfile_wrapper(final_url, 'append-play', options_str)
                        msg.debug("[NextUp] 已添加下一集: " .. (next_title_str or "Unknown"))
                    end, 0) -- PlaybackInfo
                end, 0) -- Next Info
            end, 0) -- Episodes List
        end, 0) -- Current Item
    end, 0) -- User ID
end

mp.register_event("file-loaded", on_file_loaded)