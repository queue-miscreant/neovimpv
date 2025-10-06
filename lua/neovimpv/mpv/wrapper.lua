-- Implements a plugin-aware container for an mpv asyncio protocol object and a manager
-- for playlist extmarks.
--
-- from dataclasses import dataclass
-- import logging
-- from typing import TYPE_CHECKING
--
-- import pynvim
--
-- from neovimpv.protocol import MpvProtocol

local formatting = require("neovimpv.formatting")
local log = require("neovimpv.mpv.log")

-- Example behavior of multiline playlist:
--
-- (link without markdown 1)   ---->     Try markdown, no "currently playing"
-- (link 2) (link 3)           --|->     No markdown, currently playing
--                               |->     No markdown, currently playing
-- (playlist 4, ...)           ---->     No markdown, no "currently playing"
--                                       Player arrives, sees playlist, updates "currently playing"
--                                       Item 5 has markdown, "currently playing" if "stay" mode

-- Required: nvim >=0.9(?)
local spairs = vim.spairs


---@param self MpvWrapper
local function add_events(self)
  -- default event handling
  self.socket:add_event("error", function(_, err) self:_show_error(err) end)
  self.socket:add_event("end-file", function(_, arg) self:_on_end_file(arg) end)
  self.socket:add_event("start-file", function(_, data) self:_on_start_file(data) end)
  self.socket:add_event("file-loaded", function(_, _) self:_preamble() end)
  self.socket:add_event("close", function(_, _) self.manager:close() end)
  -- TODO
  self.socket:add_event("property-change", function(_, _) self:draw_update() end)
  self.socket:add_event(
    "got-playlist", function(_, data) self.manager.playlist:update(self, data) end
  )

  -- ALWAYS observe this so we can toggle pause
  self.socket:observe_property("pause")
  -- necessary for retaining playlist position
  self.socket:observe_property("playlist")
  -- for drawing [Window] instead, toggling video
  self.socket:observe_property("video-format")
  -- observe everything we need to draw the format string
  for _, i in ipairs(formatting.mpv_properties or {}) do
    self.socket:observe_property(i)
  end
end

---@param self MpvWrapper
---@param playlist MpvPlaylist
local function load_playlist(self, playlist)
  log.info("Loading playlist!")
  log.debug("%s", playlist.playlist_id_to_item)

  -- start playing the files
  for _, item in spairs(playlist.playlist_id_to_item) do
    self.socket:send_command({"loadfile", item.filename, "append-play"})
  end
end


---@class MpvItem
---@field filename string
---@field extmark_id integer
---@field update_markdown boolean
---@field show_currently_playing boolean

---@class MpvWrapper
---@field manager MpvManager
---@field socket MpvSocket
---@field no_draw boolean
---@field _debounce_playlist boolean
---An instance of mpv which is aware of the nvim plugin. Should only be
---instantiated when nvim is available for communication.
---Automatically creates a task for launching the mpv instance.
local MpvWrapper = {}
MpvWrapper.__index = MpvWrapper

---Create a new MpvWrapper object.
---`socket` must have an open transport.
---@param manager MpvManager
---@param socket MpvSocket
---@return MpvWrapper
function MpvWrapper.new(manager, socket)
  local ret = {
    manager = manager,
    socket = socket,
    no_draw = true,
    _debounce_playlist = false,
  }
  setmetatable(ret, MpvWrapper)

  add_events(ret)
  load_playlist(ret, manager.playlist)

  return ret
end

---Rerender the player extmark to which this mpv instance corresponds
---@param force_virt_text string?
function MpvWrapper:draw_update(force_virt_text)
  if self.no_draw and force_virt_text == nil then
    return
  end

  -- draw_update is called asynchronously, so protect against errors from this call
  vim.defer_fn(function()
    vim._neovimpv_callbacks.update_extmark(
      self.manager.buffer,
      self.manager.id,
      self.socket.data,
      force_virt_text
    )
  end, 0)
end

