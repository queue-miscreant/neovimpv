#!/usr/bin/env python3
"""
neovimpv

Python backend, responsible for implementing commands which interact with mpv subprocesses.
"""
import logging
import json
import os
import os.path
import shlex

import pynvim

from neovimpv.format import Formatter
from neovimpv.mpv import log as mpv_logger
from neovimpv.player import MpvManager, create_managed_mpv, log as player_logger
from neovimpv.protocol import log as protocol_logger
from neovimpv.youtube import \
    open_results_buffer, \
    open_first_result, \
    open_playlist_results, \
    log as youtube_logger, \
    WARN_LXML

log = logging.getLogger(__name__)

# The general layout of the plugin is as follows:
#
#   Plugin
#       |
#       |---MpvManager
#       |       |   A wrapper object which delivers plugin commands to the correct subprocess
#       |       |
#       |       |------- MpvPlaylist
#       |       |           Keeps track of mpv playlist data and links it to nvim data
#       |       |
#       |       |------- MpvWrapper
#       |                   |   A plugin-aware protocol wrapper which pushes IPC data to the buffer
#       |                   |
#       |                   |------- MpvProtocol
#       |                               The actual asyncio protocol wrapping mpv's IPC socket
#       |---MpvManager
#       |
#       |---MpvManager


KEYPRESS_LOOKUP = {
    "kl": "left",
    "kr": "right",
    "ku": "up",
    "kd": "down",
    "kb": "bs",
}

def translate_keypress(key):
    '''
    Translate a vim keypress from `getchar()` into one intelligible to mpv's keypress command.
    '''
    if key[0] == "\udc80":
        #TODO: handle ctrl (\udcfc\x04, then original keypress)
        #TODO: handle alt (\udcfc\x08, then original keypress)
        #TODO: special (ctrl-right?)
        log.debug(f"Special key sequence found: {repr(key)}")
        return KEYPRESS_LOOKUP.get(key[1:], None)
    return key

def try_json(arg):
    '''Attempt to read arg as a JSON object. Return the string on failure'''
    try:
        return json.loads(arg)
    except json.JSONDecodeError:
        return arg

