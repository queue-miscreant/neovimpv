-- mpv/playlist.lua
-- Storage class for mapping mpv playlists to extmark ids.

local log = require("neovimpv.mpv.log")
local player_registry = require("neovimpv.players")
local util = require("neovimpv.mpv.util")

local tbl_count = vim.tbl_count
local tbl_keys = vim.tbl_keys
local list_contains = vim.list_contains
local list_extend = vim.list_extend

---@alias PlaylistId string
---@alias ExtmarkId integer

---@class MpvPlaylist
---Playlist information cached in the plugin, such as filenames, extmark id, and
---whether the line can be rewritten in markdown.
---@field playlist_id_to_item table<PlaylistId, MpvItem>
---Remaps from one mpv id to another
---@field playlist_id_remap table<PlaylistId, PlaylistId>
---For "stay" mode, map the old playlist id to first new item
---@field _updated_indices table<PlaylistId, ExtmarkId>
---Temporary object containing `playlist_id_to_extra_data` for reopening the player
---@field _new_items table<PlaylistId, MpvItem>
---Dict mapping filenames to titles, in case we have to reopen the player
---@field _loaded_titles table<string, string>
---Object containing state about current state of an mpv playlist.
---Responsible for remembering how to map mpv ids to extmark ids in nvim.
local MpvPlaylist = {}
MpvPlaylist.__index = MpvPlaylist

---@param buffer_id integer
---@param line_data string[]
---@param start_line integer
---@param end_line integer
---@param do_markdown boolean
---@return MpvPlaylist, integer
function MpvPlaylist.new(buffer_id, line_data, start_line, end_line, ignore_mode, do_markdown)
  local preliminary_playlist = util.construct_playlist_items(
      line_data,
      start_line,
      end_line,
      ignore_mode
  )
  if tbl_count(preliminary_playlist) == 0 then
    error(
      (start_line == end_line and "Line does" or "Lines do")
      .. " not contain a file path or valid URL"
    )
  end

  local playlist_lines = tbl_keys(preliminary_playlist)
  table.sort(playlist_lines)

  -- TODO
  local success, err = pcall(function()
    -- TODO
    return vim._neovimpv_callbacks.create_player(
      buffer_id,
      playlist_lines  -- only the line number, not the file name
    )
  end)

  if not success then error("Could not create playlist in nvim!") end

  ---@diagnostic disable-next-line
  local player_id, playlist_extmark_ids = unpack(err)

  local file_index = 1
  local playlist_id_to_item = {}
  for i, line in ipairs(playlist_lines) do
    local extmark_id = playlist_extmark_ids[i]
    local files, rewritable_line = unpack(preliminary_playlist[line])
    for _, file in ipairs(files or {}) do
      playlist_id_to_item[tostring(file_index)] = {
          filename = file,
          extmark_id = extmark_id,
          update_markdown = rewritable_line and do_markdown,
          show_currently_playing = not rewritable_line,
      } --[[@as MpvItem]]
      file_index = file_index + 1
    end
  end

  local ret = {
    playlist_id_to_item = playlist_id_to_item,
    playlist_id_remap = {},
    _updated_indices = {},
    _new_items = nil,
    _loaded_titles = {},
  }
  setmetatable(ret, MpvPlaylist)

  return ret, player_id
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
---@param mpv MpvWrapper
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
    and vim._neovimpv_callbacks.move_player(
        mpv.manager.buffer,
        mpv.manager.id,
        mpv_item.extmark_id,
        show_text
    )

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
---@param mpv MpvWrapper
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
      current_title = item.title or self._loaded_titles[item.filename]
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

  vim._neovimpv_callbacks.show_playlist_current(
    mpv.manager.buffer,
    mpv_item.extmark_id,
    current_title
  )
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
      use_markdown
        and ("[%s](%s)"):format((item.title or ""):gsub('%[', '('):gsub('%]',')'), item.filename)
        or item.filename
    )
  end
  return write_lines
end

---Paste the playlist items on top of the playlist
---Used when the mpv subprocess receives new playlist data and updates the buffer
---("paste", "paste-one").
---Nvim is assumed to not be in a fast callabck.
---@param mpv MpvWrapper
---@param new_playlist table
---@param playlist_id PlaylistId
function MpvPlaylist:_paste_playlist(mpv, new_playlist, playlist_id)
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

  local write_lines = get_write_lines(new_playlist, mpv_item.update_markdown)
  local new_extmarks = vim._neovimpv_callbacks.paste_playlist(
      mpv.manager.buffer,
      mpv.manager.id,
      mpv_item.extmark_id,
      write_lines,
      playlist_current + 1
  )
  log.info("Got new extmarks!")
  log.debug("write_lines: %s\nnew_extmarks: %s", write_lines, new_extmarks)
  mpv.no_draw = false

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

---Create a new buffer and paste the playlist items.
---Used when the mpv subprocess receives new playlist data and updates the buffer ("new-one").
-- Nvim is assumed to not be in a fast callabck.
---@param mpv MpvWrapper
---@param new_playlist table
---@param playlist_id PlaylistId
function MpvPlaylist:_new_playlist_buffer(mpv, new_playlist, playlist_id)
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

  -- TODO: multiple return values
  local new_buffer_id, new_display, new_extmarks = unpack(
    vim._neovimpv_callbacks.new_playlist_buffer(
      mpv.manager.buffer,
      mpv.manager.id,
      mpv_item.extmark_id,
      write_lines
    ) or {}
  )
  log.info("Got new playlist buffer")
  log.debug(
    "Got new playlist buffer\n"
    .. "new_buffer_id: %s\n"
    .. "new_display: %s\n"
    .. "new_extmarks: %s",
    new_buffer_id,
    new_display,
    new_extmarks
  )
  mpv.no_draw = false

  player_registry.reregister(mpv.manager, new_buffer_id, new_display)
  mpv.manager.buffer = new_buffer_id
  mpv.manager.id = new_display

  -- bind the new extmarks to their mpv ids
  for i = 1, #new_playlist do
    local new_mpv_item = new_playlist[i]
    local extmark_id = new_extmarks[i]
    self.playlist_id_to_item[new_mpv_item.id] = {
      filename = new_mpv_item.filename,
      extmark_id = extmark_id,
      update_markdown = false,
      show_currently_playing = false,
    }
  end

  mpv._debounce_playlist = false
end

---Update state after playlist loaded.
---The playlist retrieved from MpvSocket is raw, so we need to do a bit of extra processing.
---@param mpv MpvWrapper
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
    mpv.manager.update_action == "stay"
    or tbl_count(self.playlist_id_to_item) > 1
    and list_contains({"paste_one", "new_one"}, mpv.manager.update_action)
  )

  -- map the old playlist id to the first item in the new one
  self._updated_indices[original_entry] = start

  if do_stay then
    -- add remaps (i.e., old playlist id to new playlist id)
    for i = start, (end_ - 1) do
      self.playlist_id_remap[i] = original_entry
    end
  elseif list_contains({"paste", "paste_one"}, mpv.manager.update_action) then
    mpv.no_draw = true
    vim.defer_fn(function()
      self:_paste_playlist(
          mpv,
          new_playlist_items,
          original_entry
      )
    end, 0)
  elseif mpv.manager.update_action == "new_one" then
    mpv.no_draw = true
    mpv._debounce_playlist = true
    vim.defer_fn(function()
      self:_new_playlist_buffer(
          mpv,
          new_playlist_items,
          original_entry
      )
    end, 0)
  end
end

---Set the current file to the mpv file specified by the extmark `playlist_item`
---@param mpv MpvWrapper
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
---@param mpv MpvWrapper
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
