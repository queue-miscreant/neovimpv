local consts = require "neovimpv.consts"

---@diagnostic disable-next-line
---@cast vim.b.mpv_playlists_to_displays {[string]: integer}

---@return GetExtmark[]?
local function calculate_change(new_lines)
  local lines_added = true
  local old_lines = vim.fn.line("$")
  -- let old_cursor = vim.fn.line(".")
  local old_range = { vim.fn.line("'["), vim.fn.line("']") }

  if old_lines > new_lines then
    -- lines were deleted
    lines_added = false
    -- hack for last line of the file
    if old_range[2] == old_lines then
      old_range[1] = old_lines
    end
  end

  local new_old_extmark = vim.api.nvim_buf_get_extmarks(
    0,
    consts.playlist_namespace,
    {old_range[1] - 1, 0},
    {old_range[2] - 1, -1},
    {}
  )

  if not lines_added then
    return new_old_extmark
  end
end

-- Remove playlist items in `removed_playlist` and clean up the map to the player.
--
---@param removed_playlist GetExtmark[]
---@return {[string]: integer[]} A table whose keys are player ids and whose values
--- are playlist ids that survived the change.
local function get_players_with_deletions(removed_playlist)
  ---@type {[string]: boolean}
  local removed_ids = {}
  for _, extmark_data in ipairs(removed_playlist or {}) do
    removed_ids[tostring(extmark_data[1])] = true
  end

  local altered_players = {}
  ---@type {[string]: integer[]}
  local removed_items = vim.empty_dict()

  for playlist_item, player_id in pairs(vim.b.mpv_playlists_to_displays) do
    local playlist_extmark_id = tonumber(playlist_item)
    if playlist_extmark_id and removed_ids[playlist_item] then
      vim.cmd(
        "unlet b:mpv_playlists_to_displays[" .. playlist_item .. "]"
      )

      vim.api.nvim_buf_del_extmark(
        0,
        consts.playlist_namespace,
        playlist_extmark_id
      )
      table.insert(
        altered_players,
        playlist_extmark_id
      )

      if not removed_items[tostring(player_id)] then
        removed_items[tostring(player_id)] = {}
      end
      table.insert(
        removed_items[tostring(player_id)],
        playlist_extmark_id
      )
    else
    end
  end

  return removed_items
end

-- Using the old extmark data in old_extmark, attempt to find playlist items
-- which were deleted, then forward the changes to Python
--
---@param old_extmarks GetExtmark[]?
local function buffer_change_callback(old_extmarks)
  if old_extmarks ~= nil then
    local new_playlists = get_players_with_deletions(old_extmarks)
    vim.fn.MpvForwardDeletions(new_playlists)
  end
  local invisible_extmarks = vim.api.nvim_buf_get_extmarks(
    0,
    consts.display_namespace,
    {vim.fn.line("$"), 0},
    {-1, -1},
    {}
  )
  -- Close all players which fell outside the bounds
  for _, i in ipairs(invisible_extmarks) do
    vim.fn.MpvSendNvimKeys(i[1], "q", 1)
  end
end

-- Calback for autocommand. When a change in the buffer occurs, tries to find
-- out whether lines where removed and invokes buffer_change_callback
--
-- TODO: insert mode equivalent?
-- TODO: remove autocmd when last player exits?
local function find_and_forward_deletions()
  -- grab the attributes after the change that just happened
  local new_lines = vim.fn.line("$")
  -- let new_cursor = vim.fn.line(".")
  -- local new_range = { vim.fn.line("'["), vim.fn.line("']") }

  -- Lazy redrawing on
  vim.o.lz = true

  local try_undo = vim.b.changedtick
  local pre_undo_cursor = vim.fn.getcurpos()
  ---@type GetExtmark[]?
  local old_extmarks
  vim.cmd[[undo]]
  -- undo (or redo) for the change
  if try_undo == vim.b.changedtick then
    vim.cmd[[redo]]
    old_extmarks = calculate_change(new_lines)
    vim.cmd[[undo]]
  else
    old_extmarks = calculate_change(new_lines)
    vim.cmd[[redo]]
  end
  vim.fn.setpos(".", pre_undo_cursor)

  -- Lazy redrawing off
  vim.o.lz = false
  vim.defer_fn(function()
    buffer_change_callback(old_extmarks)
  end, 0)
end

---@param no_text_changed boolean?
local function bind_forward_deletions(no_text_changed)
  if not no_text_changed and vim.bo.modifiable then
    vim.api.nvim_create_autocmd(
      "TextChanged",
      {
        buffer = 0,
        callback = find_and_forward_deletions,
      }
    )
  end

  vim.api.nvim_create_autocmd(
    {"BufHidden", "BufDelete"},
    {
      buffer = 0,
      callback = function()
        vim.cmd(":MpvClose " .. vim.fn.bufnr())
      end,
    }
  )
end

return bind_forward_deletions
