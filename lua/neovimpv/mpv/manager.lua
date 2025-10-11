-- mpv/manager.lua
-- A container class for forwarding plugin commands to the correct MpvSocket
--
-- TODO: this interface should focus on being a generically spawnable
-- interface to mpv which the rest of the plugin can access consistently via its methods.
-- Buffer interactions should be done with a manager (e.g., `MpvPlaylist`) rather than being done ad-hoc here

local config = require("neovimpv.config")
local helpers = require("neovimpv.helpers")
local formatting = require("neovimpv.formatting")
local MpvSocket = require("neovimpv.mpv.socket")
local player_registry = require("neovimpv.players")
local log = require("neovimpv.mpv.log")

-- Required: nvim >=0.9(?)
local spairs = vim.spairs
local list_extend = vim.list_extend
local list_slice = vim.list_slice
local fs_join = (vim.fs or {}).joinpath or function(...) vim.fn.join({...}, "/") end

-- setup temp dir
local tempdir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
local mpv_socket_dir = fs_join(tempdir, "neovimpv")
vim.fn.mkdir(mpv_socket_dir, "p")


-- delay between sending a keypress to mpv and rerequesting properties
local KEYPRESS_DELAY_MS = 50
local DEFAULT_MPV_ARGS = {"--no-video"}

-- Example behavior of multiline playlist:
--
-- (link without markdown 1)   ---->     Try markdown, no "currently playing"
-- (link 2) (link 3)           --|->     No markdown, currently playing
--                               |->     No markdown, currently playing
-- (playlist 4, ...)           ---->     No markdown, no "currently playing"
--                                       Player arrives, sees playlist, updates "currently playing"
--                                       Item 5 has markdown, "currently playing" if "stay" mode

---@class MpvItem
---@field filename string
---@field extmark_id integer
---@field update_markdown boolean
---@field show_currently_playing boolean


---Wait until we've got the title and filename, then format the line where
---mpv is being displayed as markdown.
---@param self MpvManager
---@param playlist_id integer
---@async
local function try_update_markdown(self, playlist_id)
  local mpv_item = self.playlist.playlist_id_to_item[tostring(playlist_id)]
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
        self.playlist.playlist_id_to_item
    )
    return
  end

  local media_title = self.socket:wait_property("media-title")
  local mpv_filename = self.socket:wait_property("filename")

  local buffer_id = self.playlist.extmarks.buffer_id
  local cannot_markdown = mpv_item.filename:find("[()]")
  if (
    not mpv_item.update_markdown
    or media_title == mpv_filename
    or cannot_markdown
  ) then
      return
  end

  vim.defer_fn(function()
    if not vim.bo[buffer_id].modifiable then return end

    ---TODO: messy. We shouldn't need to touch extmarks via the raw interface
    local loc = vim.api.nvim_buf_get_extmark_by_id(
      buffer_id,
      helpers.playlist_namespace,
      mpv_item.extmark_id,
      {}
    )

    local line_content = helpers.markdownify(media_title, mpv_item.filename)
    -- Update the buffer only on mismatches
    if line_content ~= vim.fn.getbufline(buffer_id, loc[1] + 1)[1] then
      vim.fn.setbufline(buffer_id, loc[1] + 1, line_content)
      helpers.try_write_buffer(buffer_id)
    end
  end, 0)
end

---Event callback for reporting error contents to nvim.
---First argument consumes the mpv socket instance.
---@param err {property-name: string?, error: string?}
local function show_error(_, err)
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

---@class MpvManager
---@field buffer integer
---@field id integer
---@field no_draw boolean
---@field socket MpvSocket?
---@field playlist MpvPlaylist?
---@field update_action UpdateAction
---@field _mpv_args string[]
---@field _after_spawn thread[]
---@field _transitioning_players boolean
---@field _debounce_playlist boolean
---Manager for an mpv instance, containing options and arguments particular to it.
---TODO: transitioning_players unneeded with merged sockets?
local MpvManager = {}
MpvManager.__index = MpvManager

---@param buffer integer
---@param player_id integer
---@param playlist MpvPlaylist
---@param update_action UpdateAction
---@param mpv_args string[]
---@return MpvManager
function MpvManager.new(buffer, player_id, playlist, update_action, mpv_args)
  mpv_args = list_extend(list_slice(config.default_args), mpv_args)

  local ret = {
    buffer = buffer,
    id = player_id,
    no_draw = true,
    playlist = playlist,
    update_action = update_action,
    mpv = nil,
    _mpv_args = list_extend(list_slice(DEFAULT_MPV_ARGS), mpv_args),
    _after_spawn = {},
    _transitioning_players = false,
    _debounce_playlist = false,
  }
  setmetatable(ret, MpvManager)

  return ret
end

