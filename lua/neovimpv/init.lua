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
local mpv = require "neovimpv.mpv"
local helpers = require "neovimpv.helpers"

local neovimpv = {
  formatting = formatting,
  config = config, -- Temporary
  paste_and_play = actions.paste_and_play,
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

  local target = registry.get_player_by_line(vim.fn.bufnr(), line)
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

    local local_args = helpers.parse_mpvopen_args(a.fargs or {})

    local lines_to_links = helpers.multi_line(
      vim.fn.getline(a.line1, a.line2) --[[@as string[] ]],
      a.line1,
      nil,
      a.line2,
      nil,
      "vline"
    )

    mpv.new(vim.fn.bufnr(), lines_to_links, local_args)
  end, { nargs = "*", range = true})

  -- vim.api.nvim_create_user_command("MpvNewAtLine", function(a)
  --   -- TODO: lexical shell parsing
  --   -- local args = shlex.split(a.args)
  --
  --   mpv.new_from_buffer(
  --     vim.fn.bufnr(),
  --     { "" },
  --     a.line1,
  --     a.line2,
  --     helpers.parse_mpvopen_args(a.fargs or {})
  --   )
  -- end, { nargs = "*", range = true})

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
    local target = registry.get_player_by_line(vim.fn.bufnr(), a.line1)
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
    local target = registry.get_player_by_line(vim.fn.bufnr(), a.line1)
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
    local target = registry.get_player_by_line(vim.fn.bufnr(), a.line1)
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
