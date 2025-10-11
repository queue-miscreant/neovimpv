-- mpv/playlist.lua
-- Storage class for mapping mpv playlists to extmark ids.

local log = require("neovimpv.mpv.log")
local player_registry = require("neovimpv.players")
local BufferExtmarks = require("neovimpv.extmarks.buffer")
local helpers = require("neovimpv.helpers")

local tbl_count = vim.tbl_count
local tbl_keys = vim.tbl_keys
local list_contains = vim.list_contains
local list_extend = vim.list_extend
local list_slice = vim.list_slice

---@alias PlaylistId string
---@alias ExtmarkId integer

---@class MpvPlaylist
---Playlist information cached in the plugin, such as filenames, extmark id, and
---whether the line can be rewritten in markdown.
---@field extmarks BufferExtmarks
---Player/playlist extmark manager
---@field playlist_id_to_item table<PlaylistId, MpvItem>
---Remaps from one mpv id to another
---@field playlist_id_remap table<PlaylistId, PlaylistId>
---For "stay" mode, map the old playlist id to first new item
---@field _updated_indices table<PlaylistId, ExtmarkId>
---Temporary object containing `playlist_id_to_extra_data` for reopening the player
---@field _new_items table<PlaylistId, MpvItem>
---Object containing state about current state of an mpv playlist.
---Responsible for remembering how to map mpv ids to extmark ids in nvim.
local MpvPlaylist = {}
MpvPlaylist.__index = MpvPlaylist

---@param buffer_id integer
---@param lines_to_links table<LineNumber, [string[], boolean]>
---@return MpvPlaylist
function MpvPlaylist.new(buffer_id, lines_to_links)
  local playlist_lines = tbl_keys(lines_to_links)
  table.sort(playlist_lines)

  local extmarks = BufferExtmarks.new(buffer_id, playlist_lines)

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

  local ret = {
    extmarks = extmarks,
    playlist_id_to_item = playlist_id_to_item,
    playlist_id_remap = {},
    _updated_indices = {},
    _new_items = nil,
  }
  setmetatable(ret, MpvPlaylist)

  return ret
end

function MpvPlaylist:__len()
  -- Set-like table for remap targets
  local remap_dests = {}
  for _, val in pairs(self.playlist_id_remap) do
    remap_dests[val] = true
  end

  -- number of extmarks plus number of remaps minus unique remap targets
  return (
    tbl_count(self.playlist_id_to_item)
    + tbl_count(self.playlist_id_remap)
    - tbl_count(remap_dests)
  )
end

---Reorder playlist_ids by their index in the playlist.
---This is used when transitioning between two mpv instances while maintaining the playlist.
function MpvPlaylist:reorder_by_index(old_playlist)
  ---@type table<PlaylistId,PlaylistId>
  local new_remap = {}
  ---@type table<PlaylistId,MpvItem>
  local new_items = {}
  ---@type table<PlaylistId,boolean>
  local mapped = {}

  for i, item in ipairs(old_playlist) do
    local playlist_id = tostring(item.id)
    if self.playlist_id_remap[playlist_id] ~= nil then
      new_remap[tostring(i + 1)] = self.playlist_id_remap[playlist_id]
      mapped[self.playlist_id_remap[playlist_id]] = true
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

  log.info("Reordered playlist!")
  log.debug("playlist_id_remap: %s\nnew_items: %s", new_remap, new_items)

  if self._new_items ~= nil then
    self.playlist_id_to_item = self._new_items
    self._new_items = nil
  end

  self.playlist_id_remap = new_remap
  self.playlist_id_to_item = new_items
  self._updated_indices = {}
end

