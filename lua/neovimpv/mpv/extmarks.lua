-- mpv/extmarks.lua
-- Buffer-related functionality mostly decoupled from the mpv instance

local config = require "neovimpv.config"
local helpers = require "neovimpv.helpers"

local list_contains = vim.list_contains
local list_slice = vim.list_slice
local tbl_map = vim.tbl_map

local DISPLAY_NAMESPACE = helpers.display_namespace
local PLAYLIST_NAMESPACE = helpers.playlist_namespace

---From a list of `lines` in a buffer, create extmarks for a playlist
---Also sets some extra data in the buffer which remembers the player corresponding
---to a playlist. Returns the extmark ids created.
---Also, bind an autocommand to watch for deletions in the playlist.
---@param buffer_id integer
---@param lines integer[] A list of line numbers (1-indexed) to add to the playlist
---@param contents string? String to use in the sign column
---@return integer[]
local function create_playlist(buffer_id, lines, contents)
  local extmark_ids = {}
  local extmark = {
    sign_text = contents,
    sign_hl_group = "MpvPlaylistSign",
  }
  local rule = config.draw_playlist_extmarks
  if rule == "never" or (rule == "multiple" and #lines == 1) then
    extmark = {}
  end

  -- add each playlist extmark
  for i, j in pairs(lines) do
    local extmark_id = vim.api.nvim_buf_set_extmark(
      buffer_id,
      PLAYLIST_NAMESPACE,
      j - 1,
      1,
      extmark
    )
    extmark_ids[i] = extmark_id
  end
  return extmark_ids
end

---@class MpvExtmarks
---@field buffer_id integer Buffer in which the extmarks controlled by this table live.
---@field player_id integer Extmark ID of the player.
---@field playlist_ids integer[] Playlist extmarks which have been created by the player
local MpvExtmarks = {}
MpvExtmarks.__index = MpvExtmarks

---From a list of `lines` in a buffer, create extmarks for a player (which displays
---current playback state) and a playlist (which is a list of lines to play next).
---@param buffer_id integer
---@param lines integer[] A list of line numbers (1-indexed) to add to the playlist.
---@return MpvExtmarks
function MpvExtmarks.new(buffer_id, lines)
  local player_id = vim.api.nvim_buf_set_extmark(
    buffer_id,
    DISPLAY_NAMESPACE,
    lines[1] - 1,
    0,
    {
      virt_text = {{config.loading, "MpvDefault"}},
      virt_text_pos = "eol",
    }
  )

  local ret = {
    buffer_id = buffer_id,
    player_id = player_id,
    playlist_ids = create_playlist(buffer_id, lines, "|")
  }
  setmetatable(ret, MpvExtmarks)

  return ret
end

---Push an update from an mpv property table
---@param virt_text VirtText?
function MpvExtmarks:update(virt_text)
  if virt_text == nil then
    virt_text = {{config.loading, "MpvDefault"}}
  end

  local loc = vim.api.nvim_buf_get_extmark_by_id(
    self.buffer_id,
    DISPLAY_NAMESPACE,
    self.player_id,
    {}
  )

  if loc ~= nil and #loc == 2 then
    vim.api.nvim_buf_set_extmark(
      self.buffer_id,
      DISPLAY_NAMESPACE,
      loc[1],
      loc[2],
      {
        id = self.player_id,
        virt_text_pos = "eol",
        virt_text = virt_text,
      }
    )
  end
end

---Move a player with id `display_id` to the same line as the playlist item with ID `playlist_id`.
---Also handles resetting the previous playlist extmark's virtual lines
---@param new_playlist_id integer The playlist ID to which the player should be moved.
---@param new_text? string Text to set on the player.
---@return boolean success
function MpvExtmarks:move(new_playlist_id, new_text)
  -- get the destination line
  local loc = vim.api.nvim_buf_get_extmark_by_id(
    self.buffer_id,
    PLAYLIST_NAMESPACE,
    new_playlist_id,
    {}
  )
  local loc_display = vim.api.nvim_buf_get_extmark_by_id(
    self.buffer_id,
    DISPLAY_NAMESPACE,
    self.player_id,
    {}
  )
  -- return false if no extmark exists
  if #loc == 0 or #loc_display == 0 then return false end
  -- no need to move, but no error
  if loc_display[1] == loc[1] then return true end

  local new_extmark_text = new_text or config.loading
  -- set the player to that line
  vim.api.nvim_buf_set_extmark(
    self.buffer_id,
    DISPLAY_NAMESPACE,
    loc[1],
    0,
    {
      id = self.player_id,
      virt_text = {{new_extmark_text, "MpvDefault"}},
      virt_text_pos = "eol",
    }
  )

  local old_playlist_item = vim.api.nvim_buf_get_extmarks(
    self.buffer_id,
    PLAYLIST_NAMESPACE,
    {loc_display[1], 0},
    {loc_display[1], -1},
    { details = true }
  )[1]
  -- reset playlist extmark
  if old_playlist_item ~= nil and old_playlist_item[4].sign_text ~= nil then
    vim.api.nvim_buf_set_extmark(
      self.buffer_id,
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

---Update a playlist extmark to also show the currently playing item
---@param playlist_id integer
---@param virt_text string
function MpvExtmarks:show_currently_playing(playlist_id, virt_text)
  if not list_contains(self.playlist_ids, playlist_id) then return end

  local loc = vim.api.nvim_buf_get_extmark_by_id(
    self.buffer_id,
    PLAYLIST_NAMESPACE,
    playlist_id,
    {}
  )
  if loc ~= nil then
    vim.api.nvim_buf_set_extmark(
      self.buffer_id,
      PLAYLIST_NAMESPACE,
      loc[1],
      loc[2],
      {
        id = playlist_id,
        virt_lines = {{
          {"Currently playing: ", "MpvDefault"},
          {virt_text, "MpvTitle"},
        }} --[[@as VirtText[] ]],
        sign_text = "|",
        sign_hl_group = "MpvPlaylistSign"
      }
    )
  end
end

---Paste new line data "on top" of a playlist item.
---@param playlist_id integer Playlist ID of item to replace.
---@param line_content string New line content
function MpvExtmarks:paste_line(playlist_id, line_content)
  if not vim.bo[self.buffer_id].modifiable then return end
  if not list_contains(self.playlist_ids, playlist_id) then return end

  local loc = vim.api.nvim_buf_get_extmark_by_id(
    self.buffer_id,
    PLAYLIST_NAMESPACE,
    playlist_id,
    {}
  )

  -- Update the buffer only on mismatches
  if line_content ~= vim.fn.getbufline(self.buffer_id, loc[1] + 1)[1] then
    vim.fn.setbufline(self.buffer_id, loc[1] + 1, line_content)
    helpers.try_write_buffer(self.buffer_id)
  end
end

---Paste in whole playlist "on top" of an old playlist item.
---Before doing so, try to move the player to the new item so its position
---is always valid.
---@param old_playlist_id integer Playlist ID of item to replace.
---@param new_playlist string[] Replacement buffer content for playlist item
---@param current_index integer Index (NOT ID) in the playlist to move the player to after pasting.
---@return integer[]
function MpvExtmarks:paste_playlist(old_playlist_id, new_playlist, current_index)
  if not vim.bo[self.buffer_id].modifiable then return {} end

  -- get the old location of the playlist item
  local loc = vim.api.nvim_buf_get_extmark_by_id(
    self.buffer_id,
    PLAYLIST_NAMESPACE,
    old_playlist_id,
    {}
  )
  if loc[1] == nil then return {} end

  -- replace the playlist and add new lines afterward
  vim.fn.setbufline(self.buffer_id, loc[1] + 1, new_playlist[1])
  ---@diagnostic disable-next-line No need to warn about appendbufline not working for tables
  vim.fn.appendbufline(self.buffer_id, loc[1] + 1, list_slice(new_playlist, 2))
  helpers.try_write_buffer(self.buffer_id)

  local save_extmarks = {{loc[1], old_playlist_id}}
  for i = 2, #new_playlist do
    -- Create new playlist extmarks in the same manner as create_player
    local extmark_id = vim.api.nvim_buf_set_extmark(
      self.buffer_id,
      PLAYLIST_NAMESPACE,
      loc[1] + 1,
      1,
      {
        sign_text = "|",
        sign_hl_group = "MpvPlaylistSign",
      }
    )
    table.insert(self.playlist_ids, extmark_id)

    save_extmarks[i] = {loc[1] + i - 1, extmark_id}
  end

  -- TODO: indexing seems wrong. Why do we need to save the location number?
  -- move the player just in case
  local current_item = save_extmarks[current_index]
  self:move(current_item[2])

  -- only return extmark ids
  return tbl_map(function(i) return i[2] end, save_extmarks)
end

---Delete extmarks in the displays and playlists namespace.
---Also clears up playlist information in the buffer.
function MpvExtmarks:remove()
  -- Buffer already deleted
  if #vim.fn.getbufinfo(self.buffer_id) == 0 then return end

  vim.api.nvim_buf_del_extmark(
    self.buffer_id,
    DISPLAY_NAMESPACE,
    self.player_id
  )
  for _, playlist_id in pairs(self.playlist_ids) do
    vim.api.nvim_buf_del_extmark(
      self.buffer_id,
      PLAYLIST_NAMESPACE,
      playlist_id
    )
  end
end

return MpvExtmarks
