-- neovimpv/playlist.lua
--
-- Extmark functionality which deals with playlist interactions, mainly ones
-- which are dynamically loaded by mpv.

local player = require "neovimpv.player"
local consts = require "neovimpv.consts"
local bind_forward_deletions = require "neovimpv.forward_deletions"

local playlist = {}

---Set the contents of the line of a playlist item with id `playist_id` in a `buffer` to `content`
---
---@param buffer integer
---@param playlist_id integer Target ID of the playlist.
---@param content string New line contents.
function playlist.write_line_of_playlist_item(buffer, playlist_id, content)
  -- Don't bother if not modifiable
  if not vim.api.nvim_buf_get_option(buffer, "modifiable") then
    return
  end

  local loc = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    consts.playlist_namespace,
    playlist_id,
    {}
  )

  -- Update the buffer only on mismatches
  if content ~= vim.fn.getbufline(buffer, loc[1] + 1)[1] then
    vim.fn.setbufline(buffer, loc[1] + 1, content)
  end
end

---Update a playlist extmark to also show the currently playing item
---
---@param buffer integer
---@param playlist_id integer
---@param virt_text string
function playlist.show_playlist_current(buffer, playlist_id, virt_text)
  local loc = vim.api.nvim_buf_get_extmark_by_id(buffer, consts.playlist_namespace, playlist_id, {})
  if loc ~= nil then
    vim.api.nvim_buf_set_extmark(
      buffer,
      consts.playlist_namespace,
      loc[1],
      loc[2],
      {
        id = playlist_id,
        virt_lines = {{
          {"Currently playing: ", "MpvDefault"},
          {virt_text, "MpvTitle"}
        }},
        sign_text = "|",
        sign_hl_group = "MpvPlaylistSign"
      }
    )
  end
end

---Paste in whole playlist "on top" of an old playlist item.
---Before doing so, try to move the player to the new item so its position
---is always valid.
---
---@param buffer integer
---@param display_id integer Target player ID
---@param old_playlist_id integer Playlist ID of item to replace.
---@param new_playlist string[] Replacement buffer content for playlist item
---@param current_index integer Index (NOT ID) in the playlist to move the player to after pasting.
---@return integer[]
function playlist.paste_playlist(buffer, display_id, old_playlist_id, new_playlist, current_index)
  -- get the old location of the playlist item
  local loc = vim.api.nvim_buf_get_extmark_by_id(buffer, consts.playlist_namespace, old_playlist_id, {})

  -- replace the playlist and add new lines afterward
  vim.fn.setbufline(buffer, loc[1] + 1, new_playlist[1])
  vim.fn.appendbufline(buffer, loc[1] + 1, vim.list_slice(new_playlist, 2))

  local save_extmarks = {{loc[1], old_playlist_id}}
  for i = 2, #new_playlist do
    -- And create a playlist extmark for it
    -- Need to be back in main loop for the actual line numbers
    local extmark_id = vim.api.nvim_buf_set_extmark(
      buffer,
      consts.playlist_namespace,
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
        consts.playlist_namespace,
        playlist_item[1],
        0,
        {
          id = playlist_item[2],
          sign_text = "|",
          sign_hl_group = "MpvPlaylistSign"
        }
      )
      -- move the player just in case
      if i == current_index then
        player.move_player(buffer, display_id, playlist_item[2])
      end
    end
  end, 0)

  -- only return extmark ids
  return vim.tbl_map(function(i) return i[2] end, save_extmarks)
end

---Open the contents of new_playlist in a new split and call create_player
---on its contents.
---Returns the buffer, the new player extmark, and the new playlist extmarks.
---
---@param buffer integer
---@param display_id integer Target player ID.
---@param old_playlist_id integer Playlist ID to delete.
---@param new_playlist string[] New playlist contents. See argument in `paste_playlist`.
---@return ([integer, integer, integer[]] | nil)
-- TODO: user chooses open in split, open in vert split, open in new tab
-- FIXME: sometimes the first buf_call fails?
function playlist.new_playlist_buffer(buffer, display_id, old_playlist_id, new_playlist)
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
  local new_buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, new_buffer)

  -- set buffer content
  vim.api.nvim_buf_set_lines(new_buffer, 0, -1, false, new_playlist)

  local save_extmarks = {}
  vim.api.nvim_buf_call(new_buffer, function()
    vim.b.mpv_playlists_to_displays = vim.empty_dict()
    bind_forward_deletions(true)
    for i = 1, #new_playlist do
      -- And create a playlist extmark for it
      -- Need to be back in main loop for the actual line numbers
      local extmark_id = vim.api.nvim_buf_set_extmark(
        new_buffer,
        consts.playlist_namespace,
        0,
        0,
        {}
      )

      save_extmarks[i] = extmark_id
    end

    -- set options for new buffer
    vim.bo.modifiable = false
    vim.bo.bufhidden = "wipe"
    vim.bo.filetype = vim.api.nvim_buf_get_option(buffer, "filetype")
  end)

  -- "Move" player extmark between buffers.
  player.remove_player(buffer, display_id)
  local new_id = player.create_player(new_buffer, {1, -1}, true)

  vim.defer_fn(function()
    for i = 1, #save_extmarks do
      local extmark_id = save_extmarks[i]
      -- Set the extmarks in the same manner as create_player
      vim.api.nvim_buf_set_extmark(
        new_buffer,
        consts.playlist_namespace,
        i - 1,
        0,
        {
          id = extmark_id,
          sign_text = "|",
          sign_hl_group = "MpvPlaylistSign"
        }
      )

      vim.cmd(
        "let b:mpv_playlists_to_displays" ..
        "[" .. tostring(extmark_id) .. "] = " ..
        tostring(new_id)
      )
    end
  end, 0)

  return {new_buffer, new_id, save_extmarks}
end

return playlist
