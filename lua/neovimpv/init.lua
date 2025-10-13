-- neovimpv
--
-- Collects all Lua functionality into a single file for import.
-- Lua functions are used to reduce IPC with for repeated editor
-- manipulations, such as setting buffer contents or getting/setting extmarks.

local config = require "neovimpv.config"
local completion = require "neovimpv.completion"
local actions = require "neovimpv.actions"
local keys = require "neovimpv.keys"
local formatting = require "neovimpv.formatting"
local youtube_push_results = require "neovimpv.youtube.push_results"
local youtube_interact = require "neovimpv.youtube.interact"
local registry = require "neovimpv.mpv.registry"
local MpvManager = require "neovimpv.mpv.manager"
local MpvCallbacks = require "neovimpv.mpv.callbacks"
local helpers = require "neovimpv.helpers"

local neovimpv = {
  formatting = formatting,
  config = config, -- Temporary
  paste_and_play = actions.paste_and_play,
}

local get_mpv_by_line = registry.get_player_by_line
local tbl_count = vim.tbl_count


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


-- Create a MpvManager instance from line data and ranges from nvim
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
  local local_args = helpers.parse_mpvopen_args(extra_args or {})

  -- Update actions and "smart youtube"-ness
  local update_action = config.on_playlist_update

  update_action = local_args.update_action or update_action

  local success, maybe_buffer_actions = pcall(function()

    if
      start_line == end_line
      and get_mpv_by_line(current_buffer, start_line)
    then
      error("Mpv is already open on this line!", 0)
    end

    local lines_to_links = helpers.construct_playlist_items(
      line_data,
      start_line,
      end_line,
      ignore_mode and "ignore" or local_args.visual
    )

    if tbl_count(lines_to_links) == 0 then
      error(
        (start_line == end_line and "Line does" or "Lines do")
        .. " not contain a file path or valid URL",
        0
      )
    end

    return MpvCallbacks.new(current_buffer, lines_to_links, update_action)
  end)

  if not success then
    vim.notify(maybe_buffer_actions --[[@as string]], vim.log.levels.ERROR, {})
    return
  end

  ---@cast maybe_buffer_actions MpvCallbacks

  local target = MpvManager.new(
      maybe_buffer_actions,
      local_args.mpv_args
  ):spawn()

  registry.register(target)
  return target
end


---Command builder for `:MpvAction [all|buffer|buffnr]`-style commands
---@param args string[]
---@param line integer
---@param callback fun(managers: MpvManager[])
local function do_managers(args, line, callback)
  if #args ~= 0 and args[1] == "all" or args[1] == "buffer" then
    local targets = registry.query_mpvs(args[1])
    callback(targets)
    return
  end

  local target = get_mpv_by_line(vim.fn.bufnr(), line)
  if target then
    callback{ target }
  end
end

function neovimpv.setup(opts)
  config.load_globals(opts)
  formatting.parse_user_settings()
  keys.bind_base()


  --    _       _                    _
  --   /_\ _  _| |_ ___  __ _ __  __| |___
  --  / _ \ || |  _/ _ \/ _| '  \/ _` (_-<
  -- /_/ \_\_,_|\__\___/\__|_|_|_\__,_/__/
  --
  -- Autocmds

  vim.api.nvim_create_augroup("MpvSmartBindings", {clear = true})
  vim.api.nvim_create_autocmd(
    "FileType",
    {
      group = "MpvSmartBindings",
      pattern = config.smart_filetypes,
      callback = function()
        keys.bind_smart_local()
      end
    }
  )
  vim.api.nvim_create_autocmd(
    "FileType",
    {
      pattern = "youtube_results",
      callback = youtube_interact.bind_buffer_results,
    }
  )
  vim.api.nvim_create_autocmd(
    "FileType",
    {
      pattern = "youtube_playlist",
      callback = youtube_interact.bind_buffer_playlist,
    }
  )

  --  _   _                ___                              _
  -- | | | |___ ___ _ _   / __|___ _ __  _ __  __ _ _ _  __| |___
  -- | |_| (_-</ -_) '_| | (__/ _ \ '  \| '  \/ _` | ' \/ _` (_-<
  --  \___//__/\___|_|    \___\___/_|_|_|_|_|_\__,_|_||_\__,_/__/
  --
  -- User Commands

  vim.api.nvim_create_user_command("MpvOpen", function(a)
    -- TODO: lexical shell parsing
    -- local args = shlex.split(a.args)

    create_managed_mpv(
      vim.fn.getline(a.line1, a.line2) --[[@as string[] ]],
      a.line1,
      a.line2,
      a.fargs or {}
    )
  end, { nargs = "*", range = true})

  vim.api.nvim_create_user_command("MpvNewAtLine", function(a)
    -- TODO: lexical shell parsing
    -- local args = shlex.split(a.args)

    create_managed_mpv(
      { "" },
      a.line1,
      a.line2,
      a.fargs or {}
    )
  end, { nargs = "*", range = true})

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
    complete = completion.mpv_close_pause,
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
    complete = completion.mpv_close_pause,
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
    complete = completion.mpv_set_property,
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
      if result == nil then return end
      vim.defer_fn(function()
        vim.notify(vim.inspect(result))
      end, 0)
    end)()
  end, {
    nargs = 1,
    range = true,
    complete = completion.mpv_get_property,
  })

  vim.api.nvim_create_user_command("MpvSend", function(a)
    local target = get_mpv_by_line(vim.fn.bufnr(), a.line1)
    if target then
      target:send_command(try_json(a.fargs))
    end
  end, {
    nargs = "+",
    range = true,
    complete = completion.mpv_command,
  })

  if vim.list_contains(config.smart_filetypes, vim.bo.filetype) then
    keys.bind_smart_local()
  end
end

-- Exposed Lua callbacks for Python
vim._neovimpv_callbacks = {
  -- youtube.py
  open_youtube_select_split = youtube_push_results.open_select_split,
  paste_youtube_result = youtube_push_results.paste_result,
  open_youtube_playlist_results = youtube_push_results.open_playlist_results,
}

return neovimpv
