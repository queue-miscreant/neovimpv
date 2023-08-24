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
-- to a playlist. Returns the extmark ids created.
-- Also, bind an autocommand to watch for deletions in the playlist.
-- Note: `lines` is 1-indexed like line numbers in vim.
local function create_playlist(buffer, lines, contents, display_id)
  local new_ids = {}
  local extmark = {
    sign_text=contents,
    sign_hl_group="MpvPlaylistSign"
  }
  local rule = vim.g["mpv_draw_playlist_extmarks"]
  if rule == "never" or (rule == "multiple" and #lines == 1) then
    extmark = {}
  end

  vim.api.nvim_buf_call(buffer, function()
    local dict = vim.b["mpv_playlists_to_displays"]
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
        extmark
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
local function create_player(buffer, lines, no_playlist)
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

  if no_playlist then
    return player
  end

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
  local new_extmark_text = (new_text == vim.NIL or new_text == nil) and vim.g["mpv_loading"] or new_text
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
local function remove_player(buffer, display_id)
  vim.api.nvim_buf_del_extmark(
    buffer,
    DISPLAY_NAMESPACE,
    display_id
  )

  vim.api.nvim_buf_call(buffer, function()
    -- get the playlist extmarks associated to this player
    local playlist_ids = {}
    for playlist, display in pairs(vim.b["mpv_playlists_to_displays"]) do
      if display == display_id then table.insert(playlist_ids, tonumber(playlist)) end
    end
    -- delete them
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

local function get_new_player(buffer, display_id, new_buffer, new_lines)
  remove_player(buffer, display_id)
  return create_player(new_buffer, new_lines, true)
end

-- Set the contents of the line of a playlist item with id `playist_id` in a `buffer` to `content`
local function write_line_of_playlist_item(buffer, playlist_id, content)
  local loc = vim.api.nvim_buf_get_extmark_by_id(
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

-- TODO: user chooses to paste in whole playlist, open in split, open in vert split, open in new tab
local function open_playlist_results(playlist, extra)
  local old_window = vim.api.nvim_get_current_win()
  -- parse input
  local buf_lines = {}
  local content = {}
  for i = 1, #playlist do
    local text = playlist[i]["markdown"]
    -- local value = playlist[i][2]
    -- if type(text) ~= "string" or value == nil then
    --   error("Table value is not of form {string, value}")
    -- end
    table.insert(buf_lines, text)
    -- table.insert(content, value)
  end

  -- open new tab to an empty scratch
  vim.cmd("tabe")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
  -- vim.api.nvim_buf_set_var(buf, "selection", content)
  vim.api.nvim_buf_set_var(buf, "calling_window", old_window)

  -- set options for new buffer/window
  vim.api.nvim_win_set_option(win, "number", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "youtube_playlist")

  vim.cmd("%MpvOpen " .. extra)
end

-- paste in whole playlist "on top" of an old playlist item
local function paste_playlist(buffer, display_id, old_playlist_id, new_playlist, currently_playing_index)
  -- get the old location of the playlist item
  local loc = vim.api.nvim_buf_get_extmark_by_id(buffer, PLAYLIST_NAMESPACE, old_playlist_id, {})

  -- replace the playlist and add new lines afterward
  vim.call("setbufline", buffer, loc[1] + 1, new_playlist[1])
  vim.call("appendbufline", buffer, loc[1] + 1, vim.list_slice(new_playlist, 2))

  local save_extmarks = {{loc[1], old_playlist_id}}
  for i = 2, #new_playlist do
    -- And create a playlist extmark for it
    -- Need to be back in main loop for the actual line numbers
    local extmark_id = vim.api.nvim_buf_set_extmark(
      buffer,
      PLAYLIST_NAMESPACE,
      loc[1] + 1,
      0,
      {}
    )

    save_extmarks[i] = {loc[1] + i - 1, extmark_id}
    vim.cmd(
      "let b:mpv_playlists_to_displays" ..
      "[" .. tostring(extmark_id) .. "] = " ..
      tostring(display_id)
    )
  end

  -- how many levels of indirection is this?
  vim.defer_fn(function()
    for i = 1, #save_extmarks do
      local playlist_item = save_extmarks[i]
      -- Set the extmarks in the same manner as create_player
      vim.api.nvim_buf_set_extmark(
        buffer,
        PLAYLIST_NAMESPACE,
        playlist_item[1],
        0,
        {
          id=playlist_item[2],
          sign_text="|",
          sign_hl_group="MpvPlaylistSign"
        }
      )
      -- move the player just in case
      if i == currently_playing_index then
        move_player(buffer, display_id, playlist_item[2])
      end
    end
  end, 0)

  -- only return extmark ids
  return vim.tbl_map(function(i) return i[2] end, save_extmarks)
end

-- TODO: user chooses open in split, open in vert split, open in new tab
local function new_playlist_buffer(buffer, display_id, old_playlist_id, new_playlist)
  -- open split to an empty scratch
  -- TODO: user-configurable
  vim.cmd("bel split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_playlist)

  -- set options for new buffer/window
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(
    buf,
    "filetype",
    vim.api.nvim_buf_get_option(buffer, "filetype")
  )

  local save_extmarks = {}
  vim.api.nvim_buf_call(buf, function()
    vim.b["mpv_playlists_to_displays"] = vim.empty_dict()
    for i = 1, #new_playlist do
      -- And create a playlist extmark for it
      -- Need to be back in main loop for the actual line numbers
      local extmark_id = vim.api.nvim_buf_set_extmark(
        buf,
        PLAYLIST_NAMESPACE,
        0,
        0,
        {}
      )

      save_extmarks[i] = extmark_id
      vim.cmd(
        "let b:mpv_playlists_to_displays" ..
        "[" .. tostring(extmark_id) .. "] = " ..
        tostring(display_id)
      )
    end
  end)

  local new_id = get_new_player(buffer, display_id, buf, {1, -1})
  vim.defer_fn(function()
    for i = 1, #save_extmarks do
      local extmark_id = save_extmarks[i]
      -- Set the extmarks in the same manner as create_player
      vim.api.nvim_buf_set_extmark(
        buf,
        PLAYLIST_NAMESPACE,
        i - 1,
        0,
        {
          id=extmark_id,
          sign_text="|",
          sign_hl_group="MpvPlaylistSign"
        }
      )
    end
  end, 0)

  return {buf, new_id, save_extmarks}
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
  -- get_new_player=get_new_player,

  paste_playlist=paste_playlist,
  new_playlist_buffer=new_playlist_buffer,

  open_select_split=open_select_split,
  open_playlist_results=open_playlist_results,
  bind_default_highlights=bind_default_highlights,

  DISPLAY_NAMESPACE=DISPLAY_NAMESPACE,
  PLAYLIST_NAMESPACE=PLAYLIST_NAMESPACE
}
