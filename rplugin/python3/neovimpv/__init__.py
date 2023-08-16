#!/usr/bin/env python3
import asyncio
import logging
import json
import os
import os.path

import pynvim
from neovimpv.format import Formatter
from neovimpv.mpv import MpvInstance, MpvPlaylistInstance
from neovimpv.youtube import open_mpv_buffer, WARN_LXML

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
        self._display_namespace = nvim.api.create_namespace(self.__class__.__name__ + "-displays")
        self._playlist_namespace = nvim.api.create_namespace(self.__class__.__name__ + "-playlists")
        nvim.exec_lua("_mpv = require('neovimpv')")

        # options
        self.formatter = Formatter(nvim)
        self.do_markdowns = nvim.api.get_var("mpv_markdown_writable")
        MpvInstance.setDefaultArgs(nvim.api.get_var("mpv_default_args"))

        # setup temp dir
        tempname = nvim.call("tempname")
        self.mpv_socket_dir = os.path.join(
            os.path.dirname(tempname),
            self.__class__.__name__.lower()
        )
        os.makedirs(self.mpv_socket_dir)

        self._mpv_instances = {}

        self._virtual_text_locked = False

    def get_mpv_by_line(self, line, show_error=True):
        '''
        Get the mpv instance on the current line of the buffer, if such an
        instance exists.
        '''
        extmark_ids = self.nvim.current.buffer.api.get_extmarks(
            self._display_namespace,
            [line, 0],
            [line, -1],
            {}
        )
        if not extmark_ids:
            if show_error:
                self.show_error("No mpv found running on that line")
            return None
        # first 0 for "first extmark", second for extmark id
        extmark_id = extmark_ids[0][0]

        return self._mpv_instances[(self.nvim.current.buffer.number, extmark_id)]

    def remove_mpv_instance(self, instance):
        '''
        Delete an MpvInstance and its extmark. This is invoked by default when
        the file is closed.
        '''
        del self._mpv_instances[(instance.buffer.number, instance.id)]
        self.nvim.lua.neovimpv.remove_mpv_instance(
            instance.buffer.number,
            instance.id,
            instance.playlist_ids
        )
        # self.nvim.lua("asdf = ... vim.print(vim.inspect(asdf))", instance.buffer)
        # self.nvim.lua.neovimpv.update_dict(
        #     self.nvim.current.buffer.number,
        #     "mpv_running_instances",
        #     instance.id
        # )

    @pynvim.command("MpvOpen", nargs="*", range="")
    def open_in_mpv(self, args, range):
        '''Open current line as a file in mpv. '''
        start, end = range[0] - 1, range[1] - 1
        if start != end:
            # TODO
            # warn the user about mpvs currently open in that range
            lines = self.nvim.current.buffer[start:end]
            target = MpvPlaylistInstance(
                self,
                self.nvim.current.buffer,
                [start, end],
                lines,
                args
            )
            self._mpv_instances[(target.buffer.number, target.id)] = target
            return

        if (target := self.get_mpv_by_line(start, show_error=False)):
            self.show_error("Mpv is already open on this line!")
            return

        target = MpvInstance(
            self,
            self.nvim.current.buffer,
            start,
            self.nvim.current.line,
            args
        )
        self._mpv_instances[(target.buffer.number, target.id)] = target

    @pynvim.command("MpvPause", nargs="?", range="")
    def pause_mpv(self, args, range):
        '''Pause/unpause the mpv instance on the current line'''
        if args and args[0] == "all":
            targets = self.get_mpvs_in_current_buffer()
            for target in targets:
                target.protocol.set_property("pause", True)
            return

        line = range[0] - 1
        if (target := self.get_mpv_by_line(line)):
            target.toggle_pause()

    @pynvim.command("MpvClose", nargs="?", range="")
    def close_mpv(self, args, range):
        '''Close mpv instance on the current line'''
        if args and args[0] == "all":
            targets = self.get_mpvs_in_current_buffer()
            for target in targets:
                target.protocol.send_command("quit")
            return

        line = range[0] - 1
        if (target := self.get_mpv_by_line(line)):
            target.protocol.send_command("quit")

    @pynvim.command("MpvSetProperty", nargs="+", range="")
    def mpv_set_property(self, args, range):
        '''Send commands to the mpv instance on the current line'''
        line = range[0] - 1
        if (target := self.get_mpv_by_line(line)):
            target.protocol.set_property(*[try_json(i) for i in args])

    @pynvim.command("MpvSend", nargs="+", range="")
    def send_mpv_command(self, args, range):
        '''Send commands to the mpv instance on the current line'''
        line = range[0] - 1
        if (target := self.get_mpv_by_line(line)):
            target.protocol.send_command(*[try_json(i) for i in args])

    @pynvim.command("MpvYoutubeSearch", nargs="?", range="")
    def mpv_youtube_search(self, args, range):
        if WARN_LXML:
            self.show_error("Python module lxml not detected. Cannot open YouTube results.")
            return
        self.nvim.loop.create_task(
            open_mpv_buffer(self.nvim, args[0])
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

    def show_error(self, error):
        '''Show an error to nvim'''
        self.nvim.async_call(
            self.nvim.api.notify,
            error,
            4,
            {}
        )

    def live_extmark(self, buffer, content, row=-1, col=-1):
        '''
        For some nefarious reason, nvim does not support updating only an extmark's
        content after has been created. Rather than running the get/set in the plugin
        (which could be slow) defer this to Lua.
        '''
        if (extmark_id := content.get("id")) is None:
            extmark_id = buffer.api.set_extmark(
                self._display_namespace,
                row,
                col,
                content
            )
            return extmark_id
        self.nvim.lua.neovimpv.update_extmark(
            buffer,
            self._display_namespace,
            extmark_id,
            content,
            row,
            col
        )

    def write_line_of_extmark(self, buffer, extmark_id, content):
        '''Write `content` to the line of an extmark with `nvim_buf_set_lines`'''
        line, _ = buffer.api.get_extmark_by_id(self._display_namespace, extmark_id, {})

        # hack that I don't like so that the extmark doesn't get written to the wrong line
        buffer.api.set_text(
            line,
            0,
            line,
            len(buffer[line]),
            content,
        )

    def get_mpvs_in_current_buffer(self):
        extmark_ids = self.nvim.current.buffer.api.get_extmarks(
            self._display_namespace,
            [0, 0],
            [-1, -1],
            {}
        )
        return [
            self._mpv_instances[(self.nvim.current.buffer.number, extmark_id)]
            for extmark_id, _, _ in extmark_ids
        ]

    def move_extmark(self, instance, line_num):
        instance.buffer.api.set_extmark(
            self._display_namespace,
            line_num,
            0,
            {
                "id": instance.id,
                "virt_text": [self.formatter.loading],
                "virt_text_pos": "eol",
            }
        )
        instance.no_draw = False
