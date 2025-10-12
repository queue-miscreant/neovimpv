local mpv_socket = require("neovimpv.mpv.socket")

mpv_socket.new(
  "/tmp/mpv-socket",
  function(success, socket)
    if not success then return end
    ---@cast socket MpvSocket
    socket:observe_property("playback-time")
    local f = coroutine.wrap(function()
      local foo = socket:wait_property("playback-time")
      print(foo)
    end)
    f()
  end
)

vim.wait(5000)
