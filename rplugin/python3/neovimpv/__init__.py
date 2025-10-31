"""
neovimpv

Python backend for providing a nice interface to youtube searches.
"""

import pynvim

from neovimpv.youtube import (
    open_results_buffer,
    open_first_result,
    open_playlist_results,
    WARN_LXML,
)


@pynvim.plugin
class Neovimpv:
    """Plugin root object"""

    def __init__(self, nvim):
        self.nvim = nvim

    @pynvim.command("MpvYoutubeSearch", nargs="?", bang=True, range="")
    def mpv_youtube_search(self, args, _, bang=False):
        """Query Youtube and open the results in an auxiliary buffer"""
        if len(args) != 1:
            raise TypeError(f"Expected 1 argument, got {len(args)}")
        if WARN_LXML:
            self.nvim.api.notify(
                "Python module lxml not detected. Cannot open YouTube results.", 4, {}
            )
            return

        self.nvim.api.notify("Searching YouTube...", 1, {})

        if bang:
            self.nvim.loop.create_task(
                open_first_result(self.nvim, args[0], self.nvim.current.window)
            )
            return
        self.nvim.loop.create_task(
            open_results_buffer(self.nvim, args[0], self.nvim.current.window)
        )

    @pynvim.function("MpvOpenYoutubePlaylist", sync=True)
    def mpv_open_youtube_playlist(self, args):
        """(Deprecated) Make a new buffer for a YouTube playlist object"""
        if len(args) == 2:
            playlist, extra = args
        else:
            raise TypeError(f"Expected 2 argument, got {len(args)}")

        self.nvim.loop.create_task(open_playlist_results(self.nvim, playlist, extra))