---Spawn subprocess and wait `timeout_duration` seconds for error output.
---If the connection is successful, the instance's `protocol` member will be set
---to an MpvProtocol for IPC.
---@param timeout_duration_ms? integer
---@return MpvManager
function MpvManager:spawn(timeout_duration_ms)
  if not timeout_duration_ms then timeout_duration_ms = 1000 end
  self._after_spawn= {}
  self._transitioning_players = true

  local ipc_path = fs_join(mpv_socket_dir, tostring(self.id))
  MpvSocket.spawn_new(
    self._mpv_args,
    ipc_path,
    timeout_duration_ms,
    function(success, mpv_socket)
      if not success then
        vim.defer_fn(function()
          vim.notify(mpv_socket --[[@as string]], vim.log.levels.ERROR, {})
        end, 0)
        self.socket = nil
        return
      end

      log.debug("Spawned mpv with args %s", self._mpv_args)
      ---@cast mpv_socket MpvSocket
      self.socket = mpv_socket

      -- default event handling
      mpv_socket:add_event("error", show_error)
      mpv_socket:add_event("end-file", function(_, arg) self:_on_end_file(arg) end)
      mpv_socket:add_event("start-file", function(_, data) self:_on_start_file(data) end)
      mpv_socket:add_event("file-loaded", function(_, _) self:_on_file_loaded() end)
      mpv_socket:add_event("close", function(_, _) self:close() end)
      mpv_socket:add_event("property-change", function(_, _) self:draw_update() end)
      mpv_socket:add_event(
        "got-playlist", function(_, data) self.playlist:update(self, data) end
      )

      -- ALWAYS observe this so we can toggle pause
      mpv_socket:observe_property("pause")
      -- necessary for retaining playlist position
      mpv_socket:observe_property("playlist")
      -- for drawing [Window] instead, toggling video
      mpv_socket:observe_property("video-format")
      -- observe everything we need to draw the format string
      for _, i in ipairs(formatting.mpv_properties or {}) do
        mpv_socket:observe_property(i)
      end

      local playlist = (self.playlist or {}).playlist_id_to_item or {}
      log.info("Loading playlist!")
      log.debug("%s", playlist)

      -- start playing the files
      for _, item in spairs(playlist) do
        mpv_socket:send_command({"loadfile", item.filename, "append-play"})
      end

      self._transitioning_players = false
      for _, coro in ipairs(self._after_spawn) do
        coroutine.resume(coro)
      end
    end
  )

  return self
end

---Report an error to nvim if the file ended because of an error.
---@private
function MpvManager:_on_end_file(arg)
  self.no_draw = true
  self:draw_update("")

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

---Update state after new file started.
---Move the player to new playlist item and suspend drawing until complete.
---@private
function MpvManager:_on_start_file(arg)
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
  local redirected_playlist_id = self.playlist.playlist_id_remap[
    current_playlist_id
  ]

  -- use the extmark of this mpv id to move the player
  if redirected_playlist_id ~= nil then
    current_playlist_id = redirected_playlist_id
  end

  vim.defer_fn(function()
    self.playlist:move_player_extmark(self, current_playlist_id)
  end, 0)
end

---Update buffer text after new file loaded.
---@private
function MpvManager:_on_file_loaded()
  self.no_draw = false
  -- Have enough information to update with video title
  local current_playlist_id = self.socket.last_playlist_entry_id
  local current_playlist_id_str = tostring(current_playlist_id)
  local playlist_item = self.playlist.playlist_id_to_item[current_playlist_id_str]
  local redirected_playlist_id = self.playlist.playlist_id_remap[current_playlist_id_str]

  if playlist_item ~= nil and playlist_item.show_currently_playing then
    vim.defer_fn(function()
      self.playlist:update_currently_playing(
        self,
        tostring(current_playlist_id_str)
      )
    end, 0)
  elseif redirected_playlist_id ~= nil then
    vim.defer_fn(function()
      self.playlist:update_currently_playing(
        self,
        tostring(current_playlist_id_str),
        redirected_playlist_id
      )
    end, 0)
  else
    -- Coroutine invokes MpvSocket:wait_property, and therefore should not get GC'd
    coroutine.wrap(function()
      try_update_markdown(self, current_playlist_id)
    end)()
  end
end

-- If the player is in a transitioning state, save it to be called later when we get the player.
---@private
---@async
function MpvManager:_maybe_wait_transition()
  if self._transitioning_players then
    local coro = coroutine.running()
    table.insert(self._after_spawn, coro)
    coroutine.yield()
  end
end

---Rerender the player extmark to which this mpv instance corresponds
---@param force_virt_text string?
function MpvManager:draw_update(force_virt_text)
  if self.no_draw and force_virt_text == nil then
    return
  end

  -- draw_update is called asynchronously, so protect against errors from this call
  vim.defer_fn(function()
    self.playlist.extmarks:update(self.socket.data, force_virt_text)
  end, 0)
end

-- ==========================================================================
-- Convenience functions for accessing from nvim.plugin
-- ==========================================================================

---Send a command to the mpv subprocess.
---@param command any[]
function MpvManager:send_command(command)
  if self.socket == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  self.socket:send_command(command)
end

---Set a property on the mpv subprocess.
---@param property_name string
---@param value any
---@param update? boolean
---@param ignore_error? boolean
function MpvManager:set_property(property_name, value, update, ignore_error)
  if not update then update = true end
  if not ignore_error then ignore_error = false end

  if self.socket == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end
  self.socket:set_property(
      property_name, value, update, ignore_error
  )
