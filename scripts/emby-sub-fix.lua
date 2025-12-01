local utils = require 'mp.utils'
local msg = mp.msg

local is_processing = false
local initial_selection_done = false -- 标记：是否已完成初始选轨

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

-- 独立出来的选轨逻辑函数
local function select_best_subtitle()
    local tracks = mp.get_property_native("track-list")
    local current_sid = mp.get_property_number("sid") or -1
    
    local first_sid = nil       -- 保底：第一个字幕
    local priority_sid = nil    -- 最终选定的 ID
    local current_prio = 99     -- 优先级：1=简中, 2=繁中, 99=未匹配

    for _, track in ipairs(tracks) do
        if track.type == "sub" then
            -- 记录第一个遇到的字幕作为保底
            if not first_sid then
                first_sid = track.id
            end

            -- 组合语言代码和标题进行匹配 (增加准确性，Emby 常在 title 里写语言)
            local lang = (track.lang or ""):lower()
            local title = (track.title or ""):lower()
            local full_info = lang .. " " .. title

            -- 匹配规则：zh-hans, zh-cn, chi, chs, sc (title中常见)
            if full_info:find("zh%-hans") or full_info:find("zh%-cn") or 
               full_info:find("chi") or full_info:find("chs") or 
               title:find("simplified") then
                priority_sid = track.id
                current_prio = 1
                break -- 找到最高优先级，直接结束循环
            end

            -- 只有当还没找到简体中文时才记录
            if current_prio > 1 then
                -- 匹配规则：zh-hant, zh-tw, cht, tc (title中常见)
                if full_info:find("zh%-hant") or full_info:find("zh%-tw") or 
                   full_info:find("cht") or title:find("traditional") then
                    if current_prio > 2 then 
                        priority_sid = track.id
                        current_prio = 2
                    end
                end
            end
        end
    end

    -- 决策：有优先的用优先的，没有就用第一个
    local final_sid = priority_sid or first_sid

    if final_sid then
        -- 只有当目标 ID 与当前不同时才切换，避免刷新闪烁
        if final_sid ~= current_sid then
            msg.warn(">>> 自动选轨: ID " .. final_sid .. " (优先级: " .. (current_prio == 1 and "简体" or (current_prio == 2 and "繁体" or "默认")) .. ")")
            mp.set_property("sid", final_sid)
        else
            msg.verbose("当前已是最佳字幕轨道，无需切换。")
        end
    end
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

    for _, track in ipairs(sub_tracks) do
        if track.type == "sub" and track.external then
            local sub_url = track["external-filename"] or track.src
            if sub_url then
                local new_url, needs_fix = fix_subtitle_url(sub_url, vid_itemId, vid_msId)
                if needs_fix then
                    msg.verbose("修正并替换字幕轨道: " .. track.id)
                    mp.commandv("sub_remove", track.id)
                    mp.commandv("sub_add", new_url) 
                    has_changes = true
                end
            end
        end
    end

    if has_changes or not initial_selection_done then
        local delay = has_changes and 0.1 or 0.05 -- 如果有修改，多等一会等列表刷新
        
        mp.add_timeout(delay, function()
            select_best_subtitle()
            initial_selection_done = true -- 标记已完成，防止后续手动切换字幕被脚本覆盖
            is_processing = false
        end)
    else
        is_processing = false
    end
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

-- 每次新文件加载，重置状态
mp.register_event("file-loaded", function()
    initial_selection_done = false -- 重置标记
    mp.add_timeout(0, reload_subtitles)
end)

mp.observe_property("track-list", "native", function(_, tracks)
    if tracks and #tracks > 0 then
        on_tracks_changed()
    end
end)