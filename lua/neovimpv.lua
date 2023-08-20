#!/usr/bin/lua
-- neovimpv.lua
--
-- A collection of helpler functions which generally do a lot of extmark
-- (or otherwise vim-related) manipulations at once.
-- Placed here to reduce IPC with repeated get/set_extmarks calls.

local DISPLAY_NAMESPACE = vim.api.nvim_create_namespace("Neovimpv-displays")
local PLAYLIST_NAMESPACE = vim.api.nvim_create_namespace("Neovimpv-playlists")


-- Get all player ids in the display namespace, which should correspond to Python MpvInstances
function get_players_in_buffer(buffer)
  extmark_ids = vim.api.nvim_buf_get_extmarks(
    buffer,
    DISPLAY_NAMESPACE,
    0,
    -1,
    {}
  )
end

-- Try to get the playlist extmarks from `start` to `end` in a `buffer`.
-- Returns the id of the first player the playlist item belongs to.
function get_player_by_line(buffer, start, end_)
  if end_ == nil then
    end_ = start
  end

  return vim.api.nvim_buf_call(buffer, function()
    local dict = vim.b["mpv_playlists_to_displays"]
    local playlist_item = vim.api.nvim_buf_get_extmarks(
      buffer,
      PLAYLIST_NAMESPACE,
      {start - 1, 0},
      {end_ - 1, -1},
      {}
    )[1]
    
    if playlist_item == nil or dict == nil then
      return
    end

    return dict[tostring(playlist_item[1])]
  end)
end

-- Update an extmark's content without changing its row or column
local function update_extmark(buffer, extmark_id, content)
  local loc = vim.api.nvim_buf_get_extmark_by_id(buffer, DISPLAY_NAMESPACE, extmark_id, {})
  if loc ~= nil then
    pcall(function()
      vim.api.nvim_buf_set_extmark(buffer, DISPLAY_NAMESPACE, loc[1], loc[2], content)
    end)
  end
end

-- From a list of `lines` in a `buffer`, create extmarks for a playlist
-- Set some extra data in the buffer which remembers the player corresponding
-- to a playlist.
-- Note: lines is 1-indexed like line numbers in vim.
-- Also, bind an autocommand to watch for deletions in the playlist.
-- TODO: user-controllable whether all playlists draw their extmarks (or they're just invisible)
-- list of 2-tuples in the form extmark_id, row
local function create_playlist(buffer, lines, contents, display_id)
  new_ids = {}
  vim.api.nvim_buf_call(buffer, function()
    dict = vim.b["mpv_playlists_to_displays"]
    -- setup callback in this buffer
    if dict == nil then
      vim.b["mpv_playlists_to_displays"] = vim.empty_dict()
      vim.call("neovimpv#bind_autocmd")
    end
    -- add each playlist extmark
    for i, j in pairs(lines) do
      local extmark_id = vim.api.nvim_buf_set_extmark(
        buffer,
        PLAYLIST_NAMESPACE,
        j - 1,
        0,
        {
          sign_text=contents,
          sign_hl_group="MpvPlaylistSign"
        }
      )
      new_ids[i] = extmark_id
      vim.cmd(
        "let b:mpv_playlists_to_displays" ..
        "[" .. tostring(extmark_id) .. "] = " ..
        tostring(display_id)
      )
    end
  end)
  return new_ids
end

-- From a list of `lines` in a `buffer`, create extmarks for a player (displays
-- current playback state) and a playlist (list of lines to play next)
-- Note: lines is 1-indexed like line numbers in vim.
local function create_player(buffer, lines)
  local player = vim.api.nvim_buf_set_extmark(
      buffer,
      DISPLAY_NAMESPACE,
      lines[1] - 1,
      0,
      {
          virt_text={{vim.g["mpv_loading"], "MpvDefault"}},
          virt_text_pos="eol",
      }
  )
  local playlist_ids = create_playlist(
      buffer,
      lines,
      "|",
      player
  )
  return {player, playlist_ids}
end

-- Move a player with id `display_id` to the same line as the playlist item with
-- id `playlist_id`
local function move_player(buffer, display_id, new_playlist_id, new_text)
  -- get the destination line
  local loc = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    PLAYLIST_NAMESPACE,
    new_playlist_id,
    {}
  )
  -- return false if no extmark exists
  if #loc == 0 then return false end
  local new_extmark_text = new_text == vim.NIL and vim.g["mpv_loading"] or new_text
  -- set the player to that line
  vim.api.nvim_buf_set_extmark(
    buffer,
    DISPLAY_NAMESPACE,
    loc[1],
    0,
    {
      id=display_id,
      virt_text={{new_extmark_text, "MpvDefault"}},
      virt_text_pos=eol,
    }
  )
  return true
