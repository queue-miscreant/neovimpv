-- neovimpv/player.lua
--
-- Basic extmark functionality for creating players and playlist extmarks.
-- These provide standard ways for interacting with nvim to Python and vimscript

local consts = require "neovimpv.consts"
local formatting = require "neovimpv.formatting"
local bind_forward_deletions = require "neovimpv.forward_deletions"
local config = require "neovimpv.config"

local DISPLAY_NAMESPACE = consts.display_namespace
local PLAYLIST_NAMESPACE = consts.playlist_namespace

local player = {}

---@class extmark_args
---@field id integer
---@field virt_text? virt_text
---@field virt_text_pos string

---Get all extmark ids of all players in the display namespace, which should correspond to Python MpvInstances
---
---@param buffer integer
---@return integer[]
function player.get_players_in_buffer(buffer)
  local has_playlists = vim.api.nvim_buf_call(
    buffer,
    function() return vim.b.mpv_playlists_to_displays end
  )
  if not has_playlists then return {} end

  return vim.tbl_map(
    function(x) return x[1] end, -- extmark id only
    vim.api.nvim_buf_get_extmarks(buffer, DISPLAY_NAMESPACE, 0, -1, {})
  )
end

---Try to get the playlist extmarks from `start` to `end` in a `buffer`.
---
---@param buffer integer
---@param start integer
---@param end_ integer
---@param no_message? boolean
---@return [integer, integer]|[] A 2-tuple of the player ID and the playlist ID.
function player.get_player_by_line(buffer, start, end_, no_message)
  if end_ == nil then
    end_ = start
  end

  return vim.api.nvim_buf_call(buffer, function()
    local dict = vim.b.mpv_playlists_to_displays or {}
    local playlist_item = vim.api.nvim_buf_get_extmarks(
      buffer,
      PLAYLIST_NAMESPACE,
      {start - 1, 0},
      {end_ - 1, -1},
      {}
    )[1] or {}
    local player_ = dict[tostring(playlist_item[1])]

    if #playlist_item == 0 or player_ == nil then
      if not no_message then
        vim.api.nvim_notify(
          "No mpv found running on that line",
          4,
          {}
        )
      end
      return {}
    end

    return {player_, playlist_item[1]}
  end)
end

---Update an extmark's content without changing its row or column
---
---@param buffer integer
---@param extmark_id integer
---@param content extmark_args
local function update_extmark(buffer, extmark_id, content)
  local loc = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    DISPLAY_NAMESPACE,
    extmark_id,
    {}
  )

  if loc ~= nil and #loc == 2 then
    vim.api.nvim_buf_set_extmark(
      buffer,
      DISPLAY_NAMESPACE,
      loc[1],
      loc[2],
      content
    )
  end
end

---Push an update from an mpv property table
---
---@param buffer integer
---@param extmark_id integer
---@param data {[string]: any}
---@param force_text? string
function player.update_extmark(buffer, extmark_id, data, force_text)
  local display = {
    id = extmark_id,
    virt_text_pos = "eol",
  } --[[@as extmark_args]]

  local video = data["video-format"] ~= vim.NIL
  if force_text ~= vim.NIL then
    display.virt_text = {{force_text, "MpvDefault"}} --[[@as virt_text]]
  elseif video then
    display.virt_text = {{"[ Window ]", "MpvDefault"}} --[[@as virt_text]]
  else
    display.virt_text = formatting.render(data)
  end

  if display.virt_text == nil or display.virt_text == "" then
    display.virt_text = {{config.loading, "MpvDefault"}} --[[@as virt_text]]
  end

  update_extmark(buffer, extmark_id, display)
end