---Wait until we've got the title and filename, then format the line where
---mpv is being displayed as markdown.
---@async
function MpvWrapper:try_update_markdown(playlist_id)
  local mpv_item = self.manager.playlist.playlist_id_to_item[tostring(playlist_id)]
  if mpv_item == nil then
    vim.defer_fn(function()
      vim.notify(
        "Playlist transition failed!",
        vim.log.levels.ERROR,
        {}
      )
    end, 0)
    log.debug(
        "Playlist transition failed! Mpv id %s does not exist in %s",
        playlist_id,
        self.manager.playlist.playlist_id_to_item
    )
    return
  end

  local media_title = self.socket:wait_property("media-title")
  local mpv_filename = self.socket:wait_property("filename")
  local cannot_markdown = mpv_item.filename:find("[()]")
  if (
      not mpv_item.update_markdown
      or media_title == mpv_filename
      or cannot_markdown
  ) then
      return
  end

  vim.defer_fn(function()
    vim._neovimpv_callbacks.write_line_of_playlist_item(
      self.manager.buffer,
      mpv_item.extmark_id,
      ("[%s](%s)"):format(media_title:gsub('%[', '('):gsub('%]',')'), mpv_item.filename)
    )
  end, 0)
end

---Report error contents to nvim
---@param err {property-name: string?, error: string?}
function MpvWrapper:_show_error(err)
  local additional_info = ""
  local property_name = err["property-name"]
  if property_name then
    additional_info = " to request for property '" .. property_name .. "'"
  end

  vim.defer_fn(function()
    vim.notify(
      "mpv responded '" .. (err.error or "") .. "'" .. additional_info,
      vim.log.levels.ERROR,
      {}
    )
  end, 0)
  log.error("Error occurred: %s", err)
end


---Report an error to nvim if the file ended because of an error.
function MpvWrapper:_on_end_file(arg)
  self.no_draw = true
  self:draw_update("")

  local err = arg["file_error"]
  if arg.reason == "error" and err then
    vim.defer_fn(function()
      vim.notify(
        "File ended: " .. error,
        vim.log.levels.ERROR,
        {}
      )
    end, 0)
  end
end

---Update state after new file started.
---Move the player to new playlist item and suspend drawing until complete.
function MpvWrapper:_on_start_file(arg)
  -- Starting the file is enough information to move the player, but not enough
  -- to update the title of the video.
  self.no_draw = true
  local current_playlist_id = tostring(arg["playlist_entry_id"])

  if (
      self.socket.playlist_new ~= nil
      and current_playlist_id
      == self.socket.playlist_new["playlist_insert_id"]
  ) or self._debounce_playlist then
    return
  end
  local redirected_playlist_id = self.manager.playlist.playlist_id_remap[
    current_playlist_id
  ]

  -- use the extmark of this mpv id to move the player
  if redirected_playlist_id ~= nil then
    current_playlist_id = redirected_playlist_id
  end

  vim.defer_fn(function()
    self.manager.playlist:move_player_extmark(self, current_playlist_id)
  end, 0)
end


---Update buffer text after new file loaded.
function MpvWrapper:_preamble()
  self.no_draw = false
  -- Have enough information to update with video title
  local current_playlist_id = tostring(self.socket.last_playlist_entry_id)
  local playlist_item = self.manager.playlist.playlist_id_to_item[current_playlist_id]
  local redirected_playlist_id = self.manager.playlist.playlist_id_remap[current_playlist_id]

  if playlist_item ~= nil and playlist_item.show_currently_playing then
    vim.defer_fn(function()
      self.manager.playlist:update_currently_playing(
        self,
        tostring(current_playlist_id)
      )
    end, 0)
  elseif redirected_playlist_id ~= nil then
    vim.defer_fn(function()
      self.manager.playlist:update_currently_playing(
        self,
        tostring(current_playlist_id),
        redirected_playlist_id
      )
    end, 0)
  else
    -- Coroutine invokes MpvSocket:wait_property, and therefore should not get GC'd
    coroutine.wrap(function()
      self:try_update_markdown(current_playlist_id)
    end)()
  end
end


return MpvWrapper
