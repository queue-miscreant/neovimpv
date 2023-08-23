#!/usr/bin/env python3
import asyncio
import logging
import json
import os
import os.path

import pynvim
from neovimpv.format import Formatter
from neovimpv.mpv import MpvInstance
from neovimpv.youtube import open_results_buffer, open_playlist_results, WARN_LXML

log = logging.getLogger(__name__)

KEYPRESS_LOOKUP = {
    "kl": "left",
    "kr": "right",
    "ku": "up",
    "kd": "down",
}

def translate_keypress(key):
    if key[0] == "\udc80":
        #TODO: handle ctrl (\udcfc\x04, then original keypress)
        #TODO: handle alt (\udcfc\x08, then original keypress)
        #TODO: special (ctrl-right?)
        # log.debug("Filtered out")
        # log.debug(repr(key))
        return KEYPRESS_LOOKUP.get(key[1:], None)
    return key

def try_json(arg):
    '''Attempt to read arg as a JSON object. Return the string on failure'''
    try:
        return json.loads(arg)
    except:
        return arg

@pynvim.plugin
class Neovimpv:
    def __init__(self, nvim):
        self.nvim = nvim

        # options
        self.formatter = Formatter(nvim)
        self.do_markdowns = nvim.api.get_var("mpv_markdown_writable")
        self.on_playlist_update = nvim.api.get_var("mpv_on_playlist_update")
        MpvInstance.setDefaultArgs(nvim.api.get_var("mpv_default_args"))

        # setup temp dir
        tempname = nvim.call("tempname")
        self.mpv_socket_dir = os.path.join(
            os.path.dirname(tempname),
            self.__class__.__name__.lower()
        )
        os.makedirs(self.mpv_socket_dir)

        self._mpv_instances = {}

    @pynvim.command("MpvOpen", nargs="*", range="")
    def open_in_mpv(self, args, range_):
        '''Open current line as a file in mpv.'''
        start, end = range_
        if start == end and self.get_mpv_by_line(self.nvim.current.buffer, start, show_error=False):
            self.show_error("Mpv is already open on this line!")
            return

        lines = self.nvim.current.buffer[start-1:end] # end+1 for inclusive
        current_filetype = self.nvim.current.buffer.api.get_option("filetype")

        target = MpvInstance(
            self,
            self.nvim.current.buffer.number,
            range(start, end + 1),
            lines,
            args,
            current_filetype in self.do_markdowns
        )
        if target is not None:
            self._mpv_instances[(target.buffer, target.id)] = target

    @pynvim.command("MpvPause", nargs="?", range="")
    def pause_mpv(self, args, range):
        '''Pause/unpause the mpv instance on the current line'''
        if args and args[0] == "all":
            targets = self.get_mpvs_in_buffer(self.nvim.current.buffer)
            for target in targets:
                target.protocol.set_property("pause", True)
            return

        line = range[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)):
            target.toggle_pause()

    @pynvim.command("MpvClose", nargs="?", range="")
    def close_mpv(self, args, range):
        '''Close mpv instance on the current line'''
        if args and args[0] == "all":
            targets = self.get_mpvs_in_buffer(self.nvim.current.buffer)
            for target in targets:
                target.protocol.send_command("quit")
            return

        line = range[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)):
            target.protocol.send_command("quit")

    @pynvim.command("MpvSetProperty", nargs="+", range="")
    def mpv_set_property(self, args, range):
        '''Send commands to the mpv instance on the current line'''
        line = range[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)):
            target.protocol.set_property(*[try_json(i) for i in args])

    @pynvim.command("MpvSend", nargs="+", range="")
    def send_mpv_command(self, args, range):
        '''Send commands to the mpv instance on the current line'''
        line = range[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)):
            target.protocol.send_command(*[try_json(i) for i in args])

    @pynvim.command("MpvYoutubeSearch", nargs="?", range="")
    def mpv_youtube_search(self, args, range):
        if len(args) != 1:
            raise TypeError(f"Expected 1 argument, got {len(args)}")
        if WARN_LXML:
            self.show_error("Python module lxml not detected. Cannot open YouTube results.")
            return
        self.nvim.loop.create_task(
            open_results_buffer(self.nvim, args[0])
        )

    @pynvim.function("MpvSendNvimKeys", sync=True)
    def mpv_send_keypress(self, args):
        '''Send keypress to the mpv instance'''
        if len(args) == 3:
            extmark_id, key, count = args
        else:
            raise TypeError(f"Expected 3 arguments, got {len(args)}")
        if (target := self._mpv_instances.get(
            (self.nvim.current.buffer.number, extmark_id)
        )):
            if target.protocol is None:
                self.show_error("Mpv not ready yet")
                return
            if (real_key := translate_keypress(key)):
                self.nvim.loop.create_task(target.protocol.send_keypress(real_key, count=count or 1))

    @pynvim.function("MpvUpdatePlaylists", sync=True)
    def mpv_update_playlists(self, args):
        '''Receive updated playlist extmark positions from nvim'''
        if len(args) == 1:
            updated_playlists, = args
        else:
            raise TypeError(f"Expected 1 argument, got {len(args)}")

        for player, playlist_items in updated_playlists.items():
            mpv_instance = self._mpv_instances.get((self.nvim.current.buffer.number, int(player)))
            if mpv_instance is not None:
                self.nvim.loop.call_soon(mpv_instance.update_playlist, playlist_items)

    @pynvim.function("MpvOpenYoutubePlaylist", sync=True)
    def mpv_open_youtube_playlist(self, args):
        '''Receive updated playlist extmark positions from nvim'''
        if len(args) == 2:
            playlist, extra = args
        else:
            raise TypeError(f"Expected 2 argument, got {len(args)}")

        self.nvim.loop.create_task(
            open_playlist_results(self.nvim, playlist, extra)
        )

    def show_error(self, error):
        '''Show an error to nvim'''
        self.nvim.async_call(
            self.nvim.api.notify,
            error,
            4,
            {}
        )

    def get_mpvs_in_buffer(self, buffer):
        '''Show an error to nvim'''
        return [i for i in
            (self._mpv_instances.get((buffer.number, i))
                for i in self.nvim.lua.get_players_in_buffer(buffer.number))
            if i
        ]

    def get_mpv_by_line(self, buffer, line, show_error=True):
        '''
        Get the mpv instance on the current line of the buffer, if such an
        instance exists.
        '''
        player_id = self.nvim.lua.neovimpv.get_player_by_line(
            buffer.number,
            line
        )
        if player_id is None:
            if show_error:
                self.show_error("No mpv found running on that line")
            return None

        return self._mpv_instances[(buffer.number, player_id)]

    def remove_mpv_instance(self, instance):
        '''
        Delete an MpvInstance and its extmark. This is invoked by default when
        the file is closed.
        '''
        del self._mpv_instances[(instance.buffer, instance.id)]
        self.nvim.lua.neovimpv.remove_player(
            instance.buffer,
            instance.id
        )

    def set_new_buffer(self, instance, new_buffer, new_display):
        '''
        Updates the global record of an mpv instance's buffer and display extmark
        '''
        del self._mpv_instances[(instance.buffer, instance.id)]
        instance.buffer = new_buffer
        instance.id = new_display
        self._mpv_instances[(new_buffer, new_display)] = instance
