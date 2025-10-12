-- mpv/callbacks.lua
-- Class for managing buffer callbacks.

local log = require "neovimpv.log"
local formatting = require "neovimpv.formatting"
local helpers = require "neovimpv.helpers"
local config = require "neovimpv.config"
local MpvExtmarks = require "neovimpv.mpv.extmarks"

local tbl_count = vim.tbl_count
local tbl_keys = vim.tbl_keys
local list_contains = vim.list_contains
local list_extend = vim.list_extend

---@alias MpvPlaylistId string
---@alias ExtmarkId integer

---@class MpvItem
---@field filename string
---@field extmark_id integer
---@field update_markdown boolean
---@field show_currently_playing boolean
---Local representation of an item from an mpv playlist

---@class MpvPlaylistData
---@field current boolean
---@field filename string
---@field id integer
---@field playing boolean
---@field title string?
---Raw mpv playlist entry from the socket

---@class MpvCallbacks
---@field no_draw boolean
---@field update_action UpdateAction
---Player/playlist extmark manager.
---@field extmarks MpvExtmarks
---Map from mpv playlist ids to cached items.
---Unless transitioning, should be valid for spawning an MpvManager.
---@field playlist_id_to_item table<MpvPlaylistId, MpvItem>
---Remaps from one mpv id to another.
---@field _playlist_id_remap table<MpvPlaylistId, MpvPlaylistId>
---For "stay" mode, map the old playlist id to first new item.
---@field _updated_indices table<MpvPlaylistId, ExtmarkId>
---Temporary object containing `playlist_id_to_extra_data` for reopening the player.
---@field _new_items table<MpvPlaylistId, MpvItem>
---Internal debounce for playlist updates.
---@field _debounce_playlist boolean
---Object responsible for callbacks from the mpv socket to the buffer.
---Responsible for remembering the current state of an mpv playlist
---and how to map mpv ids to extmark ids in nvim.
local MpvCallbacks = {}
MpvCallbacks.__index = MpvCallbacks

---@param buffer_id integer
---@param lines_to_links table<LineNumber, [string[], boolean]>
---@param update_action UpdateAction
---@return MpvCallbacks
function MpvCallbacks.new(buffer_id, lines_to_links, update_action)
  local playlist_lines = tbl_keys(lines_to_links)
  table.sort(playlist_lines)

  local extmarks = MpvExtmarks.new(buffer_id, playlist_lines)

  local file_index = 1
  local playlist_id_to_item = {}
  for i, line in ipairs(playlist_lines) do
    local extmark_id = extmarks.playlist_ids[i]
    local files, rewritable_line = unpack(lines_to_links[line])
    for _, file in ipairs(files or {}) do
      playlist_id_to_item[tostring(file_index)] = {
        filename = file,
        extmark_id = extmark_id,
        update_markdown = rewritable_line,
        show_currently_playing = not rewritable_line,
      } --[[@as MpvItem]]
      file_index = file_index + 1
    end
  end

  -- Only one file
  if file_index == 2 then
    if config.smart_youtube then
      update_action = helpers.try_smart_youtube(playlist_id_to_item[1].filename)
    end
  elseif update_action == "new_one" then
    error("`new_one` is only valid for a single filename!")
  end

  local ret = {
    no_draw = true,
    update_action = update_action,
    extmarks = extmarks,
    playlist_id_to_item = playlist_id_to_item,
    _playlist_id_remap = {},
    _updated_indices = {},
    _new_items = nil,
    _debounce_playlist = false,
  }
  setmetatable(ret, MpvCallbacks)

  log.log(ret)

  return ret
end

function MpvCallbacks:__len()
  -- Set-like table for remap targets
  local remap_dests = {}
  for _, val in pairs(self._playlist_id_remap) do
    remap_dests[val] = true
  end

  -- number of extmarks plus number of remaps minus unique remap targets
  return (
    tbl_count(self.playlist_id_to_item)
    + tbl_count(self._playlist_id_remap)
    - tbl_count(remap_dests)
  )
end