end

---TODO: this should be callback-based instead
---Asynchronously request a property on the mpv subprocess.
---@async
---@param property_name string
---@param ignore_error? boolean
function MpvManager:wait_property(property_name, ignore_error)
  if self.socket == nil then
    vim.defer_fn(function()
      vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    end, 0)
    return
  end

  return self.socket:wait_property(property_name, ignore_error)
end

-- Map from `getcharstr()` special characters to those expected by mpv
local KEYPRESS_LOOKUP = {
    ["kl"] = "left",
    ["kr"] = "right",
    ["ku"] = "up",
    ["kd"] = "down",
    ["kb"] = "bs",
}

-- Translate a vim keypress from `getchar()` into one intelligible to mpv's keypress command.
---@param key string
---@return string?
local function translate_keypress(key)
  if key:sub(1, 1) == "\x80" then
    -- TODO: handle ctrl (\xfc\x04, then original keypress)
    -- TODO: handle alt (\xfc\x08, then original keypress)
    -- TODO: special (ctrl-right?)
    log.debug("Special key sequence found: " .. vim.inspect(key))
    return KEYPRESS_LOOKUP[key:sub(2)]
  end

  return key
end

---Send an nvim keypress and wait for its properties to be updated.
---@param count integer
---@param ignore_error? boolean
function MpvManager:send_keypress(raw_key, count, ignore_error)
  local keypress = translate_keypress(raw_key)
  count = math.max(count, 1) or 1
  if not ignore_error then ignore_error = false end

  if keypress == "q" then
    self:close()
    return
  end

  if self.socket == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  for _ = 1, count do
    self.socket:send_command({ "keypress", keypress }, nil, ignore_error)
  end

  -- some delay is necessary for the keypress to take effect
  vim.defer_fn(function()
    self.socket:fetch_subscribed()
  end, KEYPRESS_DELAY_MS)
end

---Attempt to pause/unpause the mpv subprocess.
function MpvManager:toggle_pause()
  if self.socket == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  self.socket:set_property(
    "pause", not self.socket.data.pause, true
  )
end

---Close mpv, then reopen with the same playlist and with video
---@async
function MpvManager:toggle_video()
  coroutine.wrap(function()
    if self._transitioning_players then
      vim.notify("Already attempting to show video!", vim.log.levels.ERROR, {})
      return
    end
    if self.socket == nil then
      vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
      return
    end

    local track_list = self.socket:wait_property("track-list")
    for _, track in ipairs(track_list) do
      if track.type == "video" then
        log.info("Player has video track. Cycling video instead.")
        self.socket:send_command{"cycle", "video"}
        break
      end
    end

    local current_position = self.socket:wait_property("playlist-pos")
    local current_time = self.socket:wait_property("playback-time")
    local old_playlist = self.socket.data.playlist or {}

    log.info("Beginning transition...")
    self._transitioning_players = true
    self.socket:send_command{"quit"}
    -- Draw a filler line
    self.playlist.reorder_by_index(old_playlist)
    self:draw_update()
    self.socket:next_event("close")

    log.info("Spawning player...")
    table.insert(self._mpv_args, "--video=auto")
    self:spawn()
    self._transitioning_players = false

    log.info(
      "Transition finished! Setting playlist index to %s...", current_position
    )
    self.socket:send_command{"playlist-play-index", current_position}
    self.socket:get_property("playlist")

    log.info("Waiting for file to be loaded...")
    self.socket:next_event("file-loaded")

    log.info("File loaded! Seeking...")
    self.socket:send_command{"seek", current_time}
  end)()
end

---Set the current file to the mpv file specified by the extmark `playlist_item`
---@async
function MpvManager:set_current_by_playlist_extmark(extmark_id)
  coroutine.wrap(function()
    self:_maybe_wait_transition()

    if self.socket == nil then
      vim.defer_fn(function()
        vim.notify(
          "Could not set playlist index! Mpv is closed.",
          vim.log.levels.ERROR,
          {}
        )
      end, 0)
      return
    end

      self.playlist:set_current_by_playlist_extmark(self, extmark_id)
  end)()
end

--- Forward deletions to mpv
function MpvManager:forward_deletions(removed_items)
  coroutine.wrap(function()
    self:_maybe_wait_transition()

    if self.socket == nil then
      vim.defer_fn(function()
        vim.notify(
          "Could not forward deletions! Mpv is closed.",
          vim.log.levels.ERROR,
          {}
        )
      end, 0)
      return
    end

    self.playlist:forward_deletions(self, removed_items)
  end)()
end

-- Defer to the plugin to remove the extmarks
function MpvManager:close()
  coroutine.wrap(function()
    local no_destroy_extmarks = self._transitioning_players
    self:_maybe_wait_transition()

    if self.socket ~= nil then
      self.socket:send_command{"quit"}  -- just in case
    end

    if not no_destroy_extmarks then
      vim.defer_fn(function()
        player_registry.deregister(self)
      end, 0)
    end
  end)()
end

return MpvManager
