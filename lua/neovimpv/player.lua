#!/usr/bin/lua
-- neovimpv/player.lua
--
-- Basic extmark functionality for creating players and playlist extmarks.
-- These provide standard ways for interacting with nvim to Python and vimscript

if neovimpv == nil then neovimpv = {} end

neovimpv.DISPLAY_NAMESPACE = vim.api.nvim_create_namespace("Neovimpv-displays")
neovimpv.PLAYLIST_NAMESPACE = vim.api.nvim_create_namespace("Neovimpv-playlists")
local DISPLAY_NAMESPACE = neovimpv.DISPLAY_NAMESPACE
local PLAYLIST_NAMESPACE = neovimpv.PLAYLIST_NAMESPACE

-- Link default highlights from names in `froms` to the highlight `to`
function neovimpv.bind_default_highlights(froms, to)
  for _, from in pairs(froms) do
    vim.cmd("highlight default link " .. from .. " " .. to)
  end
end

-- Get all player ids in the display namespace, which should correspond to Python MpvInstances
function neovimpv.get_players_in_buffer(buffer)
  local has_playlists = vim.api.nvim_buf_call(
    buffer,
    function() return vim.b["mpv_playlists_to_displays"] end
  )
  if not has_playlists then return {} end

  return vim.tbl_map(
    function(x) return x[1] end, -- extmark id only
    vim.api.nvim_buf_get_extmarks(buffer, DISPLAY_NAMESPACE, 0, -1, {})
  )
end

-- Try to get the playlist extmarks from `start` to `end` in a `buffer`.
-- Returns the id of the first player the playlist item belongs to.
function neovimpv.get_player_by_line(buffer, start, end_, no_message)
  if end_ == nil then
    end_ = start
  end

  return vim.api.nvim_buf_call(buffer, function()
    local dict = vim.b["mpv_playlists_to_displays"] or {}
    local playlist_item = vim.api.nvim_buf_get_extmarks(
      buffer,
      PLAYLIST_NAMESPACE,
      {start - 1, 0},
      {end_ - 1, -1},
      {}
    )[1] or {}
    local player = dict[tostring(playlist_item[1])]

    if #playlist_item == 0 or player == nil then
      if not no_message then
        vim.api.nvim_notify(
          "No mpv found running on that line",
          4,
          {}
        )
      end
      return {}
    end

    return {player, playlist_item[1]}
  end)
end

-- Update an extmark's content without changing its row or column
function neovimpv.update_extmark(buffer, extmark_id, content)
  local loc = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    DISPLAY_NAMESPACE,
    extmark_id,
    {}
  )
  if loc ~= nil then
    vim.api.nvim_buf_set_extmark(
      buffer,
      DISPLAY_NAMESPACE,
      loc[1],
      loc[2],
      content
    )
  end
end

