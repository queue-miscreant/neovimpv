local consts = require "neovimpv.consts"

local old_extmark
local function calculate_change(new_lines)
  local lines_added = 1
  local old_lines = vim.fn.line("$")
  -- let old_cursor = vim.fn.line(".")
  local old_range = { vim.fn.line("'["), vim.fn.line("']") }

  if old_lines > new_lines then
    -- lines were deleted
    lines_added = 0
    -- hack for last line of the file
    if old_range[1] == old_lines then
      old_range[0] = old_lines
    end
  end

  local new_old_extmark = vim.api.nvim_buf_get_extmarks(
    0,
    consts.playlist_namespace,
    {old_range[0] - 1, 0},
    {old_range[1] - 1, -1},
    {}
  )

  if lines_added == 0 then
    old_extmark = new_old_extmark
  end
end

-- Remove playlist items in `removed_playlist` and clean up the map to the player.
-- Along the way, create a reverse mapping consisting whose keys are player ids and
-- whose values are playlist ids that survived the change.
local function get_players_with_deletions(removed_playlist)
  local removed_ids = vim.tbl_map(function(x) return x[1] end, removed_playlist)

  local altered_players = {}
  local removed_items = {}

  for playlist_item_, player_id in pairs(vim.b.mpv_playlists_to_displays) do
    local playlist_item = tonumber(playlist_item_)

    -- TODO: how is this available in lua?
    if playlist_item and removed_ids[playlist_item + 1] then
      vim.cmd(
        "unlet b:mpv_playlists_to_displays[" .. playlist_item .. "]"
      )

      vim.api.nvim_buf_del_extmark(
        0,
        consts.playlist_namespace,
        playlist_item
      )
      table.insert(altered_players, player_id)

      if not removed_items[player_id] then
        removed_items[player_id] = {}
      end
      table.insert(removed_items[player_id], playlist_item)
    else
    end
  end

  return removed_items
end

-- Using the old extmark data in s:old_extmark, attempt to find playlist items
-- which were deleted, then forward the changes to Python
local function buffer_change_callback()
  if old_extmark ~= nil then
    local new_playlists = get_players_with_deletions(old_extmark)
    vim.fn.MpvForwardDeletions(new_playlists)
    old_extmark = nil
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
    vim.fn.MpvSendNvimKeys(i[0], "q", 1)
  end
end

-- Calback for autocommand. When a change in the buffer occurs, tries to find
-- out whether lines where removed and invokes buffer_change_callback
-- TODO insert mode equivalent?
local function undo_for_change_count()
  -- grab the attributes after the change that just happened
  local new_lines = vim.fn.line("$")
  -- let new_cursor = vim.fn.line(".")
  -- local new_range = { vim.fn.line("'["), vim.fn.line("']") }

  -- Lazy redrawing on
  vim.o.lz = true

  local try_undo = vim.b.changedtick
  local pre_undo_cursor = vim.fn.getcurpos()
  vim.cmd[[undo]]
  -- undo (or redo) for the change
  if try_undo == vim.b.changedtick then
    vim.cmd[[redo]]
    calculate_change(new_lines)
    vim.cmd[[undo]]
  else
    calculate_change(new_lines)
    vim.cmd[[redo]]
  end
  vim.fn.setpos(".", pre_undo_cursor)

  -- Lazy redrawing off
  vim.o.lz = false
  vim.defer_fn(function()
    buffer_change_callback()
  end, 0)
end

-- TODO remove autocmd when last player exits?
-- TODO use lua callback instead
---@param no_text_changed boolean?
local function bind_autocmds(no_text_changed)
  if not no_text_changed and vim.bo.modifiable then
    vim.api.nvim_create_autocmd(
      "TextChanged",
      {
        buffer = vim.fn.bufnr(),
        callback = undo_for_change_count,
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

return bind_autocmds
