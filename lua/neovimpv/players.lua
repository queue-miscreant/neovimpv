local list_slice = vim.list_slice
local list_extend = vim.list_extend

---@alias BufferIdStr string
---@alias ExtmarkIdStr string

local M = {
  ---@type table<string, table<string, MpvManager>>
  ---@private
  _players = {},
}

---@param manager MpvManager
---@param buffer_id BufferIdStr
---@param extmark_id ExtmarkIdStr
---@return boolean
function M._register(manager, buffer_id, extmark_id)
  local players_in_buffer = M._players[buffer_id] or {}

  if players_in_buffer[extmark_id] then
    vim.notify(
      "Error: buffer and extmark already correspond to a MpvManager",
      vim.log.levels.ERROR,
      {}
    )
    return false
  end
  players_in_buffer[extmark_id] = manager

  M._players[buffer_id] = players_in_buffer
  return true
end


-- Register a MpvManager using its buffer and extmark id
---@param manager MpvManager
---@return boolean
function M.register(manager)
  return M._register(manager, tostring(manager.buffer), tostring(manager.id))
end

-- Remove a MpvManager and clean up its extmarks
---@param manager MpvManager
---@return boolean
function M.deregister(manager)
  local success, err = pcall(function()
    (manager.mpv or {}).no_draw = true
    vim._neovimpv_callbacks.remove_player(manager.buffer, manager.id);
    (M._players[manager.buffer] or {})[manager.id] = nil
  end)
  if not success then
    vim.notify(
      "Unknown error occurred: could not delete player .. "
      .. tostring(manager.buffer) .. "." .. tostring(manager.id),
      vim.log.levels.ERROR,
      {}
    )
    return false
  end

  return true
end

-- Register a MpvManager using its buffer and extmark id
---@param manager MpvManager
---@param buffer_id integer
---@param extmark_id integer
---@return boolean
function M.reregister(manager, buffer_id, extmark_id)
  local old_buffer, old_extmark = tostring(manager.buffer), tostring(manager.id);
  (M._players[old_buffer] or {})[old_extmark] = nil

  return M._register(manager, tostring(buffer_id), tostring(extmark_id))
end


---Get mpv instances that we currently know about for a given buffer
---@param buffer_id BufferIdStr
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

  return M.get_mpvs_in_buffer(tostring(buffer_id))
end

---Get the mpv instance matching the buffer extmark ids, if such an
---instance exists.
---@param buffer_id BufferIdStr
---@param extmark_id ExtmarkIdStr
---@return MpvManager?
function M.get(buffer_id, extmark_id)
  return (M._players[tostring(buffer_id)] or {})[tostring(extmark_id)]
end

return M
