local push_results = require "neovimpv.youtube.push_results"
local interact = require "neovimpv.youtube.interact"

return {
  open_playlist_results = push_results.open_playlist_results,
  open_select_split = push_results.open_select_split,
  paste_result = push_results.paste_result,
  setup_autocmd = interact.setup_autocmd,
}
