local player_registry = require("neovimpv.players")
local MpvManager = require("neovimpv.mpv.manager")
local MpvPlaylist = require("neovimpv.mpv.playlist")
local util = require("neovimpv.mpv.util")
local config = require("neovimpv.config")
local log = require("neovimpv.mpv.log")

local get_mpv_by_line = player_registry.get_player_by_line
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
  local local_args = util.parse_mpvopen_args(extra_args or {})

  local success, maybe_playlist = pcall(function()

    if
      start_line == end_line
      and get_mpv_by_line(current_buffer, start_line)
    then
      error("Mpv is already open on this line!")
    end

    local lines_to_links = util.construct_playlist_items(
      line_data,
      start_line,
      end_line,
      ignore_mode and "ignore" or local_args.visual
    )

    if tbl_count(lines_to_links) == 0 then
      error(
        (start_line == end_line and "Line does" or "Lines do")
        .. " not contain a file path or valid URL"
      )
    end

    return MpvPlaylist.new(current_buffer, lines_to_links)
  end)

  if not success then
    vim.notify(maybe_playlist --[[@as string]], vim.log.levels.ERROR, {})
    return
  end

  ---@cast maybe_playlist MpvPlaylist

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
      maybe_playlist.extmarks.player_id,
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
      if target.socket == nil then
        vim.defer_fn(function()
          vim.notify("Mpv not ready yet!", vim.log.levels.ERROR, {})
        end, 0)
        return
      end

      local result = target.socket:wait_property(property_name)
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
end

return M