-- Invoke the Lua callback for moving the player to the line of a playlist extmark.
-- Used when the mpv subprocess starts a queued item to move the player to the correct line.
-- Nvim is assumed to not be in a fast callabck.
---@param mpv MpvManager
---@param playlist_id PlaylistId Playlist ID from mpv, converted for mapping
---@param show_text string?
function MpvPlaylist:move_player_extmark(mpv, playlist_id, show_text)
  assert(not vim.in_fast_event())

  log.debug(
      "Moving player!\n"
      .. "playlist_id: %s\n"
      .. "playlist_id_to_item: %s\n"
      .. "playlist_id_remap: %s",
      playlist_id,
      self.playlist_id_to_item,
      self.playlist_id_remap
  )
  local mpv_item = self.playlist_id_to_item[playlist_id]
  ---@type boolean
  local success = mpv_item ~= nil
    and self.extmarks:move(mpv_item.extmark_id, show_text)

  if not success then
    local filename = (self.playlist_id_to_item[playlist_id] or {}).filename

    vim.notify(
      "Could not move the player (current file: " .. filename .. ")!",
      vim.log.levels.ERROR,
      {}
    )
    log.debug(
      "Could not move the player!\n"
      .. "filename: %s\n"
      .. "playlist_id: %s\n"
      .. "playlist: %s",
      filename,
      playlist_id,
      mpv.socket.data.playlist
    )
  end
end

---Invoke the Lua callback for updating the currently playing text.
---Used when the mpv subprocess loads a queued item to update a "Currently Playing" display.
---Nvim is assumed to not be in a fast callabck.
---@param mpv MpvManager
---@param current_playlist_id PlaylistId
---@param redirected_playlist_id? PlaylistId
function MpvPlaylist:update_currently_playing(
    mpv, current_playlist_id, redirected_playlist_id
)
  assert(not vim.in_fast_event())

  ---@type table<string, any>
  local playlist_from_mpv = mpv.socket.data.playlist or {}
  ---@type string?
  local current_title
  for _, item in ipairs(playlist_from_mpv) do
    if item.id == current_playlist_id then
      current_title = item.title
      break
    end
  end
  log.debug(
      "current_playlist_id: %s\n"
      .. "redirected_playlist_id: %s\n",
      current_playlist_id,
      redirected_playlist_id
  )

  local mpv_item = self.playlist_id_to_item[
    redirected_playlist_id or current_playlist_id
  ]

  if mpv_item == nil then
    vim.notify(
      "Error updating currently playing title!",
      vim.log.levels.ERROR,
      {}
    )
    log.error("Could not find extmark id from mpv playlist_id")
    return
  end

  log.info("Updating currently playing!")
  log.debug(
    "current_playlist_id: %s, current_title: %s\n"
    .. "redirected_playlist_id: %s\n"
    .. "playlist_id_to_item: %s\n",
    current_playlist_id,
    current_title,
    redirected_playlist_id,
    self.playlist_id_to_item
  )

  if current_title == nil then
    log.info(
        "No currently playing title.\nIgnoring currently playing update!"
    )
    return
  end

  self.extmarks:show_currently_playing(mpv_item.extmark_id, current_title)
  mpv.no_draw = false
end

---@class MpvPlaylistData
---@field current boolean
---@field filename string
---@field id integer
---@field playing boolean
---@field title string?

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