--  ___          _       _             _ _ _             _
-- / __| ___  __| |_____| |_   __ __ _| | | |__  __ _ __| |__ ___
-- \__ \/ _ \/ _| / / -_)  _| / _/ _` | | | '_ \/ _` / _| / /(_-<
-- |___/\___/\__|_\_\___|\__| \__\__,_|_|_|_.__/\__,_\__|_\_\/__/
--
-- Socket callbacks

---Update buffer text after new file loaded.
---@param socket MpvSocket
function MpvCallbacks:on_file_loaded(socket)
  self.no_draw = false
  -- Have enough information to update with video title
  local current_playlist_id = socket.last_playlist_entry_id
  local s_current_playlist_id = tostring(current_playlist_id)
  local playlist_item = self.playlist_id_to_item[s_current_playlist_id]
  local redirected_playlist_id = self._playlist_id_remap[s_current_playlist_id]

  if (
      playlist_item ~= nil
      and playlist_item.show_currently_playing
    ) or redirected_playlist_id ~= nil
  then
    vim.defer_fn(function()
      self:_update_currently_playing(
        socket,
        s_current_playlist_id,
        redirected_playlist_id
      )
    end, 0)
  else
    -- Coroutine invokes MpvSocket:wait_property, and therefore should not get GC'd
    coroutine.wrap(function()
      local media_title = socket:wait_property("media-title")
      local mpv_filename = socket:wait_property("filename")

      vim.defer_fn(function()
        self:_try_update_markdown(media_title, mpv_filename, current_playlist_id)
      end, 0)
    end)()
  end
end

---Update state after new file started.
---Move the player to new playlist item and suspend drawing until complete.
---@param socket MpvSocket
function MpvCallbacks:on_start_file(socket, arg)
  -- Starting the file is enough information to move the player, but not enough
  -- to update the title of the video.
  self.no_draw = true
  local current_playlist_id = tostring(arg["playlist_entry_id"])

  if (
      socket.playlist_new ~= nil
      and current_playlist_id
      == socket.playlist_new["playlist_insert_id"]
  ) or self._debounce_playlist then
    return
  end
  local redirected_playlist_id = self._playlist_id_remap[
    current_playlist_id
  ]

  -- use the extmark of this mpv id to move the player
  if redirected_playlist_id ~= nil then
    current_playlist_id = redirected_playlist_id
  end

  vim.defer_fn(function()
    self:_move_player_extmark(socket, current_playlist_id)
  end, 0)
end

---Report an error to nvim if the file ended because of an error.
---@param socket MpvSocket
---@param arg table<string, any>
function MpvCallbacks:on_end_file(socket, arg)
  self.no_draw = true
  self:draw_update(socket.data, "")

  local err = arg["file_error"]
  if arg.reason == "error" and err then
    vim.defer_fn(function()
      vim.notify(
        "File ended: " .. err,
        vim.log.levels.ERROR,
        {}
      )
    end, 0)
  end
end

---Format the line where mpv is being displayed as markdown.
---Nvim is assumed to not be in a fast callback.
---@param playlist_id integer
---@param media_title string
---@param new_filename string
function MpvCallbacks:_try_update_markdown(media_title, new_filename, playlist_id)
  assert(not vim.in_fast_event())

  local mpv_item = self.playlist_id_to_item[tostring(playlist_id)]
  if mpv_item == nil then
    vim.notify(
      "Playlist transition failed!",
      vim.log.levels.ERROR,
      {}
    )
    return
  end

  local cannot_markdown = mpv_item.filename:find("[()]")
  if (
    not mpv_item.update_markdown
    or media_title == new_filename
    or cannot_markdown
  ) then
    return
  end

  self.extmarks:paste_line(
    mpv_item.extmark_id,
    helpers.markdownify(media_title, mpv_item.filename)
  )
end

---Update the currently playing text.
---Used when the mpv subprocess loads a queued item to update a "Currently Playing" display.
---Nvim is assumed to not be in a fast callback.
---@param socket MpvSocket
---@param current_playlist_id MpvPlaylistId
---@param redirected_playlist_id? MpvPlaylistId
function MpvCallbacks:_update_currently_playing(
    socket, current_playlist_id, redirected_playlist_id
)
  assert(not vim.in_fast_event())

  ---@type MpvPlaylistData
  local playlist_from_mpv = socket.data.playlist or {}
  ---@type string?
  local current_title
  for _, item in ipairs(playlist_from_mpv) do
    if tostring(item.id) == current_playlist_id then
      current_title = item.title
      break
    end
  end
  log.log{
    current_title = current_title,
    current_playlist_id = current_playlist_id,
    redirected_playlist_id = redirected_playlist_id,
  }

  local mpv_item = self.playlist_id_to_item[
    redirected_playlist_id or current_playlist_id
  ]

  if mpv_item == nil then
    vim.notify(
      "Error updating currently playing title!",
      vim.log.levels.ERROR,
      {}
    )
    log.log{"Could not find extmark id from mpv playlist_id"}
    return
  end

  log.log{
    "Updating currently playing!",
    current_playlist_id = current_playlist_id,
    current_title = current_title,
    redirected_playlist_id = redirected_playlist_id,
    playlist_id_to_item = self.playlist_id_to_item,
  }

  if current_title == nil then
    log.log{
      "No currently playing title.",
      "Ignoring currently playing update!",
    }
    return
  end

  self.extmarks:show_currently_playing(mpv_item.extmark_id, current_title)
  self.no_draw = false
end

-- Move the player to the line of a playlist extmark.
-- Used when the mpv subprocess starts a queued item to move the player to the correct line.
-- Nvim is assumed to not be in a fast callback.
---@param socket MpvSocket
---@param playlist_id MpvPlaylistId Playlist ID from mpv, converted for mapping
---@param show_text string?
function MpvCallbacks:_move_player_extmark(socket, playlist_id, show_text)
  assert(not vim.in_fast_event())

  log.log{
    "Moving player!",
    playlist_id = playlist_id,
    playlist_id_to_item = self.playlist_id_to_item,
    playlist_id_remap = self._playlist_id_remap,
  }
  local mpv_item = self.playlist_id_to_item[playlist_id]
  local success = mpv_item ~= nil
    and self.extmarks:move(mpv_item.extmark_id, show_text)

  if not success then
    local filename = (self.playlist_id_to_item[playlist_id] or {}).filename or "(none)"

    vim.notify(
      "Could not move the player (current file: " .. filename .. ")!",
      vim.log.levels.ERROR,
      {}
    )
    log.log{
      "Could not move the player!",
      filename = filename,
      playlist_id = playlist_id,
      playlist = socket.data.playlist,
    }
  end
end

--  _   _ _   _ _ _ _   _
-- | | | | |_(_) (_) |_(_)___ ___
-- | |_| |  _| | | |  _| / -_|_-<
--  \___/ \__|_|_|_|\__|_\___/__/
--
-- Utilities

---Rerender the player extmark to which this mpv instance corresponds
---@param data table<string, any>
---@param force_text? string
function MpvCallbacks:draw_update(data, force_text)
  ---@type VirtText?
  local virt_text
  if force_text then
    virt_text = {{force_text, "MpvDefault"}}
  else
    if self.no_draw then return end
    virt_text = formatting.render(data)
  end

  -- draw_update can be called asynchronously
  vim.defer_fn(function()
    self.extmarks:update(virt_text)
  end, 0)
end

---Reorder playlist_ids by their index in the playlist.
---This is used when transitioning between two mpv instances while maintaining the playlist.
function MpvCallbacks:reorder_by_index(old_playlist)
  ---@type table<MpvPlaylistId,MpvPlaylistId>
  local new_remap = {}
  ---@type table<MpvPlaylistId,MpvItem>
  local new_items = {}
  ---@type table<MpvPlaylistId,boolean>
  local mapped = {}

  for i, item in ipairs(old_playlist) do
    local playlist_id = tostring(item.id)
    if self._playlist_id_remap[playlist_id] ~= nil then
      new_remap[tostring(i + 1)] = self._playlist_id_remap[playlist_id]
      mapped[self._playlist_id_remap[playlist_id]] = true
    end
    -- Create a new MpvItem instance
    -- No effect if the lookup fails
    new_items[tostring(i + 1)] = self.playlist_id_to_item[playlist_id]
  end

  for extmark_id, _ in pairs(mapped) do
    -- attempt to find remapped extmarks and assign them in the item dict
    for new_playlist_id, playlist_extmark_id in pairs(new_remap) do
      if playlist_extmark_id == extmark_id then
        ---@diagnostic disable-next-line
        new_items[new_playlist_id].extmark_id = tonumber(extmark_id)
        break
      end
    end
  end

  log.log{
    "Reordered playlist!",
    new_remap = new_remap,
    new_items = new_items,
  }

  if self._new_items ~= nil then
    self.playlist_id_to_item = self._new_items
    self._new_items = nil
  end

  self._playlist_id_remap = new_remap
  self.playlist_id_to_item = new_items
  self._updated_indices = {}
end

---@param playlist MpvPlaylistData[]
local function get_current(playlist)
  for i, item in ipairs(playlist) do
    if item.current then
      return i
    end
  end
end

---@param playlist MpvPlaylistData[]
---@param use_markdown boolean
local function get_write_lines(playlist, use_markdown)
  local write_lines = {}
  for _, item in ipairs(playlist) do
    table.insert(
      write_lines,
      use_markdown and helpers.markdownify(item.title, item.filename) or item.filename
    )
  end
  return write_lines
end

---Paste the playlist items on top of the playlist
---Used when the mpv subprocess receives new playlist data and updates the buffer
---("paste", "paste-one").
---Nvim is assumed to not be in a fast callback.
---@param new_playlist table
---@param playlist_id MpvPlaylistId
function MpvCallbacks:_paste_playlist(new_playlist, playlist_id)
  assert(not vim.in_fast_event())

  log.log{
    "Pasting new playlist!",
    new_playlist = new_playlist,
  }
  -- make sure we get the right index for currently-playing
  local playlist_current = get_current(new_playlist)
  if playlist_current == nil then
    vim.notify("Could not get current playlist index!", vim.log.levels.ERROR, {})
    return
  end

  -- get markdown, if applicable
  local mpv_item = self.playlist_id_to_item[playlist_id]
  if mpv_item == nil then
    log.log{
      "Attempted to paste playlist, but could not find original player!"
    }
    return
  end

  -- TODO: check markdown writeable
  -- list_contains(config.markdown_writable, current_filetype)
  local write_lines = get_write_lines(new_playlist, mpv_item.update_markdown)
  local new_extmarks = self.extmarks:paste_playlist(
    mpv_item.extmark_id,
    write_lines,
    playlist_current + 1
  )
  log.log{
    "Got new extmarks!",
    write_lines = write_lines,
    new_extmarks = new_extmarks
  }

  -- bind the new extmarks to their mpv ids
  for i = 1, #new_playlist do
    local new_mpv_item = new_playlist[i]
    local extmark_id = new_extmarks[i]
    self.playlist_id_to_item[new_mpv_item.id] = {
      filename = new_mpv_item.filename,
      extmark_id = extmark_id,
      update_markdown = mpv_item.update_markdown,
      show_currently_playing = false,
    }
  end
end

---Create a new buffer in a split and paste the playlist items.
---Used when the mpv subprocess receives new playlist data and updates the buffer ("new-one").
-- Nvim is assumed to not be in a fast callback.
---TODO: user chooses open in split, open in vert split, open in new tab
---@param new_playlist table
---@param playlist_id MpvPlaylistId
---@return boolean?
function MpvCallbacks:_new_playlist_buffer(new_playlist, playlist_id)
  assert(not vim.in_fast_event())

  log.log{
    "Creating new playlist buffer!",
    new_playlist = new_playlist,
  }
  -- get markdown, if applicable
  local mpv_item = self.playlist_id_to_item[playlist_id]
  if mpv_item == nil then
    log.log{
      "Attempted to create playlist buffer, but could not find original player!"
    }
    return
  end

  local write_lines = get_write_lines(new_playlist, mpv_item.update_markdown)

  -- open split to an empty scratch
  vim.cmd("bel split")
  local win = vim.api.nvim_get_current_win()
  local new_buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, new_buffer)

  -- set buffer content
  vim.api.nvim_buf_set_lines(new_buffer, 0, -1, false, write_lines)

  vim.bo[new_buffer].modifiable = false
  vim.bo[new_buffer].bufhidden = "wipe"
  vim.bo[new_buffer].filetype = vim.bo[buffer].filetype

  -- "Move" player extmark between buffers.
  self.extmarks:remove()
  local new_player = MpvExtmarks.new(new_buffer, {1, -1})
  self.extmarks = new_player

  -- TODO
  -- vim.api.nvim_buf_call(new_buffer, function()
  --   bind_forward_deletions(true)
  -- end)
  --
  log.log{
    "Got new playlist buffer",
    new_player = new_player,
  }

  -- bind the new extmarks to their mpv ids
  for i = 1, #new_playlist do
    local new_mpv_item = new_playlist[i]
    local extmark_id = new_player.playlist_ids[i]
    self.playlist_id_to_item[new_mpv_item.id] = {
      filename = new_mpv_item.filename,
      extmark_id = extmark_id,
      update_markdown = false,
      show_currently_playing = false,
    }
  end

  return true