end

-- Delete extmarks in the displays and playlists namespace. Also, clear up
-- playlist information in the buffer.
local function remove_player(buffer, display_id, playlist_ids)
  vim.api.nvim_buf_del_extmark(
    buffer,
    DISPLAY_NAMESPACE,
    display_id
  )
  vim.api.nvim_buf_call(buffer, function()
    for _, playlist_id in pairs(playlist_ids) do
      vim.api.nvim_buf_del_extmark(
        buffer,
        PLAYLIST_NAMESPACE,
        playlist_id
      )
      vim.cmd(
        "unlet b:mpv_playlists_to_displays" ..
        "[" .. tostring(playlist_id) .. "]"
      )
    end
  end)
end

-- Set the contents of the line of a playlist item with id `playist_id` in a `buffer` to `content`
local function write_line_of_playlist_item(buffer, playlist_id, content)
  loc = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    PLAYLIST_NAMESPACE,
    playlist_id,
    {}
  )

  vim.call("setbufline", buffer, loc[1] + 1, content)
end

-- Open some content in a split to run a callback
--
-- `input`
--      A list of 2-tuples (tables).
--      The first item is the line of text that should be displayed.
--      The second is a value that will be used for the callback.
--
-- `filetype`
--      The filetype of the buffer to open in a split. There should be an
--      autocommand for this filetype that establishes callbacks for each of the lines.
--
-- `height` (optional)
--      The height of the split
--
local function open_select_split(input, filetype, height)
  local old_window = vim.api.nvim_get_current_win()
  -- parse input
  local buf_lines = {}
  local content = {}
  for i = 1, #input do
    local text = input[i][1]
    local value = input[i][2]
    if type(text) ~= "string" or value == nil then
      error("Table value is not of form {string, value}")
    end
    table.insert(buf_lines, text)
    table.insert(content, value)
  end

  -- open split to an empty scratch
  vim.cmd("bel split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
  vim.api.nvim_buf_set_var(buf, "selection", content)
  vim.api.nvim_buf_set_var(buf, "calling_window", old_window)
  if type(height) == "number" then
    vim.cmd("resize " .. tostring(height))
  end

  -- set options for new buffer/window
  vim.api.nvim_win_set_option(win, "number", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", filetype)
end

-- Link default highlights from names in `froms` to the highlight `to`
local function bind_default_highlights(froms, to)
  for _, from in pairs(froms) do
    vim.cmd("highlight default link " .. from .. " " .. to)
  end
end

neovimpv = {
  get_players_in_buffer=get_players_in_buffer,
  get_player_by_line=get_player_by_line,

  update_extmark=update_extmark,
  create_player=create_player,
  move_player=move_player,
  remove_player=remove_player,
  write_line_of_playlist_item=write_line_of_playlist_item,

  open_select_split=open_select_split,
  bind_default_highlights=bind_default_highlights,

  DISPLAY_NAMESPACE=DISPLAY_NAMESPACE,
  PLAYLIST_NAMESPACE=PLAYLIST_NAMESPACE
}
