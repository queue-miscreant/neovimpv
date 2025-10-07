
local util = require("neovimpv.mpv.util")

local M = {
  _mpv_instances = {},
}

---Interpret each item in `args` as a JSON string.
---In other words, convert quoted strings to strings and digit literals to numbers.
---@param args string[]
local function try_json(args)
  local command = {}
  for _, arg in ipairs(args) do
    local success, val = pcall(vim.fn.json_decode, arg)
    table.insert(command, success and val or arg)
  end
  return command
end

---Get mpv instances that we currently know about for a given buffer
---@return MpvManager[]
local function get_mpvs_in_buffer(buffer)
  local matches = {}
  for key, mpv_instance in pairs(M._mpv_instances) do
    if key:find(buffer .. "%.") then
      table.insert(matches, mpv_instance)
    end
  end
  return matches
end

---Interpret a string `arg` as either a buffer number or 'all'.
---Return mpv instances in the buffer, or all of them.
---@param arg string
---@return MpvManager[]
local function query_mpvs(arg)
  if arg == "all" then
    return M._mpv_instances.values()
  end
  local buffnum = tonumber(arg)

  return buffnum and get_mpvs_in_buffer(buffnum or vim.fn.bufnr()) or {}
end


---Get the mpv instance on the current line of the buffer, if such an
---instance exists.
---@param buffer integer
---@param line integer
---@return MpvManager?
local function get_mpv_by_line(buffer, line)
  local player_id, _ = vim._neovimpv_callbacks.get_player_by_line(
    buffer, line, line, true
  )
  if not player_id then return nil end

  return M._mpv_instances[tostring(buffer) .. "." .. tostring(player_id)]
end

---Create an MpvManager and register it in `_mpv_instances`
---@param lines string[]
---@param start integer
---@param end_ integer
---@param args string[]
---@param ignore_mode? boolean
local function create_mpv_instance(lines, start, end_, args, ignore_mode)
  if start == end_ and get_mpv_by_line(vim.fn.bufnr(), start) then
    vim.notify("Mpv is already open on this line!", vim.log.levels.ERROR, {})
    return
  end

  local target = util.create_managed_mpv(lines, start, end_, args, ignore_mode or false)
  if target == nil  then
    return
  end

  M._mpv_instances[tostring(target.buffer) .. "." .. tostring(target.id)] = target
end

---Command builder for `:MpvAction [all|buffer|buffnr]`-style commands
---@param args string[]
---@param line integer
---@param callback fun(managers: MpvManager[])
local function do_managers(args, line, callback)
  if #args ~= 0 and args[1] == "all" then
    local targets = query_mpvs(args[0]) --[[@as MpvManager[] ]]
    callback(targets)
    return
  end

  local target = get_mpv_by_line(vim.fn.bufnr(), line)
  if target then
    callback{ target }
  end
end

