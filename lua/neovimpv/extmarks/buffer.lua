local config = require "neovimpv.config"
local formatting = require "neovimpv.formatting"
local helpers = require "neovimpv.helpers"

local list_contains = vim.list_contains

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
    sign_hl_group = "MpvPlaylistSign"
  }
  local rule = config.draw_playlist_extmarks
  if rule == "never" or (rule == "multiple" and #lines == 1) then
    extmark = {}
  end

  vim.api.nvim_buf_call(buffer_id, function()
    -- add each playlist extmark
    for i, j in pairs(lines) do
      local extmark_id = vim.api.nvim_buf_set_extmark(
        buffer_id,
        PLAYLIST_NAMESPACE,
        j - 1,
        0,
        extmark
      )
      extmark_ids[i] = extmark_id
    end
  end)
  return extmark_ids
end

---@class BufferExtmarks
---@field buffer_id integer Buffer in which the extmarks controlled by this table live.
---@field player_id integer Extmark ID of the player.
---@field playlist_ids integer[] Extmark ID of the player.
local BufferExtmarks = {}
BufferExtmarks.__index = BufferExtmarks

---From a list of `lines` in a buffer, create extmarks for a player (which displays
---current playback state) and a playlist (which is a list of lines to play next).
---@param buffer_id integer
---@param lines integer[] A list of line numbers (1-indexed) to add to the playlist
---@return BufferExtmarks
function BufferExtmarks.new(buffer_id, lines)
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
  setmetatable(ret, BufferExtmarks)

  return ret
end

---Push an update from an mpv property table
---@param data table<string, any>
---@param force_text? string
function BufferExtmarks:update(data, force_text)

  local video = data["video-format"] ~= nil
  ---@type VirtText?
  local virt_text
  if force_text then
    virt_text = {{force_text, "MpvDefault"}}
  elseif video then
    virt_text = {{"[ Window ]", "MpvDefault"}}
  else
    virt_text = formatting.render(data)
  end

  if virt_text == nil or force_text == "" then
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
function BufferExtmarks:move(new_playlist_id, new_text)
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
function BufferExtmarks:show_currently_playing(playlist_id, virt_text)
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
      helpers.playlist_namespace,
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

---Delete extmarks in the displays and playlists namespace.
---Also clears up playlist information in the buffer.
function BufferExtmarks:remove()
  -- Buffer already deleted
  if #vim.fn.getbufinfo(buffer) == 0 then return end

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

return BufferExtmarks