end

---Update state after playlist loaded.
---The playlist retrieved from MpvSocket is raw, so we need to do a bit of extra processing.
---@param data table
---@param new_buffer_callback fun()
function MpvCallbacks:update_playlist(data, new_buffer_callback)
  log.log{
    "Got updated playlist!",
    playlist = data,
  }

  -- the mpv video id which triggered the new playlist
  -- should correspond to the index in self.playlist_id_to_item
  local original_entry = data.new.playlist_entry_id
  local start = data.new.playlist_insert_id
  local end_ = start + data.new.playlist_insert_num_entries
  local new_playlist_items = {}
  for _, i in ipairs(data.playlist) do
    if i.id > start and i.id < end_ then
      table.insert(new_playlist_items, i)
    end
  end

  -- "stay" if we've been told to or we're not a single playlist
  local do_stay = (
    self.update_action == "stay"
    or tbl_count(self.playlist_id_to_item) > 1
    and list_contains({"paste_one", "new_one"}, self.update_action)
  )

  -- map the old playlist id to the first item in the new one
  self._updated_indices[tostring(original_entry)] = start

  if do_stay then
    -- add remaps (i.e., old playlist id to new playlist id)
    for i = start, (end_ - 1) do
      self._playlist_id_remap[tostring(i)] = tostring(original_entry)
    end
  elseif list_contains({"paste", "paste_one"}, self.update_action) then
    self.no_draw = true
    vim.defer_fn(function()
      self:_paste_playlist(
        new_playlist_items,
        original_entry
      )
      self.no_draw = false
    end, 0)
  elseif self.update_action == "new_one" then
    self.no_draw = true
    self._debounce_playlist = true
    vim.defer_fn(function()
      local success = self:_new_playlist_buffer(
        new_playlist_items,
        original_entry
      )
      self.no_draw = false
      self._debounce_playlist = false

      if success then new_buffer_callback() end
    end, 0)
  end
