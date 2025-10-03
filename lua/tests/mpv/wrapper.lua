local mpv_socket = require("neovimpv.mpv.socket")
local MpvWrapper = require("neovimpv.mpv.wrapper")
local formatting = require("neovimpv.formatting")

formatting.mpv_properties = {"pause", "playback-time", "duration", "loop"}

local MockManager = {
  playlist = {
    playlist_id_to_item = {},
    playlist_id_remap = {},
    update_currently_playing = function(...) vim.print("Updating currently playing", ...) end,
    update = function(...) vim.print("Updating", ...) end,
  },
  close = function() vim.print("Closing!") end,
  buffer = 999,
  id = 1000,
}

mpv_socket.new(
  "/tmp/mpv-socket",
  function(this)
    MpvWrapper.new(MockManager, this)
  end
)

vim.wait(5000)
