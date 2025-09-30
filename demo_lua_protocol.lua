local mpv_socket = require("neovimpv.mpv.protocol")

mpv_socket.new(
  "/tmp/mpv-socket",
  function(this)
    this:observe_property("playback-time")
    local f = coroutine.wrap(function()
      local foo = this:wait_property("playback-time")
      print(foo)
    end)
    f()
  end
)

vim.wait(5000)