end

---Set the current file to the mpv file specified by the extmark `playlist_item`
---@param socket MpvSocket
---@param extmark_id ExtmarkId
function MpvCallbacks:set_current_by_playlist_extmark(socket, extmark_id)
  -- try to remap the extmark to the one it came from
  local s_extmark_id = tostring(extmark_id)
  ---@type string?
  local try_remap = s_extmark_id
  for _, remapped_id in pairs(self._playlist_id_remap) do
    if remapped_id == s_extmark_id then
      try_remap = remapped_id
      break
    end
  end

  -- then get the mpv id from it
  local n_try_remap = tonumber(try_remap)
  ---@type string?
  local playlist_id
  for i, mpv_item in pairs(self.playlist_id_to_item) do
    if mpv_item.extmark_id == n_try_remap then
      playlist_id = i
      break
    end
  end

  -- adjustment for updated playlists
  if self._updated_indices[playlist_id] ~= nil then
    playlist_id = self._updated_indices[playlist_id]
  end

  -- then index into the current playlist
  ---@type MpvPlaylistData[]
  local playlist = socket.data.playlist or {}
  if #playlist <= 1 then
    vim.defer_fn(function()
      vim.notify(
        "Refusing to set playlist index on small playlist!",
        vim.log.levels.WARN,
        {}
      )
    end, 0)
    return
  end

  ---@type integer?
  local playlist_index
  for index, item in ipairs(playlist) do
    if item.id == playlist_id then
      playlist_index = index
      break
    end
  end

  log.log{
    "Setting current playlist item!",
    extmark_id = extmark_id,
    try_remap = try_remap,
    playlist_id = playlist_id,
    playlist_index = playlist_index,
  }

  if playlist_index == nil then
    vim.defer_fn(function()
      vim.notify(
        "Could not find mpv item!",
        vim.log.levels.ERROR,
        {}
      )
    end, 0)
    log.log{
      "Entry does not exist in playlist!",
      playlist_id = playlist_id,
      playlist = playlist,
    }
    return
  end

  socket:send_command({"playlist-play-index", playlist_index})
