local config = require "neovimpv.config"
local helpers = require "neovimpv.helpers"
local registry = require "neovimpv.mpv.registry"
local MpvManager = require "neovimpv.mpv.manager"
local MpvCallbacks = require "neovimpv.mpv.callbacks"

local tbl_count = vim.tbl_count

local M = {}

-- Create a MpvManager instance from line data and ranges from nvim
-- This also spawns a task for creating an mpv subprocess and opening a communication channel.
---@param line_data string[]
---@param start_line integer
---@param end_line integer
---@param local_args MpvLocalArgs
---@param ignore_mode? boolean
---@return MpvManager?
function M.new_from_buffer(
  buffer_id,
  line_data,
  start_line,
  end_line,
  local_args,
  ignore_mode
)
  -- Update actions and "smart youtube"-ness
  local update_action = local_args.update_action or config.on_playlist_update

  local success, maybe_buffer_actions = pcall(function()

    if
      start_line == end_line
      and registry.get_player_by_line(buffer_id, start_line)
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
