local utils = require 'mp.utils'
local msg = mp.msg

local is_processing = false

-- 辅助函数：提取 ID
local function extract_ids_from_video_path(path)
    if not path then return nil, nil end
    local lower_path = path:lower()
    local itemId = lower_path:match("/videos/([^/]+)")
    if not itemId then return nil, nil end
    local mediasourceId = nil
    mediasourceId = lower_path:match("[?&]mediasourceid=([^&]+)")
    if not mediasourceId then
        mediasourceId = lower_path:match("/mediasources/([^/]+)")
    end
    if not mediasourceId then
        local pattern = "/videos/" .. itemId:gsub("%-", "%%-") .. "/([^/]+)"
        local potential_id = lower_path:match(pattern)
        if potential_id and potential_id:find("mediasource_") then
            mediasourceId = potential_id
        end
    end
    if not mediasourceId then
        mediasourceId = "mediasource_" .. itemId
    end
    if mediasourceId:find("?") then
        mediasourceId = mediasourceId:match("([^?]+)")
    end
    return itemId, mediasourceId
end

-- 修正字幕 URL
local function fix_subtitle_url(sub_url, target_itemId, target_msId)
    if not sub_url then return sub_url, false end
    local check_pattern = "/videos/" .. target_itemId:lower() .. "/" .. target_msId:lower()
    if sub_url:lower():find(check_pattern) then
        return sub_url, false
    end

    local new_segment = "%1" .. target_itemId .. "/" .. target_msId .. "%2"
    local new_sub_url, count = sub_url:gsub("(/Videos/)[^/]+/[^/]+(/Subtitles/)", new_segment)

    if count == 0 then
        new_sub_url = sub_url:gsub("mediasourceid=[^&]+", "mediasourceid=" .. target_msId:gsub("mediasource_", ""))
        local old_itemId = sub_url:lower():match("/videos/([^/]+)")
        if old_itemId and old_itemId ~= target_itemId then
             new_sub_url = new_sub_url:gsub("/Videos/" .. old_itemId, "/Videos/" .. target_itemId)
        end
    end

    if new_sub_url ~= sub_url then
        return new_sub_url, true
    end
    return sub_url, false
end

local function reload_subtitles()
    if is_processing then return end
    is_processing = true
    
    local path = mp.get_property("path")
    if not path or not path:find("/emby") then 
        is_processing = false
        return 
    end
    
    local vid_itemId, vid_msId = extract_ids_from_video_path(path)
    if not vid_itemId then
        is_processing = false
        return
    end

    local sub_tracks = mp.get_property_native("track-list")
    local has_changes = false
    
    -- 执行批量替换
    -- 注意：这里 sub_add 不传 "select"，防止处理过程中画面乱跳
    for _, track in ipairs(sub_tracks) do
        if track.type == "sub" and track.external then
            local sub_url = track["external-filename"] or track.src
            if sub_url then
                local new_url, needs_fix = fix_subtitle_url(sub_url, vid_itemId, vid_msId)
                if needs_fix then
                    msg.verbose("修正并替换字幕轨道: " .. track.id)
                    mp.commandv("sub_remove", track.id)
                    mp.commandv("sub_add", new_url) -- 仅添加，暂不选中
                    has_changes = true
                end
            end
        end
    end

    -- 如果没有改动，直接退出，保持当前选中状态不变
    if not has_changes then
        is_processing = false
        return
    end

    -- 强制选中第一个字幕
    -- 稍微延迟一点点，确保 sub_add 指令已被 MPV 消化，列表已更新
    mp.add_timeout(0.1, function()
        local new_tracks = mp.get_property_native("track-list")
        local first_sub_id = nil
        
        -- 寻找列表中的第一个字幕轨道 (ID最小的或者列表顺序最前的)
        for _, track in ipairs(new_tracks) do
            if track.type == "sub" then
                first_sub_id = track.id
                break -- 找到第一个就停止
            end
        end

        if first_sub_id then
            msg.warn(">>> EMBY 字幕修正完成，强制选中第一个字幕 ID: " .. first_sub_id)
            mp.set_property("sid", first_sub_id)
        end
        
        is_processing = false
    end)
end

-- 防抖
local timer = nil
local function on_tracks_changed()
    if timer then timer:kill() end
    timer = mp.add_timeout(0.1, function()
        reload_subtitles()
        timer = nil
    end)
end

mp.register_event("file-loaded", function()
    mp.add_timeout(0, reload_subtitles)
end)

mp.observe_property("track-list", "native", function(_, tracks)
    if tracks and #tracks > 0 then
        on_tracks_changed()
    end
end)