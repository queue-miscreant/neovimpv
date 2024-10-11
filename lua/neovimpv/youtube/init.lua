local push_results = require "neovimpv.youtube.push_results"
local interact = require "neovimpv.youtube.interact"

return {
  open_playlist_results = push_results.open_playlist_results,
  open_select_split = push_results.open_select_split,
  paste_result = push_results.paste_result,
  bind_buffer_results = interact.bind_buffer_results,
  bind_buffer_playlist = interact.bind_buffer_playlist,
}
