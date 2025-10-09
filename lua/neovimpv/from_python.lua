local player_registry = require("neovimpv.players")
local MpvManager = require("neovimpv.mpv.manager")
local MpvPlaylist = require("neovimpv.mpv.playlist")
local util = require("neovimpv.mpv.util")
local config = require("neovimpv.config")
local log = require("neovimpv.mpv.log")

local list_contains = vim.list_contains
local tbl_count = vim.tbl_count

local M = {}

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


---Get the mpv instance on the current line of the buffer, if such an
---instance exists.
---@param buffer_id integer
---@param line integer
---@return MpvManager?
local function get_mpv_by_line(buffer_id, line)
  local player_id, _ = vim._neovimpv_callbacks.get_player_by_line(
    buffer_id, line, line, true
  )
  if not player_id then return nil end

  return player_registry.get(tostring(buffer_id), tostring(player_id))
end


-- Create a MpvManager instance from line data and ranges from the vim.
-- This also spawns a task for creating an mpv subprocess and opening a communication channel.
---@param line_data string[]
---@param start_line integer
---@param end_line integer
---@param extra_args string[]?
---@param ignore_mode boolean?
---@return MpvManager?
local function create_managed_mpv(
    line_data,
    start_line,
    end_line,
    extra_args,
    ignore_mode
)
  local current_buffer = vim.fn.bufnr()
  local current_filetype = vim.bo.filetype

  if start_line == end_line and get_mpv_by_line(current_buffer, start_line) then
    vim.notify("Mpv is already open on this line!", vim.log.levels.ERROR, {})
    return nil
  end

  local local_args = util.parse_mpvopen_args(extra_args or {})

  local success, maybe_playlist, maybe_player_id = pcall(function()
    return MpvPlaylist.new(
      current_buffer,
      line_data,
      start_line,
      end_line,
      ignore_mode and "ignore" or local_args.visual,
      list_contains(config.markdown_writable, current_filetype)
    )
  end)

  if not success then
    vim.notify(maybe_playlist --[[@as string]], vim.log.levels.ERROR, {})
    return
  end

  ---@cast maybe_playlist MpvPlaylist
  ---@cast maybe_player_id integer

  -- Update actions and "smart youtube"-ness
  local update_action = config.on_playlist_update
  local playlist_length = tbl_count(maybe_playlist.playlist_id_to_item)
  if playlist_length == 1 then
    if config.smart_youtube then
      update_action = util.try_smart_youtube(maybe_playlist.playlist_id_to_item[1].filename)
    end
  elseif local_args.update_action == "new_one" then
    vim.notify(
      "Cannot create new buffer for playlist of initial size 1!",
      vim.log.levels.ERROR,
      {}
    )
    return
  end

  update_action = local_args.update_action or update_action

  local target = MpvManager.new(
      current_buffer,
      maybe_player_id,
      maybe_playlist,
      update_action,
      local_args.mpv_args
  ):spawn()

  player_registry.register(target)
  return target
end

---Command builder for `:MpvAction [all|buffer|buffnr]`-style commands
---@param args string[]
---@param line integer
---@param callback fun(managers: MpvManager[])
local function do_managers(args, line, callback)
  if #args ~= 0 and args[1] == "all" or args[1] == "buffer" then
    local targets = player_registry.query_mpvs(args[1])
    callback(targets)
    return
  end

  local target = get_mpv_by_line(vim.fn.bufnr(), line)
  if target then
    callback{ target }
  end
end

function M.setup_commands()
  vim.api.nvim_create_user_command("MpvOpen", function(a)
    -- TODO: lexical shell parsing
    -- local args = shlex.split(a.args)

    create_managed_mpv(
      vim.fn.getline(a.line1, a.line2) --[[@as string[] ]],
      a.line1,
      a.line2,
      args or {}
    )
  end, { nargs = "*", range = true})

  vim.api.nvim_create_user_command("MpvNewAtLine", function(a)
    -- TODO: lexical shell parsing
    -- local args = shlex.split(a.args)

    create_managed_mpv(
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
      vim.notify("Expected 1 argument, got " .. #a.fargs, vim.log.levels.ERROR, {})
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

-- Send keypress to the mpv instance
---@param extmark_id integer
---@param key string
---@param count? integer
function M.mpv_send_keypress(extmark_id, key, count)
  local target = player_registry.get(tostring(vim.fn.bufnr()), tostring(extmark_id))
  if target then
    local real_key = translate_keypress(key)
    target:send_keypress(real_key, nil, count and math.max(count, 1) or 1)
  end
end

return M
