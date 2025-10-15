-- mpv/registry.lua
-- Extmark/MpvManager registry.
-- Keeps autocmds which interact with extmarks clean.

local helpers = require "neovimpv.helpers"

local list_contains = vim.list_contains
local list_slice = vim.list_slice
local list_extend = vim.list_extend
local tbl_filter  = vim.tbl_filter

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
  M.try_bind_autocmds(buffer_id)

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


---Try to get the playlist extmarks from a line number (or list thereof) in buffer `buffer_id`.
---@param buffer_id BufferId
---@param line_numbers integer|integer[]
---@param show_message? boolean
---@return MpvManager?, integer?
function M.get_player_by_line(buffer_id, line_numbers, show_message)
  if buffer_id == 0 then buffer_id = vim.fn.bufnr() end
  if type(line_numbers) == "number" then line_numbers = { line_numbers } end
  ---@cast line_numbers integer[]

  local playlist_item = tbl_filter(
    function(val) return list_contains(line_numbers, val[2] + 1) end,
    vim.api.nvim_buf_get_extmarks(
      buffer_id,
      helpers.playlist_namespace,
      0,
      -1,
      {}
    )
  )[1]

  local found_player
  for _, player in pairs(M._players[buffer_id] or {}) do
    if list_contains(player.callbacks.extmarks.playlist_ids, (playlist_item or {})[1]) then
      found_player = player
      break
    end
  end

  if not found_player then
    -- Cleanup the buffer in case it looks like there's a player there
    if playlist_item then
      M.cleanup_buffer(buffer_id)
    end

    if show_message then
      vim.notify("No mpv found running on that line", 4, {})
    end
    return
  end

  return found_player, playlist_item[1]
end

---@param buffer_id BufferId
---@param namespace integer
---@return table<integer, boolean>
local function build_extmark_set(buffer_id, namespace)
  local extmarks = vim.api.nvim_buf_get_extmarks(buffer_id, namespace, 0, -1, {})
  local ret = {}
  for _, extmark in ipairs(extmarks) do
    ret[extmark[1]] = true
  end

  return ret
end

---Remove all extmarks not associated with the registry.
---@param buffer_id BufferId
function M.cleanup_buffer(buffer_id)
  local all_player_ids = build_extmark_set(buffer_id, helpers.display_namespace)
  local all_playlist_item_ids = build_extmark_set(buffer_id, helpers.playlist_namespace)

  for _, player in pairs(M._players[buffer_id] or {}) do
    local extmarks = player.callbacks.extmarks
    local removed = {}

    for _, playlist_item in ipairs(extmarks.playlist_ids) do
      -- If we have a playlist item which no longer extists as an extmark,
      -- then the deletion should be forwarded to the player
      if not all_playlist_item_ids[playlist_item] then
        table.insert(removed, playlist_item)
      end
      -- Don't remove this buffer at the end
      all_playlist_item_ids[playlist_item] = nil
    end
    player:forward_deletions(removed)

    all_player_ids[extmarks.player_id] = nil
  end

  -- Extmark ids that remain are not tracked by the registry
  for player_id, _ in pairs(all_player_ids) do
    vim.api.nvim_buf_del_extmark(
      buffer_id,
      helpers.display_namespace,
      player_id
    )
  end
  for playlist_item_id, _ in pairs(all_playlist_item_ids) do
    vim.api.nvim_buf_del_extmark(
      buffer_id,
      helpers.playlist_namespace,
      playlist_item_id
    )
  end
end

---Remove extmarks for lines which were deleted according to the
---@param new_line_count integer
---@return GetExtmark[]?
local function try_remove_deletions(new_line_count)
  local old_line_count = vim.fn.line("$")
  local old_range = { vim.fn.line("'["), vim.fn.line("']") }

  if old_line_count <= new_line_count then
    return
  end
  -- Hack for last line of file
  if old_range[2] == old_line_count then
    old_range[1] = old_line_count
  end

  local previous_playlists = vim.api.nvim_buf_get_extmarks(
    0,
    helpers.playlist_namespace,
    {old_range[1] - 1, 0},
    {old_range[2] - 1, -1},
    {}
  )
  local previous_downloads = vim.api.nvim_buf_get_extmarks(
    0,
    helpers.download_namespace,
    {old_range[1] - 1, 0},
    {old_range[2] - 1, -1},
    {}
  )

  for _, removed_playlist in ipairs(previous_playlists) do
    vim.api.nvim_buf_del_extmark(
      0,
      helpers.playlist_namespace,
      removed_playlist[1]
    )
  end
  for _, removed_download in ipairs(previous_downloads) do
    vim.api.nvim_buf_del_extmark(
      0,
      helpers.download_namespace,
      removed_download[1]
    )
  end
end

-- Calback for autocommand. When a change in the buffer occurs, tries to find
-- out whether lines where removed and invokes buffer_change_callback
--
-- TODO: insert mode equivalent?
local function find_and_forward_deletions()
  -- grab the attributes after the change that just happened
  local new_line_count = vim.fn.line("$")
  -- let new_cursor = vim.fn.line(".")
  -- local new_range = { vim.fn.line("'["), vim.fn.line("']") }
  if vim.b.mpv_no_undo then
    vim.b.mpv_no_undo = nil
    return
  end

  -- Lazy redrawing on
  vim.o.lz = true

  local try_undo = vim.b.changedtick
  local pre_undo_cursor = vim.fn.getcurpos()
  vim.cmd[[undo]]
  -- undo (or redo) for the change
  if try_undo == vim.b.changedtick then
    vim.cmd[[redo]]
    try_remove_deletions(new_line_count)
    vim.cmd[[undo]]
  else
    try_remove_deletions(new_line_count)
    vim.cmd[[redo]]
  end
  vim.fn.setpos(".", pre_undo_cursor)

  -- Lazy redrawing off
  vim.o.lz = false

  vim.defer_fn(function()
    M.cleanup_buffer(vim.fn.bufnr())
  end, 0)
end

---@param buffer_id integer
function M.try_bind_autocmds(buffer_id)
  if vim.b.mpv_bound_autocmds then return end
  vim.b.mpv_bound_autocmds = true

  if vim.bo.modifiable then
    vim.api.nvim_create_autocmd(
      "TextChanged",
      {
        buffer = buffer_id,
        callback = find_and_forward_deletions,
      }
    )
  end

  vim.api.nvim_create_autocmd(
    {"BufHidden", "BufDelete", "VimLeavePre"},
    {
      buffer = buffer_id,
      callback = function(ev)
        local players = M.query_mpvs(
          ev.event:find("^Buf")
          and ev.buf
          or "all"
        )
        for _, player in ipairs(players) do
          player:close()
        end
      end
    }
  )
end

return M