@pynvim.plugin
class Neovimpv: # pylint: disable=too-many-public-methods
    '''Plugin root object. Keeps track of and routes commands to MpvManager objects.'''
    def __init__(self, nvim):
        self.nvim = nvim

        # options
        self.formatter = Formatter(nvim)
        self.do_markdowns = nvim.api.get_var("mpv_markdown_writable")
        self.on_playlist_update = nvim.api.get_var("mpv_on_playlist_update")
        self.smart_youtube = nvim.api.get_var("mpv_smart_youtube_playlist")
        MpvManager.set_default_args(nvim.api.get_var("mpv_default_args"))

        # setup temp dir
        tempname = nvim.call("tempname")
        self.mpv_socket_dir = os.path.join(
            os.path.dirname(tempname),
            self.__class__.__name__.lower()
        )
        os.makedirs(self.mpv_socket_dir)

        self._mpv_instances = {}

    def create_mpv_instance(self, lines, start, end, args, ignore_mode=False):  # pylint: disable=too-many-arguments
        '''Create an MpvManager and register it in `self._mpv_instances`'''
        if (
            start == end
            and self.get_mpv_by_line(self.nvim.current.buffer, start)
        ):

            self.show_error("Mpv is already open on this line!")
            return

        target = create_managed_mpv(
            self,
            lines,
            start,
            end,
            args,
            ignore_mode,
        )
        if target is None:
            return

        self._mpv_instances[(target.buffer, target.id)] = target

    @pynvim.command("MpvOpen", nargs="*", range="")
    def open_in_mpv(self, args, range_):
        '''Open current line as a file in mpv.'''
        start, end = range_
        # For some reason, vim sends the args over space-delimited,
        # instead of with quotes interpreted
        args = shlex.split(" ".join(args))
        lines = self.nvim.current.buffer[start-1:end]

        self.create_mpv_instance(lines, start, end, args)

    @pynvim.command("MpvNewAtLine", nargs="*", range="")
    def new_mpv_at_line(self, args, range_):
        '''Open file from command argument at the current line.'''
        start, end = range_
        args = shlex.split(" ".join(args))
        target_link = [args[0]]
        self.create_mpv_instance(target_link, start, end, args[1:], ignore_mode=True)

    @pynvim.command(
        "MpvPause",
        nargs="?",
        range="",
        complete="customlist,neovimpv#mpv_close_pause"
    )
    def pause_mpv(self, args, range_):
        '''Pause/unpause the mpv instance on the current line'''
        if args and args[0] == "all":
            targets = self.query_mpvs(args[0])
            for target in targets:
                target.set_property("pause", True)
            return

        line = range_[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)):
            target.toggle_pause()

    @pynvim.command(
        "MpvClose",
        nargs="?",
        range="",
        complete="customlist,neovimpv#complete#mpv_close_pause"
    )
    def close_mpv(self, args, range_):
        '''Close mpv instance on the current line'''
        if args:
            targets = self.query_mpvs(args[0])
            for target in targets:
                target.close()
            return

        line = range_[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)):
            target.close()

    @pynvim.command(
        "MpvSetProperty",
        nargs="+",
        range="",
        complete="customlist,neovimpv#complete#mpv_set_property"
    )
    def mpv_set_property(self, args, range_):
        '''Assign a value to a property of the mpv instance on the current line'''
        line = range_[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)):
            target.set_property(*[try_json(i) for i in args])

    @pynvim.command(
        "MpvGetProperty",
        nargs="1",
        range="",
        complete="customlist,neovimpv#complete#mpv_get_property"
    )
    def mpv_get_property(self, args, range):
        '''Request a property from the mpv instance on the current line'''
        if len(args) != 1:
            raise TypeError(f"Expected 1 argument, got {len(args)}")

        property_name = args[0]
        line = range[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)) is None:
            return

        async def get_property():
            result = await target.wait_property(property_name)
            self.nvim.async_call(self.nvim.api.notify, str(result), 0, {})
        self.nvim.loop.create_task(get_property())

    @pynvim.command(
        "MpvSend",
        nargs="+",
        range="",
        complete="customlist,neovimpv#complete#mpv_command"
    )
    def send_mpv_command(self, args, range_):
        '''Send commands to the mpv instance on the current line'''
        line = range_[0]
        if (target := self.get_mpv_by_line(self.nvim.current.buffer, line)):
            target.send_command(*[try_json(i) for i in args])

    @pynvim.command("MpvYoutubeSearch", nargs="?", bang=True, range="")
    def mpv_youtube_search(self, args, _, bang=False):
        '''Query Youtube and open the results in an auxiliary buffer'''
        if len(args) != 1:
            raise TypeError(f"Expected 1 argument, got {len(args)}")
        if WARN_LXML:
            self.show_error("Python module lxml not detected. Cannot open YouTube results.")
            return

        if bang:
            self.nvim.loop.create_task(
                open_first_result(self.nvim, args[0], self.nvim.current.window)
            )
            return
        self.nvim.loop.create_task(
            open_results_buffer(self.nvim, args[0], self.nvim.current.window)
        )

    @pynvim.command(
        "MpvLogLevel",
        nargs="+",
        range="",
        complete="customlist,neovimpv#complete#log_level"
    )
    def mpv_log_level(self, args, _):
        '''Set logging level from vim'''
        if len(args) == 2:
            logger_name, level = args
        else:
            raise TypeError(f"Expected 2 arguments, got {len(args)}")

        logger_name = logger_name.lower()
        if logger_name not in ["mpv", "player", "protocol", "youtube", "all"]:
            raise ValueError(f"Invalid logger name given: {logger_name}")

        level = level.upper()
        if level not in ["INFO", "DEBUG", "WARNING", "WARN", "ERROR", "FATAL", "NOTSET"]:
            raise ValueError(f"Invalid logging level given: {level}")

        if logger_name == "mpv":
            mpv_logger.setLevel(level)
        elif logger_name == "player":
            player_logger.setLevel(level)
        elif logger_name == "protocol":
            protocol_logger.setLevel(level)
        elif logger_name == "youtube":
            youtube_logger.setLevel(level)
        elif logger_name == "all":
            log.setLevel(level)

    @pynvim.function("MpvSendNvimKeys", sync=True)
    def mpv_send_keypress(self, args):
        '''Send keypress to the mpv instance'''
        if len(args) == 3:
            extmark_id, key, count = args
        else:
            raise TypeError(f"Expected 3 arguments, got {len(args)}")
        log.debug(
            "Received keypress: %s\n" \
            "Sending to buffer %s.%s\n" \
            "mpv_instances: %s",
            repr(key),
            self.nvim.current.buffer.number, extmark_id,
            self._mpv_instances
        )
        if (target := self._mpv_instances.get(
            (self.nvim.current.buffer.number, extmark_id)
        )):
            real_key = translate_keypress(key)

            self.nvim.loop.create_task(
                target.send_keypress(real_key, count=count or 1)
            )

    @pynvim.function("MpvSetPlaylist", sync=True)
    def mpv_set_playlist(self, args):
        '''Set currently playing item'''
        if len(args) == 2:
            player, playlist_item = args
        else:
            raise TypeError(f"Expected 2 arguments, got {len(args)}")

        mpv_instance = self._mpv_instances.get(
            (self.nvim.current.buffer.number, int(player))
        )
        if mpv_instance is not None:
            self.nvim.loop.create_task(mpv_instance.set_current_by_playlist_extmark(playlist_item))

    @pynvim.function("MpvForwardDeletions", sync=True)
    def mpv_forward_deletions(self, args):
        '''Receive updated playlist extmark positions from nvim'''
        if len(args) == 1:
            updated_playlists, = args
        else:
            raise TypeError(f"Expected 1 argument, got {len(args)}")

        for player, removed_items in updated_playlists.items():
            mpv_instance = self._mpv_instances.get(
                (self.nvim.current.buffer.number, int(player))
            )
            if mpv_instance is not None:
                self.nvim.loop.create_task(mpv_instance.forward_deletions(removed_items))

    @pynvim.function("MpvToggleVideo", sync=True)
    def mpv_toggle_video(self, args):
        '''Turn an audio player into a video player and vice-versa'''
        if len(args) == 1:
            player, = args
        else:
            raise TypeError(f"Expected 1 argument, got {len(args)}")

        mpv_instance = self._mpv_instances.get(
            (self.nvim.current.buffer.number, int(player))
        )
        if mpv_instance is not None:
            self.nvim.loop.create_task(mpv_instance.toggle_video())

    @pynvim.function("MpvOpenYoutubePlaylist", sync=True)
    def mpv_open_youtube_playlist(self, args):
        '''(Deprecated) Make a new buffer for a YouTube playlist object'''
        if len(args) == 2:
            playlist, extra = args
        else:
            raise TypeError(f"Expected 2 argument, got {len(args)}")

        self.nvim.loop.create_task(
            open_playlist_results(self.nvim, playlist, extra)
        )

    def show_error(self, error, level=4):
        '''Show an error to nvim'''
        log.error(error)
        self.nvim.async_call(
            self.nvim.api.notify,
            error,
            level,
            {}
        )

    def query_mpvs(self, arg):
        '''
        Interpret a string `arg` as either a buffer number or 'all'.
        Return mpv instances in the buffer, or all of them.
        '''
        if arg == "all":
            return self._mpv_instances.values()
        try:
            buffnum = int(arg)
        except ValueError:
            return []

        return self.get_mpvs_in_buffer(
            buffnum or self.nvim.current.buffer.number
        )

    def get_mpvs_in_buffer(self, buffer):
        '''Get mpv instances that we currently know about'''
        return [
            mpv_instance
            for (i, _), mpv_instance in self._mpv_instances.items()
            if i == buffer
        ]

    def get_mpv_by_line(self, buffer, line):
        '''
        Get the mpv instance on the current line of the buffer, if such an
        instance exists.
        '''
        try_get_mpv = self.nvim.lua.neovimpv.get_player_by_line(
            buffer.number,
            line
        )
        if not try_get_mpv:
            return None

        player_id, _ = try_get_mpv
        return self._mpv_instances[(buffer.number, player_id)]

    def remove_mpv_instance(self, instance):
        '''
        Delete an MpvInstance and its extmark. This is invoked by default when
        the file is closed.
        '''
        try:
            instance.no_draw = True
            self.nvim.lua.neovimpv.remove_player(
                instance.buffer,
                instance.id
            )
            if (instance.buffer, instance.id) in self._mpv_instances:
                del self._mpv_instances[(instance.buffer, instance.id)]
        except pynvim.NvimError as e:
            self.show_error(
                f"Unknown error occurred: could not delete player {instance.buffer}.{instance.id}"
            )
            log.debug(
                "mpv_instances: %s\n" \
                "%s",
                self._mpv_instances,
                e,
                stack_info=True
            )

    def set_new_buffer(self, instance, new_buffer, new_display):
        '''
        Updates the global record of an mpv instance's buffer and display extmark
        '''
        del self._mpv_instances[(instance.buffer, instance.id)]
        instance.buffer = new_buffer
        instance.id = new_display
        self._mpv_instances[(new_buffer, new_display)] = instance