---Paste in whole playlist "on top" of an old playlist item.
---Before doing so, try to move the player to the new item so its position
---is always valid.
---
---@param extmarks BufferExtmarks
---@param old_playlist_id integer Playlist ID of item to replace.
---@param new_playlist string[] Replacement buffer content for playlist item
---@param current_index integer Index (NOT ID) in the playlist to move the player to after pasting.
---@return integer[]
local function paste_playlist(extmarks, old_playlist_id, new_playlist, current_index)
  -- get the old location of the playlist item
  local loc = vim.api.nvim_buf_get_extmark_by_id(
    extmarks.buffer_id,
    helpers.playlist_namespace,
    old_playlist_id,
    {}
  )

  -- replace the playlist and add new lines afterward
  vim.fn.setbufline(extmarks.buffer_id, loc[1] + 1, new_playlist[1])
  vim.fn.appendbufline(extmarks.buffer_id, loc[1] + 1, list_slice(new_playlist, 2))
  helpers.try_write_buffer(extmarks.buffer_id)

  local save_extmarks = {{loc[1], old_playlist_id}}
  for i = 2, #new_playlist do
    -- And create a playlist extmark for it
    -- Need to be back in main loop for the actual line numbers
    local extmark_id = vim.api.nvim_buf_set_extmark(
      extmarks.buffer_id,
      helpers.playlist_namespace,
      loc[1] + 1,
      0,
      {}
    )

    save_extmarks[i] = {loc[1] + i - 1, extmark_id}
  end

  -- TODO: remember playlist items created!
  for i = 1, #save_extmarks do
    local playlist_item = save_extmarks[i]
    -- Set the extmarks in the same manner as create_player
    vim.api.nvim_buf_set_extmark(
      extmarks.buffer_id,
      helpers.playlist_namespace,
      playlist_item[1],
      0,
      {
        id = playlist_item[2],
        sign_text = "|",
        sign_hl_group = "MpvPlaylistSign"
      }
    )
    -- move the player just in case
    if i == current_index then
      extmarks:move(playlist_item[2])
    end
  end

  -- only return extmark ids
  return vim.tbl_map(function(i) return i[2] end, save_extmarks)
end

---Paste the playlist items on top of the playlist
---Used when the mpv subprocess receives new playlist data and updates the buffer
---("paste", "paste-one").
---Nvim is assumed to not be in a fast callabck.
---@param new_playlist table
---@param playlist_id PlaylistId
function MpvPlaylist:_paste_playlist(new_playlist, playlist_id)
  assert(not vim.in_fast_event())

  log.info("Pasting new playlist!")
  log.debug("new_playlist: %s", new_playlist)
  -- make sure we get the right index for currently-playing
  local playlist_current = get_current(new_playlist)
  if playlist_current == nil then
    vim.notify("Could not get current playlist index!", vim.log.levels.ERROR, {})
    return
  end

  -- get markdown, if applicable
  local mpv_item = self.playlist_id_to_item[playlist_id]
  if mpv_item == nil then
    log.error(
        "Attempted to paste playlist, but could not find original player!"
    )
    return
  end

  -- TODO: check markdown writeable
  -- list_contains(config.markdown_writable, current_filetype)
  local write_lines = get_write_lines(new_playlist, mpv_item.update_markdown)
  local new_extmarks = paste_playlist(
    self.extmarks,
    mpv_item.extmark_id,
    write_lines,
    playlist_current + 1
  )
  log.info("Got new extmarks!")
  log.debug("write_lines: %s\nnew_extmarks: %s", write_lines, new_extmarks)

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
-- Nvim is assumed to not be in a fast callabck.
---TODO: user chooses open in split, open in vert split, open in new tab
---@param new_playlist table
---@param playlist_id PlaylistId
---@return boolean?
function MpvPlaylist:_new_playlist_buffer(new_playlist, playlist_id)
  assert(not vim.in_fast_event())

  log.info("Creating new playlist buffer!")
  log.debug("new_playlist: %s", new_playlist)
  -- get markdown, if applicable
  local mpv_item = self.playlist_id_to_item[playlist_id]
  if mpv_item == nil then
    log.error(
        "Attempted to create playlist buffer, but could not find original player!"
    )
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
  local new_player = BufferExtmarks.new(new_buffer, {1, -1})
  self.extmarks = new_player

  -- TODO
  -- vim.api.nvim_buf_call(new_buffer, function()
  --   bind_forward_deletions(true)
  -- end)
  --
  log.info("Got new playlist buffer")
  log.debug(
    "Got new playlist buffer\n"
    .. "new_buffer_id: %s\n"
    .. "new_display: %s\n"
    .. "new_extmarks: %s",
    new_player.buffer_id,
    new_player.player_id,
    new_player.playlist_ids
  )

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
---@param mpv MpvManager
---@param data table
function MpvPlaylist:update(mpv, data)
  log.debug(
    "Got updated playlist!\n"
    .. "playlist: %s",
    data
  )

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
    mpv.update_action == "stay"
    or tbl_count(self.playlist_id_to_item) > 1
    and list_contains({"paste_one", "new_one"}, mpv.update_action)
  )

  -- map the old playlist id to the first item in the new one
  self._updated_indices[original_entry] = start

  if do_stay then
    -- add remaps (i.e., old playlist id to new playlist id)
    for i = start, (end_ - 1) do
      self.playlist_id_remap[i] = original_entry
    end
  elseif list_contains({"paste", "paste_one"}, mpv.update_action) then
    mpv.no_draw = true
    vim.defer_fn(function()
      self:_paste_playlist(
          new_playlist_items,
          original_entry
      )
      mpv.no_draw = false
    end, 0)
  elseif mpv.update_action == "new_one" then
    mpv.no_draw = true
    mpv._debounce_playlist = true
    vim.defer_fn(function()
      local success = self:_new_playlist_buffer(
          new_playlist_items,
          original_entry
      )
      mpv.no_draw = false
      mpv._debounce_playlist = false

      if success then
        player_registry.reregister(mpv, self.extmarks.buffer_id, self.extmarks.player_id)
        -- TODO: may be unnecessary
        mpv.buffer = self.extmarks.buffer_id
        mpv.id = self.extmarks.player_id
      end
    end, 0)
  end
