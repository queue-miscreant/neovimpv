-- mpv/manager.lua
-- A container class for forwarding plugin commands to the correct MpvSocket

local config = require("neovimpv.config")
local MpvSocket = require("neovimpv.mpv.socket")
local MpvWrapper = require("neovimpv.mpv.wrapper")
local player_registry = require("neovimpv.players")
local log = require("neovimpv.mpv.log")

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

---@class MpvManager
---Manager for an mpv instance, containing options and arguments particular to it.
---@field buffer integer
---@field id integer
---@field mpv MpvWrapper?
---@field playlist MpvPlaylist?
---@field update_action UpdateAction
---@field _mpv_args string[]
---@field _after_spawn thread[]
---@field _transitioning_players boolean
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
    playlist = playlist,
    update_action = update_action,
    mpv = nil,
    _mpv_args = list_extend(list_slice(DEFAULT_MPV_ARGS), mpv_args),
    _after_spawn = {},
    _transitioning_players = false,
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
        self.mpv = nil
      else
        log.debug("Spawned mpv with args %s", self._mpv_args)
        self.mpv = MpvWrapper.new(self, mpv_socket --[[@as MpvSocket]])
      end

      self._transitioning_players = false
      for _, coro in ipairs(self._after_spawn) do
        coroutine.resume(coro)
      end
    end
  )

  return self
end

-- If the player is in a transitioning state, save it to be called later when we get the player.
---@private
function MpvManager:_maybe_wait_transition()
  if self._transitioning_players then
    local coro = coroutine.running()
    table.insert(self._after_spawn, coro)
    coroutine.yield()
  end
end

-- ==========================================================================
-- Convenience functions for accessing from nvim.plugin
-- ==========================================================================

---Send a command to the mpv subprocess.
---@param command any[]
function MpvManager:send_command(command)
  if self.mpv == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  self.mpv.socket:send_command(command)
end

---Set a property on the mpv subprocess.
---@param property_name string
---@param value any
---@param update? boolean
---@param ignore_error? boolean
function MpvManager:set_property(property_name, value, update, ignore_error)
  if not update then update = true end
  if not ignore_error then ignore_error = false end

  if self.mpv == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end
  self.mpv.socket:set_property(
      property_name, value, update, ignore_error
  )
end

---Asynchronously request a property on the mpv subprocess.
---@async
---@param property_name string
---@param ignore_error? boolean
function MpvManager:wait_property(property_name, ignore_error)
  if self.mpv == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  return self.mpv.socket:wait_property(property_name, ignore_error)
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

  if self.mpv == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  for _ = 1, count do
    self.mpv.socket:send_command({ "keypress", keypress }, nil, ignore_error)
  end

  -- some delay is necessary for the keypress to take effect
  vim.defer_fn(function()
    self.mpv.socket:fetch_subscribed()
  end, KEYPRESS_DELAY_MS)
end

---Attempt to pause/unpause the mpv subprocess.
function MpvManager:toggle_pause()
  if self.mpv == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  self.mpv.socket:set_property(
    "pause", not self.mpv.socket.data.pause, true
  )
end

---Close mpv, then reopen with the same playlist and with video
---@async
function MpvManager:toggle_video()
  if self._transitioning_players then
    vim.notify("Already attempting to show video!", vim.log.levels.ERROR, {})
    return
  end
  if self.mpv == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  local track_list = self.mpv.socket:wait_property("track-list")
  for _, track in ipairs(track_list) do
    if track.type == "video" then
      log.info("Player has video track. Cycling video instead.")
      self.mpv.socket:send_command{"cycle", "video"}
      break
    end
  end

  local current_position = self.mpv.socket:wait_property("playlist-pos")
  local current_time = self.mpv.socket:wait_property("playback-time")
  local old_playlist = self.mpv.socket.data.playlist or {}

  log.info("Beginning transition...")
  self._transitioning_players = true
  self.mpv.socket:send_command{"quit"}
  -- Draw a filler line
  self.playlist.reorder_by_index(old_playlist)
  vim.defer_fn(function()
    self.mpv:draw_update()
  end, 0)
  self.mpv.socket:next_event("close")

  log.info("Spawning player...")
  table.insert(self._mpv_args, "--video=auto")
  self:spawn()
  self._transitioning_players = false

  log.info(
    "Transition finished! Setting playlist index to %s...", current_position
  )
  self.mpv.socket:send_command{"playlist-play-index", current_position}
  self.mpv.socket:get_property("playlist")

  log.info("Waiting for file to be loaded...")
  self.mpv.socket:next_event("file-loaded")

  log.info("File loaded! Seeking...")
  self.mpv.socket:send_command{"seek", current_time}
end

---Set the current file to the mpv file specified by the extmark `playlist_item`
---@async
function MpvManager:set_current_by_playlist_extmark(extmark_id)
  coroutine.wrap(function()
    self:_maybe_wait_transition()

    if self.mpv == nil then
      vim.defer_fn(function()
        vim.notify(
          "Could not set playlist index! Mpv is closed.",
          vim.log.levels.ERROR,
          {}
        )
      end, 0)
      return
    end

      self.playlist:set_current_by_playlist_extmark(self.mpv, extmark_id)
  end)()
end

--- Forward deletions to mpv
function MpvManager:forward_deletions(removed_items)
  coroutine.wrap(function ()
    self:_maybe_wait_transition()

    if self.mpv == nil then
      vim.defer_fn(function()
        vim.notify(
          "Could not forward deletions! Mpv is closed.",
          vim.log.levels.ERROR,
          {}
        )
      end, 0)
      return
    end

    self.playlist:forward_deletions(self.mpv, removed_items)
  end)()
end

-- Defer to the plugin to remove the extmarks
function MpvManager:close()
  coroutine.wrap(function()
    local no_destroy_extmarks = self._transitioning_players
    self:_maybe_wait_transition()

    if self.mpv ~= nil then
      self.mpv.socket:send_command{"quit"}  -- just in case
    end

    if not no_destroy_extmarks then
      vim.defer_fn(function()
        player_registry.deregister(self)
      end, 0)
    end
  end)()
end

return MpvManager