---From a list of `lines` in a `buffer`, create extmarks for a playlist
---Also sets some extra data in the buffer which remembers the player corresponding
---to a playlist. Returns the extmark ids created.
---Also, bind an autocommand to watch for deletions in the playlist.
---
---@param buffer integer
---@param lines integer[] A list of line numbers (1-indexed) to add to the playlist
---@param contents (string | nil) String to use in the sign column
---@param display_id integer
---@return integer[]
local function create_playlist(buffer, lines, contents, display_id)
  local new_ids = {}
  local extmark = {
    sign_text = contents,
    sign_hl_group = "MpvPlaylistSign"
  }
  local rule = config.draw_playlist_extmarks
  if rule == "never" or (rule == "multiple" and #lines == 1) then
    extmark = {}
  end

  vim.api.nvim_buf_call(buffer, function()
    local dict = vim.b.mpv_playlists_to_displays
    -- setup callback in this buffer
    if dict == nil then
      vim.b.mpv_playlists_to_displays = vim.empty_dict()
      bind_forward_deletions()
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

---From a list of `lines` in a `buffer`, create extmarks for a player (which displays
---current playback state) and a playlist (which is a list of lines to play next).
---
---@param buffer integer
---@param lines integer[] A list of line numbers (1-indexed) to add to the playlist
---@param no_playlist? boolean Whether to create a new playlist.
---Only used internally by playlist movement.
---@return [integer, integer[]] | integer
function player.create_player(buffer, lines, no_playlist)
  local player_ = vim.api.nvim_buf_set_extmark(
      buffer,
      DISPLAY_NAMESPACE,
      lines[1] - 1,
      0,
      {
          virt_text = {{config.loading, "MpvDefault"}},
          virt_text_pos = "eol",
      }
  )

  if no_playlist then
    return player_
  end

  local playlist_ids = create_playlist(
      buffer,
      lines,
      "|",
      player_
  )
  return {player_, playlist_ids}
end

---Move a player with id `display_id` to the same line as the playlist item with ID `playlist_id`.
---Also handles resetting the previous playlist extmark's virtual lines
---
---@param buffer integer
---@param display_id integer The ID of the player to move.
---@param new_playlist_id integer The playlist ID to which the player should be moved.
---@param new_text? string Text to set on the player.
---@return boolean
function player.move_player(buffer, display_id, new_playlist_id, new_text)
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

  local new_extmark_text = (new_text == vim.NIL or new_text == nil) and config.loading or new_text
  -- set the player to that line
  vim.api.nvim_buf_set_extmark(
    buffer,
    DISPLAY_NAMESPACE,
    loc[1],
    0,
    {
      id = display_id,
      virt_text = {{new_extmark_text, "MpvDefault"}},
      virt_text_pos = "eol",
    }
  )

  local old_playlist_item = vim.api.nvim_buf_get_extmarks(
    buffer,
    PLAYLIST_NAMESPACE,
    {loc_display[1], 0},
    {loc_display[1], -1},
    { details = true }
  )[1]
  -- reset playlist extmark
  if old_playlist_item ~= nil and old_playlist_item[4].sign_text ~= nil then
    vim.api.nvim_buf_set_extmark(
      buffer,
      PLAYLIST_NAMESPACE,
      loc_display[1],
      0,
      {
        id = old_playlist_item[1],
        sign_text = "|",
        sign_hl_group = "MpvPlaylistSign",
        virt_lines = {},
      }
    )
  end
  return true
end

---Delete extmarks in the displays and playlists namespace.
---Also clears up playlist information in the buffer.
---
---@param buffer integer
---@param display_id integer The ID of the player which should be deleted
function player.remove_player(buffer, display_id)
  -- buffer already deleted
  if #vim.fn.getbufinfo(buffer) == 0 then return end

  vim.api.nvim_buf_del_extmark(
    buffer,
    DISPLAY_NAMESPACE,
    display_id
  )

  vim.api.nvim_buf_call(buffer, function()
    -- get the playlist extmarks associated to this player
    local playlist_ids = {}
    for playlist, display in pairs(vim.b.mpv_playlists_to_displays or {}) do
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

return player
