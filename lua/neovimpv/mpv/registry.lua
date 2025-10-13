-- mpv/registry.lua
-- MpvManager registry

local helpers = require "neovimpv.helpers"

local list_contains = vim.list_contains
local list_slice = vim.list_slice
local list_extend = vim.list_extend

---@alias BufferId integer
---@alias ExtmarkId integer

-- The general layout of the plugin is as follows:
--
-- Registry
--  |
--  |---MpvManager
--  |   |    A wrapper object which delivers plugin commands to the correct subprocess.
--  |   |
--  |   |---MpvCallbacks
--  |   |   |    Keeps track of the relationship between mpv playlist data and buffer data.
--  |   |   |    Provides internal callbacks.
--  |   |   |
--  |   |   |---MpvExtmarks
--  |   |       Extmarks manager for the plugin, providing a "nicer" drawing/pasting interface.
--  |   |
--  |   |---MpvSocket
--  |       Interface to mpv's IPC socket, wrapping a libuv pipe.
--  |
--  |---MpvManager
--  |
--  |---MpvManager

local M = {
  ---@private
  ---@type table<BufferId, table<ExtmarkId, MpvManager>>
  _players = {},
}

---@param manager MpvManager
---@return boolean
function M.register(manager)
  local extmarks = manager.callbacks.extmarks
  local buffer_id, player_id = extmarks.buffer_id, extmarks.player_id
  local players_in_buffer = M._players[buffer_id] or {}

  if players_in_buffer[player_id] then
    vim.notify(
      "Error: buffer and extmark already correspond to a MpvManager",
      vim.log.levels.ERROR,
      {}
    )
    return false
  end
  players_in_buffer[player_id] = manager

  M._players[buffer_id] = players_in_buffer
  return true
end

-- Remove a MpvManager and clean up its extmarks
---@param manager MpvManager
---@return boolean
function M.deregister(manager)
  local extmarks = manager.callbacks.extmarks
  local success, _ = pcall(function()
    manager.callbacks.no_draw = true
    (M._players[extmarks.buffer_id] or {})[extmarks.player_id] = nil
    extmarks:remove()
  end)
  if not success then
    vim.notify(
      "Unknown error occurred: could not delete player "
      .. ("%d.%d"):format(extmarks.buffer_id, extmarks.player_id),
      vim.log.levels.ERROR,
      {}
    )
    return false
  end

  return true
end

-- Register a MpvManager using its buffer and extmark id
---@param manager MpvManager
---@param old_extmarks MpvExtmarks
---@return boolean
function M.reregister(manager, old_extmarks)
  local old_buffer, old_extmark = old_extmarks.buffer_id, old_extmarks.player_id;
  (M._players[old_buffer] or {})[old_extmark] = nil

  return M.register(manager)
end


---Get mpv instances that we currently know about for a given buffer
---@param buffer_id BufferId
---@return MpvManager[]
function M.get_mpvs_in_buffer(buffer_id)
  -- Shallow copy
  return list_slice(M._players[buffer_id] or {})
end

---Get mpv instances associated to a buffer, or all of them.
---If `arg` is a buffer number, we get mpvs from that buffer.
---If `arg` is "buffer", we get them from the current buffer.
---If `arg` is "all", we get all mpvs known to the registry.
---@param arg "all" | "buffer" | integer
---@return MpvManager[]
function M.query_mpvs(arg)
  if arg == "all" then
    local ret = {}
    for _, buffer_mpvs in pairs(M._players) do
      list_extend(ret, list_slice(buffer_mpvs))
    end
    return ret
  end

  local buffer_id = arg
  if arg == "buffer" or arg == "0" or arg == 0 then
    buffer_id = vim.fn.bufnr()
  end
  ---@cast buffer_id integer
  return M.get_mpvs_in_buffer(buffer_id)
end

---Get the mpv instance matching the buffer extmark ids, if such an
---instance exists.
---@param buffer_id BufferId
---@param extmark_id ExtmarkId
---@return MpvManager?
function M.get(buffer_id, extmark_id)
  return (M._players[buffer_id] or {})[extmark_id]
end


---Try to get the playlist extmarks from `start` to `end` in a `buffer`.
---@param buffer_id BufferId
---@param start_line integer
---@param end_line? integer
---@param show_message? boolean
---@return MpvManager?, integer?
function M.get_player_by_line(buffer_id, start_line, end_line, show_message)
  if buffer_id == 0 then buffer_id = vim.fn.bufnr() end
  if end_line == nil then end_line = start_line end

  local playlist_item = vim.api.nvim_buf_get_extmarks(
    buffer_id,
    helpers.playlist_namespace,
    {start_line - 1, 0},
    {end_line - 1, -1},
    {}
  )[1] or {}

  local found_player
  for _, player in pairs(M._players[buffer_id] or {}) do
    if list_contains(player.callbacks.extmarks.playlist_ids, playlist_item[1]) then
      found_player = player
      break
    end
  end

  if not found_player then
    if show_message then
      vim.notify("No mpv found running on that line", 4, {})
    end
    return
  end

  return found_player, playlist_item[1]
end

return M
