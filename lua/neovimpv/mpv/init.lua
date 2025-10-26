local config = require "neovimpv.config"
local Formatter = require "neovimpv.formatting"
local registry = require "neovimpv.mpv.registry"
local MpvManager = require "neovimpv.mpv.manager"
local MpvCallbacks = require "neovimpv.mpv.callbacks"

local tbl_count = vim.tbl_count
local tbl_keys = vim.tbl_keys

local M = {}

---@alias MpvOpenLines table<LineNumber, [string[], boolean]>

-- Create a MpvManager instance from line data and ranges from nvim
-- This also spawns a task for creating an mpv subprocess and opening a communication channel.
---@param buffer_id BufferId
---@param lines_to_links MpvOpenLines
---@param local_args MpvLocalArgs
---@param formatter? Formatter
---@return MpvManager?
function M.new(
  buffer_id,
  lines_to_links,
  local_args,
  formatter
)
  -- Update actions and "smart youtube"-ness
  local update_action = local_args.update_action or config.on_playlist_update
  local multiple_lines = tbl_count(lines_to_links)

  local success, maybe_buffer_actions = pcall(function()

    if tbl_count(lines_to_links) == 0 then
      error(
        "Cannot open mpv: no file paths or URLs found",
        0
      )
    end

    if registry.get_player_by_line(buffer_id, tbl_keys(lines_to_links)) then
      error(
        "Mpv is already open on"
        .. (multiple_lines and "one of these lines!" or "this line!"),
        0
      )
    end

    return MpvCallbacks.new(
      buffer_id,
      lines_to_links,
      update_action,
      formatter or Formatter.new(config.format, config.style)
    )
  end)

  if not success then
    vim.notify(maybe_buffer_actions --[[@as string]], vim.log.levels.ERROR, {})
    return
  end

  ---@cast maybe_buffer_actions MpvCallbacks

  -- "Cook" local arguments into actual command-line arguments
  local mpv_args = local_args.mpv_args or {}
  local is_video = local_args.is_video
  if is_video ~= nil then
    local i = 1
    while i <= #mpv_args do
      local arg = mpv_args[i]
      if arg:find("^--vid") or arg == "--no-video" then
        table.remove(mpv_args, i)
      else
        i = i + 1
      end
    end
    table.insert(mpv_args, is_video and "--video=auto" or "--no-video")
  end

  local target = MpvManager.new(
    maybe_buffer_actions,
    mpv_args
  ):spawn()

  registry.register(target)
  return target
end

return M
