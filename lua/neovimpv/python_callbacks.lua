-- neovimpv.python_callbacks
--
-- Lua callbacks for python.

local player = require "neovimpv.player"
local playlist = require "neovimpv.playlist"

local youtube_push_results = require "neovimpv.youtube.push_results"

return {
  -- player.py
  create_player = player.create_player,

  -- mpv.py
  update_extmark = player.update_extmark,
  write_line_of_playlist_item = player.write_line_of_playlist_item,
  move_player = player.move_player,
  show_playlist_current = playlist.show_playlist_current,
  paste_playlist = playlist.paste_playlist,
  new_playlist_buffer = playlist.new_playlist_buffer,

  -- youtube.py
  open_youtube_select_split = youtube_push_results.open_select_split,
  paste_youtube_result = youtube_push_results.paste_result,
  open_youtube_playlist_results = youtube_push_results.open_playlist_results,
}
