#!/usr/bin/lua
-- neovimpv/playlist.lua
--
-- Extmark functionality which deals with playlist interactions, mainly ones
-- which are dynamically loaded by mpv.

require"neovimpv/player"
local DISPLAY_NAMESPACE = neovimpv.DISPLAY_NAMESPACE
local PLAYLIST_NAMESPACE = neovimpv.PLAYLIST_NAMESPACE

-- Set the contents of the line of a playlist item with id `playist_id` in a `buffer` to `content`
function neovimpv.write_line_of_playlist_item(buffer, playlist_id, content)
  -- Don't bother if not modifiable
  if not vim.api.nvim_buf_get_option(buffer, "modifiable") then
    return
  end

  local loc = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    PLAYLIST_NAMESPACE,
    playlist_id,
    {}
  )

  vim.call("setbufline", buffer, loc[1] + 1, content)
end

-- Update a playlist extmark to also show the currently playing item
function neovimpv.show_playlist_current(buffer, playlist_item, virt_text)
  local loc = vim.api.nvim_buf_get_extmark_by_id(buffer, PLAYLIST_NAMESPACE, playlist_item, {})
  if loc ~= nil then
    vim.api.nvim_buf_set_extmark(
      buffer,
      PLAYLIST_NAMESPACE,
      loc[1],
      loc[2],
      {
        id=playlist_item,
        virt_lines={{
          {"Currently playing: ", "MpvDefault"},
          {virt_text, "MpvTitle"}
        }},
        sign_text="|",
        sign_hl_group="MpvPlaylistSign"
      }
    )
  end
end

-- Paste in whole playlist "on top" of an old playlist item.
-- Before doing so, try to move the player to the new item so its position
-- is always valid.
function neovimpv.paste_playlist(buffer, display_id, old_playlist_id, new_playlist, current_index)
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
      if i == current_index then
        neovimpv.move_player(buffer, display_id, playlist_item[2])
      end
    end
  end, 0)

  -- only return extmark ids
  return vim.tbl_map(function(i) return i[2] end, save_extmarks)
end

-- Open the contents of new_playlist in a new split and call create_player
-- on its contents. Return the buffer, the new player extmark, and the new
-- playlist extmarks.
-- TODO: user chooses open in split, open in vert split, open in new tab
-- FIXME: sometimes the first buf_call fails?
function neovimpv.new_playlist_buffer(buffer, display_id, old_playlist_id, new_playlist)
  if old_playlist_id == vim.NIL then return end
  -- free up the old playlist map
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd(
      "unlet b:mpv_playlists_to_displays" ..
      "[" .. tostring(old_playlist_id) .. "]"
    )
  end)
  -- open split to an empty scratch
  vim.cmd("bel split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_playlist)

  local save_extmarks = {}
  vim.api.nvim_buf_call(buf, function()
    vim.b["mpv_playlists_to_displays"] = vim.empty_dict()
    vim.call("neovimpv#bind_autocmd", true)
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
    end
  end)

  -- set options for new buffer/window
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(
    buf,
    "filetype",
    vim.api.nvim_buf_get_option(buffer, "filetype")
  )
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  -- "Move" player extmark between buffers.
  neovimpv.remove_player(buffer, display_id)
  local new_id = neovimpv.create_player(buf, {1, -1}, true)

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

      vim.cmd(
        "let b:mpv_playlists_to_displays" ..
        "[" .. tostring(extmark_id) .. "] = " ..
        tostring(new_id)
      )
    end
  end, 0)

  return {buf, new_id, save_extmarks}
end
