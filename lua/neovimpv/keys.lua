local player = require "neovimpv.player"
local config = require "neovimpv.config"

local keys = {}

local function exit_mode()
  vim.defer_fn(function()
    vim.cmd[[exe "normal \<esc>"]]
  end, 0)
end

---@param extra_args string?
---@param is_visual boolean?
local function omnikey(extra_args, is_visual)
  if extra_args == nil then extra_args = "" end

  local first_line, last_line = vim.fn.getpos("v")[2], vim.fn.getpos(".")[2]
  local try_get_mpv = player.get_player_by_line(0, first_line, last_line, true)

  if #try_get_mpv == 0 then
    -- no playlist on that line found, trying to open
    if config.omni_open_new_if_empty then
      vim.cmd((":%d,%dMpvOpen %s"):format(first_line, last_line, extra_args))
    end
  elseif not is_visual then
    local player, playlist_item = unpack(try_get_mpv) ---@diagnostic disable-line

    if extra_args:find("--video=auto") then
      vim.fn.MpvToggleVideo(player)
      exit_mode()
      return
    end

    -- mpv found, get key to send
    local temp_ns = vim.api.nvim_create_namespace("")
    local new_extmark = vim.api.nvim_buf_set_extmark(
      0,
      temp_ns,
      vim.fn.line(".") - 1,
      0,
      {
        virt_text = {{"[ getting input... ]", "MpvDefault"}},
        virt_text_pos = "eol"
      }
    )
    vim.cmd[[redraw]]

    pcall(function()
      local temp = vim.fn.getcharstr()
      if temp == config.playlist_key then
        vim.fn.MpvSetPlaylist(player, playlist_item)
      else
        vim.fn.MpvSendNvimKeys(player, temp, vim.v.count)
      end
    end)

    vim.api.nvim_buf_del_extmark(0, temp_ns, new_extmark)
  else
    vim.notify("Given range includes playlist! Ignoring...", vim.log.levels.ERROR)
  end

  exit_mode()
end

---@param direction -1 | 1
local function goto_relative_mpv(direction)
  local current = vim.fn.line(".") - 1
  local start = {current + 1, 0}
  local end_ = {-1, -1}

  if direction < 0 then
    start = {current - 1, 0}
    end_ = {0, -1}
  end

  local mpv_instances = vim.api.nvim_buf_get_extmarks(
    0,
    player.DISPLAY_NAMESPACE,
    start,
    end_,
    {}
  )

  if #mpv_instances == 0 then
    if direction < 0 then
      vim.notify("No previous mpv found", vim.log.levels.ERROR)
    else
      vim.notify("No later mpv found", vim.log.levels.ERROR)
    end
    return
  end

  vim.cmd(("normal %dG"):format(mpv_instances[1][2] + 1))
end

-- Open search prompt
local function youtube_search_prompt(first_result)
  if not vim.bo.modifiable then
    vim.notify("Cannot search YouTube from non-modifiable buffer!", vim.log.levels.ERROR)
    return
  end

  ---@type string
  local query = vim.fn.input("YouTube Search: ")

  if query:len() ~= 0 then
    if first_result == 0 then
      vim.cmd("MpvYoutubeSearch " .. query)
    else
      vim.cmd("MpvYoutubeSearch! " .. query)
    end
  end
end

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
    player.PLAYLIST_NAMESPACE,
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
        player.PLAYLIST_NAMESPACE,
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
    player.DISPLAY_NAMESPACE,
    {vim.fn.line("$"), 0},
    {-1, -1},
    {}
  )
  -- Close all players which fell outside the bounds
  for _, i in ipairs(invisible_extmarks) do
    vim.fn.MpvSendNvimKeys(i[0], "q", 1)
  end
end

function keys.bind_base()
  local vks = vim.keymap.set
  vks("n", "<Plug>(mpv_omnikey)", function() omnikey() end)
  vks("n", "<Plug>(mpv_omnikey_video)", function() omnikey("--video=auto") end)
  vks("v", "<Plug>(mpv_omnikey)", function() omnikey("vline --", true) end)
  vks("v", "<Plug>(mpv_omnikey_video)", function() omnikey("vline -- --video=auto", true) end)

  vks("n", "<Plug>(mpv_goto_earlier)", function() goto_relative_mpv(-1) end)
  vks("n", "<Plug>(mpv_goto_later)", function() goto_relative_mpv(1) end)
  vks("n", "<Plug>(mpv_youtube_prompt)", function() youtube_search_prompt() end)
  vks("n", "<Plug>(mpv_youtube_prompt_lucky)", function() youtube_search_prompt(true) end)
end

function keys.bind_smart_local()
  local vks = vim.keymap.set
  vks(
    {"n", "v"},
    "<leader>" .. config.playlist_key,
    "<Plug>(mpv_omnikey)",
    {silent = true, buffer = 0}
  )

  if
    config.playlist_key_video ~= ""
    and config.playlist_key_video ~= config.playlist_key
  then
    vks(
      {"n", "v"},
      "<leader>" .. config.playlist_key_video,
      "<Plug>(mpv_omnikey)",
      {silent = true, buffer = 0}
    )
  end

  vks(
    "n",
    "<leader>yt",
    "<Plug>(mpv_youtube_prompt)",
    {silent = true, buffer = 0}
  )
  vks(
    "n",
    "<leader>Yt",
    "<Plug>(mpv_youtube_prompt_lucky)",
    {silent = true, buffer = 0}
  )
  vks(
    "n",
    "<leader>[",
    "<Plug>(mpv_goto_earlier)",
    {silent = true, buffer = 0}
  )
  vks(
    "n",
    "<leader>]",
    "<Plug>(mpv_goto_later)",
    {silent = true, buffer = 0}
  )
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
function keys.bind_autocmd(no_text_changed)
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
      buffer = vim.fn.bufnr(),
      callback = function()
        vim.cmd(":MpvClose " .. vim.fn.bufnr())
      end,
    }
  )
end

return keys