end

---Forward deletions to mpv.
---Used when deletions or changes occur in the buffer.
---@param socket MpvSocket
---@param removed_items integer[]
function MpvCallbacks:forward_deletions(socket, removed_items)
  local playlist_ids = {}
  for i, mpv_item in pairs(self.playlist_id_to_item) do
    if list_contains(removed_items, mpv_item) then
      table.insert(playlist_ids, i)
    end
  end

  -- reverse-lookup for remapped extmarks
  local static_deletions = {}
  for _, i in ipairs(removed_items) do
    local s_i = tostring(i)
    for j, k in pairs(self._playlist_id_remap) do
      if k == s_i then
        table.insert(static_deletions, j)
      end
    end
  end
  list_extend(playlist_ids, static_deletions)

  -- get deleted indexes
  ---@type MpvPlaylistData[]
  local playlist = socket.data.playlist or {}
  local removed_indices = {}
  for index, item in ipairs(playlist) do
    if list_contains(playlist_ids, item.id) then
      table.insert(removed_indices, index)
    end
  end

  log.log{
    "Removing mpv ids!",
    playlist_ids = playlist_ids,
    playlist = playlist,
  }

  table.sort(removed_indices)
  for i = #removed_indices, 1, -1 do
    socket:send_command({"playlist-remove", removed_indices[i]})
  end
end

return MpvCallbacks
