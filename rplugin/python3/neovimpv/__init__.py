#!/usr/bin/env python3
import asyncio
import logging
import os
import os.path

import pynvim
from neovimpv.format import Formatter, try_json
from neovimpv.mpv import MpvInstance

log = logging.getLogger(__name__)

@pynvim.plugin
class Neovimpv:
    def __init__(self, nvim):
        self.nvim = nvim
        self._plugin_namespace = nvim.api.create_namespace(self.__class__.__name__)

        # options
        self.formatter = Formatter(nvim)
        self.do_markdowns = nvim.api.get_var("mpv_markdown_writable")
        MpvInstance.MPV_ARGS.extend(nvim.api.get_var("mpv_default_args"))

        # setup temp dir
        tempname = nvim.call("tempname")
        self.mpv_socket_dir = os.path.join(
            os.path.dirname(tempname),
            self.__class__.__name__.lower()
        )
        os.makedirs(self.mpv_socket_dir)

        self._mpv_instances = {}
        nvim.exec_lua("_mpv = require('neovimpv')")

        self._virtual_text_locked = False

    def get_mpv_by_line(self, line, show_error=True):
        '''
        Get the mpv instance on the current line of the buffer, if such an
        instance exists.
        '''
        extmark_ids = self.nvim.current.buffer.api.get_extmarks(
            self._plugin_namespace,
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
        instance.buffer.api.del_extmark(
            self._plugin_namespace,
            instance.id,
        )

    @pynvim.command("MpvOpen", nargs="*", range="")
    def open_in_mpv(self, args, range):
        '''Open current line as a file in mpv. '''
        line = range[0] - 1
        if (target := self.get_mpv_by_line(line, show_error=False)):
            self.show_error("Mpv is already open on this line!")
            return

        target = MpvInstance(
            self,
            self.nvim.current.buffer,
            line,
            self.nvim.current.line,
            args
        )
        self._mpv_instances[(target.buffer.number, target.id)] = target

    @pynvim.command("MpvPause", nargs="?", range="")
    def pause_mpv(self, args, range):
        '''Pause/unpause the mpv instance on the current line'''
        #TODO: optional argument for "all" instances
        line = range[0] - 1
        if (target := self.get_mpv_by_line(line)):
            target.toggle_pause()

    @pynvim.command("MpvClose", nargs="?", range="")
    def close_mpv(self, args, range):
        '''Close mpv instance on the current line'''
        #TODO: optional argument for "all" instances
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

    def show_error(self, error):
        self.nvim.async_call(
            self.nvim.api.notify,
            error,
            4,
            {}
        )

    def live_extmark(self, buffer, content, row=0, col=0):
        '''
        For some nefarious reason, nvim does not support updating an extmark after one
        has been created. Rather than running the get/set in the plugin (which is slow)
        defer this to Lua.
        '''
        if (extmark_id := content.get("id")) is None:
            extmark_id = buffer.api.set_extmark(
                self._plugin_namespace,
                row,
                col,
                content
            )
            return extmark_id
        self.nvim.lua.neovimpv.update_extmark(buffer, self._plugin_namespace, extmark_id, content)

    def write_line_of_extmark(self, buffer, extmark_id, content):
        '''Write `content` to the line of an extmark with `nvim_buf_set_lines`'''
        line, _ = buffer.api.get_extmark_by_id(self._plugin_namespace, extmark_id, {})

        # hack that I don't like so that the extmark doesn't get written to the wrong line
        buffer.api.set_text(
            line,
            0,
            line,
            len(buffer[line]),
            content,
        )
