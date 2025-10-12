-- mpv/manager.lua
-- A container class for forwarding plugin commands to the correct MpvSocket
--
-- TODO: this interface should focus on being a generically spawnable
-- interface to mpv which the rest of the plugin can access consistently via its methods.
-- Buffer interactions should be done with a manager (e.g., `MpvPlaylist`) rather than being done ad-hoc here

local config = require("neovimpv.config")
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
  log.log{ "Error occurred", error = err }
end

---@class MpvManager
---@field socket MpvSocket?
---@field buffer_actions MpvBufferTracker
---@field _mpv_args string[]
---@field _after_spawn thread[]
---@field _transitioning_players boolean
---Manager for an mpv instance, containing options and arguments particular to it.
---TODO: transitioning_players unneeded with merged sockets?
local MpvManager = {}
MpvManager.__index = MpvManager

---@param buffer_actions MpvBufferTracker
---@param mpv_args string[]
---@return MpvManager
function MpvManager.new(buffer_actions, mpv_args)
  mpv_args = list_extend(list_slice(config.default_args), mpv_args)

  local ret = {
    buffer_actions = buffer_actions,
    socket = nil,
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

  local extmarks = self.buffer_actions.extmarks
  local ipc_path = fs_join(
    mpv_socket_dir,
    ("%d.%d"):format(extmarks.buffer_id, extmarks.player_id)
  )

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

      log.log{"Spawned mpv!", args = self._mpv_args}
      ---@cast mpv_socket MpvSocket
      self.socket = mpv_socket

      -- default event handling
      mpv_socket:add_event("error", show_error)
      mpv_socket:add_event("end-file", function(_, arg)
        self.buffer_actions:on_end_file(self.socket, arg)
      end)
      mpv_socket:add_event("start-file", function(_, data)
        self.buffer_actions:on_start_file(self.socket, data)
      end)
      mpv_socket:add_event("file-loaded", function(_, _)
        self.buffer_actions:on_file_loaded(self.socket)
      end)
      mpv_socket:add_event("close", function(_, _)
        self:close()
      end)
      mpv_socket:add_event("property-change", function(_, _)
        self.buffer_actions:draw_update(self.socket.data)
      end)
      mpv_socket:add_event("got-playlist", function(_, data)
        local old_extmarks = self.buffer_actions.extmarks
        self.buffer_actions:update_playlist(data, function()
          player_registry.reregister(self, old_extmarks)
        end)
      end)

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

      local playlist = self.buffer_actions.playlist_id_to_item or {}
      log.log{"Loading playlist!", playlist = playlist}

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

-- ==========================================================================
-- Convenience methods for interacting with the rest of the plugin
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
    return KEYPRESS_LOOKUP[key:sub(2)]
  end

  return key
end

---Send an nvim keypress and wait for its properties to be updated.
---@param count? integer
---@param ignore_error? boolean
function MpvManager:send_keypress(raw_key, count, ignore_error)
  local keypress = translate_keypress(raw_key)
  count = math.max(count or 1, 1)

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
        log.log{"Player has video track. Cycling video instead."}
        self.socket:send_command{"cycle", "video"}
        break
      end
    end

    local current_position = self.socket:wait_property("playlist-pos")
    local current_time = self.socket:wait_property("playback-time")
    local old_playlist = self.socket.data.playlist or {}

    log.log{"Beginning transition..."}
    self._transitioning_players = true
    self.socket:send_command{"quit"}
    -- Draw a filler line
    self.buffer_actions:reorder_by_index(old_playlist)
    self.buffer_actions:draw_update(self)
    self.socket:next_event("close")

    log.log{"Spawning player..."}
    table.insert(self._mpv_args, "--video=auto")
    self:spawn()
    self._transitioning_players = false

    log.log{
      "Transition finished!",
      new_playlist_index = current_position
    }
    self.socket:send_command{"playlist-play-index", current_position}
    self.socket:get_property("playlist")

    log.log{"Waiting for file to be loaded..."}
    self.socket:next_event("file-loaded")

    log.log{"File loaded! Seeking..."}
    self.socket:send_command{"seek", current_time}
  end)()
end

---Set the current file to the mpv file specified by the extmark `playlist_item`
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

    self.buffer_actions:set_current_by_playlist_extmark(self.socket, extmark_id)
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

    self.buffer_actions:forward_deletions(self.socket, removed_items)
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