end

---Set the current file to the mpv file specified by the extmark `playlist_item`
---@param mpv MpvManager
---@param extmark_id ExtmarkId
function MpvPlaylist:set_current_by_playlist_extmark(mpv, extmark_id)
  -- try to remap the extmark to the one it came from
  local s_extmark_id = tostring(extmark_id)
  ---@type string?
  local try_remap = s_extmark_id
  for _, remapped_id in pairs(self.playlist_id_remap) do
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
  local playlist = mpv.socket.data.playlist or {}
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

  log.debug(
    "Setting current playlist item!\n"
    .. "extmark_id: %s\n"
    .. "try_remap: %s\n"
    .. "playlist_id: %s\n"
    .. "playlist_index: %s",
    extmark_id,
    try_remap,
    playlist_id,
    playlist_index
  )

  if playlist_index == nil then
    vim.defer_fn(function()
      vim.notify(
        "Could not find mpv item!",
        vim.log.levels.ERROR,
        {}
      )
    end, 0)
    log.error("Entry %s does not exist in playlist!\n%s", playlist_id, playlist)
    return
  end

  mpv.socket:send_command({"playlist-play-index", playlist_index})
end

---Forward deletions to mpv.
---Used when deletions or changes occur in the buffer.
---@param mpv MpvManager
---@param removed_items integer[]
function MpvPlaylist:forward_deletions(mpv, removed_items)
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
    for j, k in pairs(self.playlist_id_remap) do
      if k == s_i then
        table.insert(static_deletions, j)
      end
    end
  end
  list_extend(playlist_ids, static_deletions)

  -- get deleted indexes
  ---@type MpvPlaylistData[]
  local playlist = mpv.socket.data.playlist or {}
  local removed_indices = {}
  for index, item in ipairs(playlist) do
    if list_contains(playlist_ids, item.id) then
      table.insert(removed_indices, index)
    end
  end

  log.debug(
    "Removing mpv ids!\n"
    .. "playlist_ids: %s\n"
    .. "playlist: %s",
    playlist_ids,
    playlist
  )

  table.sort(removed_indices)
  for i = #removed_indices, 1, -1 do
    mpv.socket:send_command({"playlist-remove", removed_indices[i]})
  end
end

return MpvPlaylist