-- From a list of `lines` in a `buffer`, create extmarks for a playlist
-- Set some extra data in the buffer which remembers the player corresponding
-- to a playlist. Returns the extmark ids created.
-- Also, bind an autocommand to watch for deletions in the playlist.
-- Note: `lines` is 1-indexed like line numbers in vim.
local function create_playlist(buffer, lines, contents, display_id)
  local new_ids = {}
  local extmark = {
    sign_text=contents,
    sign_hl_group="MpvPlaylistSign"
  }
  local rule = vim.g["mpv_draw_playlist_extmarks"]
  if rule == "never" or (rule == "multiple" and #lines == 1) then
    extmark = {}
  end

  vim.api.nvim_buf_call(buffer, function()
    local dict = vim.b["mpv_playlists_to_displays"]
    -- setup callback in this buffer
    if dict == nil then
      vim.b["mpv_playlists_to_displays"] = vim.empty_dict()
      vim.call("neovimpv#bind_autocmd")
    end
    -- add each playlist extmark
    for i, j in pairs(lines) do
      local extmark_id = vim.api.nvim_buf_set_extmark(
        buffer,
        PLAYLIST_NAMESPACE,
        j - 1,
        0,
        extmark
      )
      new_ids[i] = extmark_id
      vim.cmd(
        "let b:mpv_playlists_to_displays" ..
        "[" .. tostring(extmark_id) .. "] = " ..
        tostring(display_id)
      )
    end
  end)
  return new_ids
end

-- From a list of `lines` in a `buffer`, create extmarks for a player (displays
-- current playback state) and a playlist (list of lines to play next)
-- Note: lines is 1-indexed like line numbers in vim.
function neovimpv.create_player(buffer, lines, no_playlist)
  local player = vim.api.nvim_buf_set_extmark(
      buffer,
      DISPLAY_NAMESPACE,
      lines[1] - 1,
      0,
      {
          virt_text={{vim.g["mpv_loading"], "MpvDefault"}},
          virt_text_pos="eol",
      }
  )

  if no_playlist then
    return player
  end

  local playlist_ids = create_playlist(
      buffer,
      lines,
      "|",
      player
  )
  return {player, playlist_ids}
end

-- Move a player with id `display_id` to the same line as the playlist item with
-- id `playlist_id`. Also handles resetting the previous playlist extmark's virtual lines
function neovimpv.move_player(buffer, display_id, new_playlist_id, new_text)
  -- get the destination line
  local loc = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    PLAYLIST_NAMESPACE,
    new_playlist_id,
    {}
  )
  local loc_display = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    DISPLAY_NAMESPACE,
    display_id,
    {}
  )
  -- return false if no extmark exists
  if #loc == 0 or #loc_display == 0 then return false end
  -- no need to move, but no error
  if loc_display[1] == loc[1] then return true end

  local new_extmark_text = (new_text == vim.NIL or new_text == nil) and vim.g["mpv_loading"] or new_text
  -- set the player to that line
  vim.api.nvim_buf_set_extmark(
    buffer,
    DISPLAY_NAMESPACE,
    loc[1],
    0,
    {
      id=display_id,
      virt_text={{new_extmark_text, "MpvDefault"}},
      virt_text_pos=eol,
    }
  )

  local old_playlist_item = vim.api.nvim_buf_get_extmarks(
    buffer,
    PLAYLIST_NAMESPACE,
    {loc_display[1], 0},
    {loc_display[1], -1},
    { details=true }
  )[1]
  -- reset playlist extmark
  if old_playlist_item ~= nil and old_playlist_item[4].sign_text ~= nil then
    vim.api.nvim_buf_set_extmark(
      buffer,
      PLAYLIST_NAMESPACE,
      loc_display[1],
      0,
      {
        id=old_playlist_item[1],
        sign_text="|",
        sign_hl_group="MpvPlaylistSign",
        virt_lines={},
      }
    )
  end
  return true
end

-- Delete extmarks in the displays and playlists namespace. Also, clear up
-- playlist information in the buffer.
function neovimpv.remove_player(buffer, display_id)
  -- buffer already deleted
  if #vim.call("getbufinfo", buffer) == 0 then return end

  vim.api.nvim_buf_del_extmark(
    buffer,
    DISPLAY_NAMESPACE,
    display_id
  )

  vim.api.nvim_buf_call(buffer, function()
    -- get the playlist extmarks associated to this player
    local playlist_ids = {}
    for playlist, display in pairs(vim.b["mpv_playlists_to_displays"] or {}) do
      if display == display_id then
        table.insert(playlist_ids, tonumber(playlist)) 
      end
    end
    -- delete them
    for _, playlist_id in pairs(playlist_ids) do
      vim.api.nvim_buf_del_extmark(
        buffer,
        PLAYLIST_NAMESPACE,
        playlist_id
      )
      vim.cmd(
        "unlet b:mpv_playlists_to_displays" ..
        "[" .. tostring(playlist_id) .. "]"
      )
    end
  end)
end
