-- mpv/socket.lua
-- Object-oriented interface to the mpv IPC socket

local log = require("neovimpv.log").new(true)

local list_extend = vim.list_extend
local list_slice = vim.list_slice
local json_encode = (vim.json or {}).encode or vim.fn.json_encode
local json_decode = (vim.json or {}).decode or vim.fn.json_decode
local split = vim.split
local trim = vim.trim
local uv = vim.uv or vim.loop

local MPV_SET = 0
local MPV_GET = 1

---@alias MpvRequestId integer Aliased request ID, for use as a key in tables
---@alias MpvWaitingProperties [integer, string, thread]
--- 3-tuple of:
--- - whether we retrieved a property or set one,
--- - the property name, and
--- - a coroutine to resume when we have a property value

---@class MpvPlaylistIds
---@field playlist_entry_id integer
---@field playlist_insert_id integer
---@field playlist_insert_num_entries integer

---@alias MpvEventCallback fun(this: MpvSocket, json_data: table<string, any>)

---@class MpvSocket
---@field transport UVPipe?
---@field data table<string, any>
---@field _properties table<string, integer> Table of property names to request IDs.
---@field _reverse_properties table<MpvRequestId, string> Table of request ids to property names
---@field _last_property integer Last-used property ID.
---Table containing handlers for mpv events.
---Events are invoked with the socket instance and the event JSON from mpv.
---@field _event_handlers table<string, MpvEventCallback[]>
---Map from request IDs of properties we're waiting for to MpvWaitingProperties.
---@field _waiting_properties table<MpvRequestId, MpvWaitingProperties>
---Map from request IDs to whether errors should be ignored for that ID.
---@field _ignore_errors table<MpvRequestId, boolean>
---Map from event names to coroutines waiting to be resumed when the event occurs.
---@field _waiting_events table<string, thread[]>
---Request ID of the playlist request.
---@field _playlist_request integer
---Temporary buffer for new playlist lengths and IDs inside mpv during transitions.
---@field playlist_new MpvPlaylistIds?
---Temporary `playlist_entry_id`, remembered when files are loaded by mpv.
---@field last_playlist_entry_id integer
---Protocol and storage for interacting with a mpv instance's IPC.
---Supports event callbacks with signature (protocol, data) which can be added with `add_event`.
local MpvSocket = {}
MpvSocket.__index = MpvSocket