local function setup_commands()
  -- TODO
  vim.api.nvim_create_user_command("MpvOpen", function(a)
    -- local args = shlex.split(a.args)

    create_mpv_instance(
      vim.fn.getline(a.line1, a.line2) --[[@as string[] ]],
      a.line1,
      a.line2,
      args or {}
    )
  end, { nargs = "*", range = true})

  -- TODO
  vim.api.nvim_create_user_command("MpvNewAtLine", function(a)
    -- local args = shlex.split(a.args)

    create_mpv_instance(
      { "" },
      a.line1,
      a.line2,
      args or {}
    )
  end, { nargs = "*", range = true})

  -- TODO
  vim.api.nvim_create_user_command("MpvPause", function(a)
    do_managers(a.fargs, a.line1, function(managers)
      if #managers == 1 then
        managers[1]:toggle_pause()
        return
      end

      for _, target in ipairs(managers) do
        target:set_property("pause", true)
      end
    end)
  end, {
    nargs = "?",
    range = true,
    complete="customlist,neovimpv#complete#mpv_close_pause",
  })

  vim.api.nvim_create_user_command("MpvClose", function(a)
    do_managers(a.fargs, a.line1, function(managers)
      for _, target in ipairs(managers) do
        target:close()
      end
    end)
  end, {
    nargs = "?",
    range = true,
    complete="customlist,neovimpv#complete#mpv_close_pause",
  })

  vim.api.nvim_create_user_command("MpvSetProperty", function(a)
    local target = get_mpv_by_line(vim.fn.bufnr(), a.line1)
    if target then
      local args = try_json(a.fargs)
      target:set_property(args[1], args[2])
    end
  end, {
    nargs = "+",
    range = true,
    complete = "customlist,neovimpv#complete#mpv_set_property",
  })

  vim.api.nvim_create_user_command("MpvGetProperty", function(a)
    if #a.fargs ~= 1 then
      vim.notify(f"Expected 1 argument, got " .. #a.fargs, vim.log.levels.ERROR, {})
    end

    local property_name = a.fargs[1]
    local target = get_mpv_by_line(vim.fn.bufnr(), a.line1)
    if target == nil then return end

    coroutine.wrap(function()
      local result = target:wait_property(property_name)
      vim.defer_fn(function()
        vim.notify(vim.inspect(result))
      end, 0)
    end)()
  end, {
    nargs = 1,
    range = true,
    complete = "customlist,neovimpv#complete#mpv_get_property",
  })

  vim.api.nvim_create_user_command("MpvSend", function(a)
    local target = get_mpv_by_line(vim.fn.bufnr(), a.line1)
    if target then
      target:send_command(try_json(a.fargs))
    end
  end, {
    nargs = "+",
    range = true,
    complete = "customlist,neovimpv#complete#mpv_command",
  })

  -- TODO
  --[[
    @pynvim.function("MpvSendNvimKeys", sync=True)
    def mpv_send_keypress(self, args):
        """Send keypress to the mpv instance"""
        if len(args) == 3:
            extmark_id, key, count = args
        else:
            raise TypeError(f"Expected 3 arguments, got {len(args)}")
        log.debug(
            "Received keypress: %s\n"
            "Sending to buffer %s.%s\n"
            "mpv_instances: %s",  # pylint: disable=implicit-str-concat
            repr(key),
            self.nvim.current.buffer.number,
            extmark_id,
            self._mpv_instances,
        )
        if target := self._mpv_instances.get(
            (self.nvim.current.buffer.number, extmark_id)
        ):
            real_key = translate_keypress(key)

            self.nvim.loop.create_task(target.send_keypress(real_key, count=count or 1))
  ]]

  -- TODO
  --[[
    @pynvim.function("MpvSetPlaylist", sync=True)
    def mpv_set_playlist(self, args):
        """Set currently playing item"""
        if len(args) == 2:
            player, playlist_item = args
        else:
            raise TypeError(f"Expected 2 arguments, got {len(args)}")

        mpv_instance = self._mpv_instances.get(
            (self.nvim.current.buffer.number, int(player))
        )
        if mpv_instance is not None:
            self.nvim.loop.create_task(
                mpv_instance.set_current_by_playlist_extmark(playlist_item)
            )
  ]]

  -- TODO
  --[[
    @pynvim.function("MpvForwardDeletions", sync=True)
    def mpv_forward_deletions(self, args):
        """Receive updated playlist extmark positions from nvim"""
        if len(args) == 1:
            (updated_playlists,) = args
        else:
            raise TypeError(f"Expected 1 argument, got {len(args)}")

        for player, removed_items in updated_playlists.items():
            mpv_instance = self._mpv_instances.get(
                (self.nvim.current.buffer.number, int(player))
            )
            if mpv_instance is not None:
                self.nvim.loop.create_task(
                    mpv_instance.forward_deletions(removed_items)
                )
  ]]

  -- TODO
  --[[
    @pynvim.function("MpvToggleVideo", sync=True)
    def mpv_toggle_video(self, args):
        """Turn an audio player into a video player and vice-versa"""
        if len(args) == 1:
            (player,) = args
        else:
            raise TypeError(f"Expected 1 argument, got {len(args)}")

        mpv_instance = self._mpv_instances.get(
            (self.nvim.current.buffer.number, int(player))
        )
        if mpv_instance is not None:
            self.nvim.loop.create_task(mpv_instance.toggle_video())
  ]]
end

return setup_commands
