local config = require "neovimpv.config"
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
---@return MpvManager?
function M.new(
  buffer_id,
  lines_to_links,
  local_args
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

    return MpvCallbacks.new(buffer_id, lines_to_links, update_action)
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

return M