--  ___     _          _         __  __     _   _            _
-- | _ \_ _(_)_ ____ _| |_ ___  |  \/  |___| |_| |_  ___  __| |___
-- |  _/ '_| \ V / _` |  _/ -_) | |\/| / -_)  _| ' \/ _ \/ _` (_-<
-- |_| |_| |_|\_/\__,_|\__\___| |_|  |_\___|\__|_||_\___/\__,_/__/
--
-- Private methods

---@param self MpvSocket
---@param event_name string
---@param json_data table<string, any>
local function try_handle_event(self, event_name, json_data)
  for _, handler in ipairs(self._event_handlers[event_name] or {}) do
    handler(self, json_data)
  end
  -- set futures
  for _, future in ipairs(self._waiting_events[event_name] or {}) do
    log:log{
      event_name = event_name,
      future = future,
      status = coroutine.status(future),
    }
    if not coroutine.status(future) == "suspended" then
      coroutine.resume(future, true)
    end
  end
  self._waiting_events[event_name] = {}

  if event_name ~= "property-change" then
    log:log{
      "Received event",
      [event_name] = json_data,
    }
  end
end

---Split out received data into individual JSONs and send to storage
---@param self MpvSocket
---@param data string
local function data_received(self, data)
  for _, json_datum in ipairs(split(data, "\n")) do
    if trim(json_datum):len() == 0 then
      goto continue
    end
    -- parse response
    local datum = json_decode(json_datum)
    local request_id = datum.request_id
    local consumed_error = false
    -- pop request id from error list
    if self._ignore_errors[request_id] then
      self._ignore_errors[request_id] = nil
      consumed_error = true
    end

    local event_name = datum.event
    -- handle response
    if datum.error ~= nil and datum.error ~= "success" then
      if consumed_error then
        log:log{"Ignoring errorful response", datum = datum}
        goto continue
      end
      -- reverse lookup the property name for convenience
      local property_name = self._reverse_properties[request_id]
      if property_name ~= nil then
        datum["property-name"] = property_name
      end
      try_handle_event(self, "error", datum)
    elseif event_name ~= nil then
      try_handle_event(self, event_name, datum)
    elseif request_id ~= nil and self._reverse_properties[request_id] ~= nil then
      -- reverse lookup the property name for convenience
      local property_name = self._reverse_properties[request_id]
      self.data[property_name] = datum.data
      log:log{"Got property", [property_name] = datum}
    elseif request_id ~= nil and request_id == self._playlist_request then
      try_handle_event(
        self,
        "got-playlist",
        {
          playlist = datum.data,
          new = self.playlist_new,
        }
      )
      self._playlist_request = -1
      self.playlist_new = nil
    elseif request_id ~= nil and self._waiting_properties[request_id] ~= nil then
      -- we received a message about something we're waiting for
      local type_, property_name, future = unpack(self._waiting_properties[request_id])
      self._waiting_properties[request_id] = nil

      if type_ == MPV_GET then
        self.data[property_name] = datum["data"]
        log:log{"Got awaited property", [property_name] = datum}
        coroutine.resume(future, datum["data"])
      elseif type_ == MPV_SET then
        self.data[property_name] = future
        log:log{"Successfully set property", [property_name] = datum}
      end
    else
      log:log{"Unknown data received from mpv", datum = datum}
    end
    ::continue::
  end
end

---Keep records of which properties we've sent before and decided on an ID for.
---@param self MpvSocket
---@param property_name string
local function property_id(self, property_name)
  local prop_id = self._properties[property_name] or self._last_property
  if prop_id == self._last_property then
    self._properties[property_name] = prop_id
    self._reverse_properties[prop_id] = property_name
    self._last_property = self._last_property + 1
  end
  return prop_id
end


---Handler for mpv "property-change" events.
---@param self MpvSocket
---@param json_data table<string, any>
local function property_change(self, json_data)
  local property_name = self._reverse_properties[json_data.id]
  local data = json_data.data
  if property_name ~= nil then
      self.data[property_name] = data
  end
end


---Remember the last playlist_entry_id for when the file gets loaded.
---@param self MpvSocket
---@param json_data table<string, any>
local function remember_playlist_id(self, json_data)
  self.last_playlist_entry_id = json_data["playlist_entry_id"] or -1
end

---Handler for file-close events with reason redirect.
---@param self MpvSocket
---@param json_data table<string, any>
local function try_playlist(self, json_data)
  if json_data.reason ~= "redirect" then
    return
  end
  self._playlist_request = self._last_property
  self.playlist_new = {
    playlist_entry_id = json_data["playlist_entry_id"],
    playlist_insert_id = json_data["playlist_insert_id"],
    playlist_insert_num_entries = json_data["playlist_insert_num_entries"],
  }
  self:get_property("playlist", self._playlist_request)
  self._last_property = self._last_property + 1
  try_handle_event(self, "pre-got-playlist", {})
end


--  ___      _    _ _      __  __     _   _            _
-- | _ \_  _| |__| (_)__  |  \/  |___| |_| |_  ___  __| |___
-- |  _/ || | '_ \ | / _| | |\/| / -_)  _| ' \/ _ \/ _` (_-<
-- |_|  \_,_|_.__/_|_\__| |_|  |_\___|\__|_||_\___/\__,_/__/
--
-- Public Methods

---Add event handler. All mpv event names are valid, as are "connected", "close", and "error"
---@param event_name string
---@param callback MpvEventCallback
function MpvSocket:add_event(event_name, callback)
  if self._event_handlers[event_name] == nil then
    self._event_handlers[event_name] = {}
  end
  table.insert(self._event_handlers[event_name], callback)
  return callback
end

---Write a command to the socket
---@param args any[]
---@param request_id? integer
---@param ignore_error? boolean
function MpvSocket:send_command(args, request_id, ignore_error)
  ---@diagnostic disable-next-line
  if self.transport == nil or self.transport:is_closing() then
    return
  end

  local command = {
    command = args,
    request_id = request_id or 0,
  }
  if ignore_error then
    self._ignore_errors[request_id] = true
  end

  log:log{"Sent command", command = command}
  self.transport:write(json_encode(command) .. "\n")
end


---Send a command to retrieve a property from the mpv instance.
---Note that this does NOT return the property!
---@param property_name string
---@param request_id integer?
---@param ignore_error boolean?
function MpvSocket:get_property(property_name, request_id, ignore_error)
  if request_id == nil then
    request_id = property_id(self, property_name)
  end
  self:send_command(
      { "get_property", property_name },
      request_id,
      ignore_error
  )
end

---Request property `property_name` and wait for the response from mpv.
---@async
---@param property_name string
---@param ignore_error boolean?
function MpvSocket:wait_property(property_name, ignore_error)
    self._waiting_properties[self._last_property] = {
        MPV_GET,
        property_name,
        coroutine.running(),
    }

    self:get_property(
      property_name,
      self._last_property,
      ignore_error
    )
    self._last_property = self._last_property + 1
    return coroutine.yield()
end

---Wait for the next event which happens with name `event_name`.
---@async
---@param event_name string
function MpvSocket:next_event(event_name)
  if self._waiting_events[event_name] == nil then
    self._waiting_events[event_name] = {}
  end

  local coro = coroutine.running()
  table.insert(self._waiting_events[event_name], coro)
  return coroutine.yield()
end



---Fetch all properties we've sent a request for, if we've gotten desynced
function MpvSocket:fetch_subscribed()
  for prop, _ in pairs(self._properties) do
    self:get_property(prop, nil, true)
  end
end


---Send a command to set a property on the mpv instance.
---@param property_name string
---@param value any
---@param no_update boolean?
---@param ignore_error boolean?
function MpvSocket:set_property(property_name, value, no_update, ignore_error)
  if no_update then
    self:send_command(
      {"set_property", property_name, value},
      nil,
      ignore_error
    )
    return
  end

  self._waiting_properties[self._last_property] = {MPV_SET, property_name, value}
  self:send_command(
      {"set_property", property_name, value},
      self._last_property,
      ignore_error
  )
  self._last_property = self._last_property + 1
end


---Send a command to observe a property from the mpv instance.
---The value in self.data will be updated on "property-change" events.
---@param property_name string
---@param ignore_error? boolean
function MpvSocket:observe_property(property_name, ignore_error)
  self:send_command(
    {
      "observe_property",
      property_id(self, property_name),
      property_name,
    },
    nil,
    ignore_error
  )
end


---Create a new socket listening to the Unix-domain socket at `socket_file`.
---Does not return the socket.
---Instead, a callback function should be provided as the second argument,
---which is called with two arguments: a boolean indicating connection success
---and either the created socket or a string describing the error.
---@param socket_file string
---@param callback fun(success: boolean, socket_or_msg: MpvSocket | string)
function MpvSocket.new(socket_file, callback)
  local this = {
    data = {},
    --
    _properties = {},
    _reverse_properties = {},
    _last_property = 20,
    -- events and async support
    _event_handlers = {},
    _waiting_properties = {},
    _ignore_errors = {},
    _waiting_events = {},
    -- playlist support
    _playlist_request = -1,
    playlist_new = nil,
    last_playlist_entry_id = -1,
  }
  setmetatable(this, MpvSocket)

  this:add_event("property-change", property_change)
  this:add_event("start-file", remember_playlist_id)
  this:add_event("end-file", try_playlist)

  ---@diagnostic disable-next-line
  local pipe = uv.new_pipe(true)
  pipe:connect(socket_file, function(err)
    if err then
      if callback then callback(false, "Failed to connect to mpv") end
      return
    end

    this.transport = pipe
    try_handle_event(this, "connected", {})

    pipe:read_start(function(pipe_err, chunk)
      if pipe_err == nil and chunk ~= nil then
        data_received(this, chunk)
      else
        -- Process communication closed. Call close event.
        try_handle_event(this, "close", {})
        -- All coroutines should GC automatically
        -- for _, prop in pairs(self._waiting_properties) do
        --   coroutine.close(prop[3])
        -- end
        -- for _, event in pairs(self._waiting_events) do
        --   for _, future in ipairs(event) do
        --     coroutine.close(future)
        --   end
        -- end
      end
    end)

    if callback then callback(true, this) end
  end)

  return this
end

---Create a mpv subprocess with an IPC server and wrap its socket in an `MpvSocket` object.
---Does not return the socket.
---Instead, a callback function should be provided as the second argument,
---which is called with two arguments: a boolean indicating connection success
---and either the created socket or a string describing the error.
---@param mpv_args string[]
---@param ipc_path string
---@param read_timeout_ms? integer
---@param callback fun(success: boolean, socket_or_msg: MpvSocket | string)
function MpvSocket.spawn_new(mpv_args, ipc_path, read_timeout_ms, callback)
  if read_timeout_ms == nil then read_timeout_ms = 1000 end

  ---@diagnostic disable-next-line
  local stdout = uv.new_pipe(true)
  ---@diagnostic disable-next-line
  uv.spawn("mpv", {
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
      callback(false, "Mpv terminated early!")
      return
    end

    local did_callback = false
    MpvSocket.new(ipc_path, function(success, mpv_socket)
      did_callback = true
      callback(success, mpv_socket)
    end)

    vim.defer_fn(function()
      if not did_callback then
        callback(false, "Timed out connecting to protocol!")
      end
    end, read_timeout_ms)
  end, read_timeout_ms)
end

return MpvSocket
