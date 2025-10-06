-- mpv/player.lua
-- A container class for forwarding plugin commands to the correct MpvSocket
-- Also contains playlist extmark manager.

local config = require("neovimpv.config")
local MpvSocket = require("neovimpv.mpv.socket")
local MpvWrapper = require("neovimpv.mpv.wrapper")
local log = require("neovimpv.mpv.log")

local list_extend = vim.list_extend
local list_slice = vim.list_slice
local fs_join = vim.fs.joinpath or function(...) vim.fn.join({...}, "/") end


-- delay between sending a keypress to mpv and rerequesting properties
local KEYPRESS_DELAY_MS = 50
local DEFAULT_MPV_ARGS = {"--no-video"}
---@type string[]
local MPV_ARGS = {}


---@class MpvManager
---Manager for an mpv instance, containing options and arguments particular to it.
---@field buffer integer
---@field id integer
---@field mpv MpvWrapper?
---@field playlist MpvPlaylist
---@field update_action UpdateAction
---@field _mpv_args string[]
---@field _not_spawning_player nil TODO (asyncio.Event equivalent)
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

  local ret = {
    buffer = buffer,
    id = player_id,
    playlist = playlist,
    update_action = update_action,
    mpv = nil,
    _mpv_args = list_extend(list_slice(MPV_ARGS), mpv_args),
    _not_spawning_player = nil,
    _transitioning_players = false,
  }
  setmetatable(ret, MpvManager)

  return ret
end

function MpvManager.set_default_args(new_args)
  MPV_ARGS = list_extend(list_slice(DEFAULT_MPV_ARGS), new_args)
end

---Create an instance of mpv which uses MpvProtocol for IPC at the UNIX path `ipc_path`
---Returns tuple of asyncio Process and MpvProtocol in use.
---@param mpv_args string[]
---@param ipc_path string
---@param read_timeout_ms? integer
---@param callback fun(mpv_socket: MpvSocket)
local function create_mpv(mpv_args, ipc_path, read_timeout_ms, callback)
  if read_timeout_ms == nil then read_timeout_ms = 1000 end

  ---@diagnostic disable-next-line
  local stdout = vim.uv.new_pipe()
  ---@diagnostic disable-next-line
  vim.uv.spawn("mpv", {
    args = list_extend(list_slice(mpv_args), {
      "--input-ipc-server=" .. ipc_path,
      "--idle=once",
    }),
    stdio = {nil, stdout, nil},
  })

  -- timeout a read from the subprocess's stdout (for errors)
  local startup_print = false
  -- TODO: This might be wrong for libuv.
  stdout:read_start(function(_, _)
    startup_print = true
  end)

  vim.defer_fn(function()
    if startup_print then
      vim.notify("Mpv terminated early!", vim.log.levels.ERROR, {})
      return
    end

    local success = false
    MpvSocket.new(ipc_path, function(mpv_socket)
      success = true
      callback(mpv_socket)
    end)

    vim.defer_fn(function()
      if not success then
        vim.notify("Timed out connecting to protocol!", vim.log.levels.ERROR, {})
      end
    end, read_timeout_ms)
  end, read_timeout_ms)
end

---Spawn subprocess and wait `timeout_duration` seconds for error output.
---If the connection is successful, the instance's `protocol` member will be set
---to an MpvProtocol for IPC.
---@param timeout_duration_ms? integer
---@return MpvManager
function MpvManager:spawn(timeout_duration_ms)
  if not timeout_duration_ms then timeout_duration_ms = 1000 end
  -- TODO
  -- self._not_spawning_player.clear()

  local ipc_path = fs_join(config.mpv_socket_dir, tostring(self.id))
  create_mpv(
    self._mpv_args,
    ipc_path,
    timeout_duration_ms,
    function(mpv_socket)
      -- TODO: on error
      -- self._not_spawning_player.set()

      log.debug("Spawned mpv with args %s", self._mpv_args)

      self.mpv = MpvWrapper.new(self, mpv_socket)
      -- TODO
      -- self._not_spawning_player.set()
    end
  )

  return self
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

---Send a keypress and wait for its properties to be updated.
---@async
---@param ignore_error boolean?
---@param count integer?
function MpvManager:send_keypress(keypress, ignore_error, count)
  if not ignore_error then ignore_error = false end
  if not count then count = 1 end

  if keypress == "q" then
    self:close_async()
    return
  end

  if self.mpv == nil then
    vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
    return
  end

  for _ = 1, count do
    self.mpv.socket:send_command{
      "keypress", keypress, ignore_error
    }
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
  self._not_spawning_player:wait()
  if self.mpv == nil then
    vim.notify("Could not set playlist index! Mpv is closed.", vim.log.levels.ERROR, {})
    return
  end

  self.playlist:set_current_by_playlist_extmark(self.mpv, extmark_id)
end

--- Forward deletions to mpv
function MpvManager:forward_deletions(removed_items)
  self._not_spawning_player:wait()
  if self.mpv == nil then
    vim.notify("Could not forward deletions! Mpv is closed.", vim.log.levels.ERROR, {})
    return
  end

  self.playlist:forward_deletions(self.mpv, removed_items)
end

---Defer to the plugin to remove the extmark
---@param no_destroy_extmarks? boolean
---@async
function MpvManager:close_async(no_destroy_extmarks)
  self._not_spawning_player:wait()
  if self.mpv ~= nil then
    self.mpv.socket:send_command{"quit"}  -- just in case
  end

  if not no_destroy_extmarks then
    --TODO
    -- self.plugin.nvim.async_call(self.plugin.remove_mpv_instance, self)
  end
end

---Defer to the plugin to remove the extmark
function MpvManager:close()
  local no_destroy_extmarks = self._transitioning_players
  -- TODO
  -- self.plugin.nvim.loop.create_task(self:close_async(no_destroy_extmarks))
end

return MpvManager
