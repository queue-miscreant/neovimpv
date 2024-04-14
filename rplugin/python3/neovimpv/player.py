"""
neovimpv.player

Implements a container class which forwards plugin commands to the correct mpv subprocess
wrapper and playlist extmark manager.
"""
import asyncio
import enum
import logging
import os.path
import re

from neovimpv.mpv import MpvPlaylist, MpvWrapper, MpvItem
from neovimpv.protocol import create_mpv, MpvError

log = logging.getLogger(__name__)
log.setLevel("DEBUG")

# TODO: diagram of MpvManager and children


# delay between sending a keypress to mpv and rerequesting properties
KEYPRESS_DELAY = 0.05
DEFAULT_MPV_ARGS = ["--no-video"]

# the most confusing regex possible: [group1](group2)
MARKDOWN_LINK_RE = re.compile(r"\[([^\[\]]*)\]\(([^()]*)\)")
YTDL_YOUTUBE_SEARCH_RE = re.compile(r"^ytdl://\s*ytsearch(\d*):")
LINK_RE = re.compile("(https?://.+?\\.[^`\\s]+)")

class VisualMode(enum.Enum):
    """More idiomatic names from neovim `mode()` responses."""
    VISUAL_RANGE = "v"
    VISUAL_BLOCK = "\x16"
    NONE = None


def find_closest_link(line, column):
    """
    Find the closest LINK_RE match in `line` to the position `column`.
    Returns a 2-tuple of the matching link and whether or not the link was found
    at the start of its line and was the only match.
    """
    i = None
    last = None
    count = 0
    for i in LINK_RE.finditer(line):
        count += 1
        if column < i.start():
            break
        last = i

    if i is None:
        return None, True

    if last is None:
        # only one result
        if count > 0:
            return i.group(), i.start() == 0
        else:
            return None, True
    else:
        dist_from_last = column - last.end()
        dist_to_next = column - i.start()
        if abs(dist_from_last) > abs(dist_to_next):
            return i.group(), False
        else:
            return last.group(), False

# filenames, whether to apply markdown to the line
def links_by_line(line, start_col, end_col):
    '''
    Filter off URLs between start_col and end_col.
    If end_col is None, then no upper bound for the column will be used.
    '''
    ret = [
        match
        for match in LINK_RE.finditer(line)
        if match.end() >= start_col and (
            match.start() < end_col if end_col is not None else True
        )
    ]
    return [i.group() for i in ret], len(ret) == 1 and ret[0].start() == 0

def try_path_and_markdown(line):
    '''
    Attempt to interpret the line as a file path or as markdown.
    If the line is not a valid filename or the markdown match fails, return None.
    '''
    if os.path.exists(file_link := os.path.expanduser(line)):
        return file_link

    try_markdown = MARKDOWN_LINK_RE.search(line)
    if try_markdown:
        return try_markdown.group(2)

    return None

def multi_line(lines, start, end, mode: VisualMode):
    '''
    Construct a dictionary from line numbers to a tuple of a list of files
    and whether or not this is the only openable item on its line
    (in other words, whether overwriting it with markdown is acceptible).
    '''
    start_line, start_col = start
    end_line, end_col = end

    ret = {}
    line_numbers = range(start_line, end_line + 1)
    for line_number, line in zip(line_numbers, lines):
        if (path := try_path_and_markdown(line)):
            ret[line_number] = [path], True
            continue
        links = []
        if line_number == start_line and mode == VisualMode.VISUAL_RANGE:
            links = links_by_line(line, start_col, None)
        elif line_number == end_line and mode == VisualMode.VISUAL_RANGE:
            links = links_by_line(line, 0, end_col)
        elif mode == VisualMode.VISUAL_BLOCK:
            links = links_by_line(line, start_col, end_col)
        else:
            links = links_by_line(line, 0, None)

        if len(links) != 0:
            ret[line_number] = links

    return ret

def parse_mpvopen_args(args: list, playlist_length, default_mpv_args: list):
    '''
    Parse arguments `args` retrieved from MpvOpen.
    Arguments preceding "--", if they exist, are considered local, and
    control local functionality, like determining if dynamic playlists
    should use non-global options.
    '''
    mpv_args = args
    local_args = []
    try:
        split = args.index("--")
        local_args = args[:split]
        mpv_args = args[split+1:]
    except ValueError:
        pass
    mpv_args = default_mpv_args + mpv_args

    update_action = None
    if "stay" in local_args:
        update_action = "stay"
    elif "paste" in local_args:
        update_action = "paste"
    elif "new" in local_args:
        if playlist_length != 1:
            raise ValueError(
                f"Cannot create new buffer for playlist of initial size {len(playlist_length)}!"
            )
        update_action = "new_one"

    if "video" in local_args:
        mpv_args = [i for i in mpv_args if not i.startswith("--vid") and i != "--no-video"]
        mpv_args.append("--video=auto")

    return mpv_args, update_action

def construct_playlist_items(plugin, lines, start_line, end_line, ignore_mode):
    '''
    Read over the list of lines, skipping those which are not files or URLs.
    Make note of which need to be turned into markdown.
    '''
    start = start_line
    end = end_line

    if not ignore_mode:
        log.info("Attempting action based on vim mode")
        vim_mode = plugin.nvim.api.get_mode().get("mode")
        try:
            # Block or visual block modes
            mode = VisualMode(('v', "\x16").index(vim_mode[0]))
            start = plugin.nvim.current.buffer.api.get_mark("<")
            end = plugin.nvim.current.buffer.api.get_mark(">")
            log.info("Creating playlist from visual selection")
            log.debug(
                "lines: %s\nstart: %s\nend: %s\nmode: %s",
                lines,
                start,
                end,
                mode
            )
            return multi_line(lines, start, end, mode)
        except ValueError:
            pass
        if vim_mode == "n" and start_line == end_line:
            new_start_line, start_col = plugin.nvim.current.buffer.api.get_mark(".")
            # If somehow we were given a range without the cursor actually being there,
            # assume the start of the line
            if start_line == new_start_line:
                log.info("Trying path/markdown")
                single_file = try_path_and_markdown(lines[0])
                if single_file is not None:
                    return {start_line: ([single_file], True)}
                log.info("Finding closest link")
                log.debug("line: %s\nstart_col: %s", lines[0], start_col)
                closest_link, has_multiple_links = find_closest_link(lines[0], start_col)
                if closest_link is not None:
                    return {start_line: ([closest_link], not has_multiple_links)}
                log.info("No results found from default action")
                return {}

    log.info("Creating playlist as default")
    log.debug(
        "lines: %s\nstart: %s\nend: %s\nmode: %s",
        lines,
        start_line,
        end_line,
    )
    return multi_line(lines, (start_line, 0), (end_line, None), VisualMode.NONE)

def convert_playlist(playlist, unmarkdown):
    '''
    Convert the playlist from `construct_playlist_items` to a `playlist_id_to_extra_data`
    value for MpvPlaylist. This is a dict of tuples from playlist indices (starting with 1)
    to 3-tuples consisting of (filename, write_markdown, unmarkdown).
    '''
    playlist_id_to_extra_data = {}

    file_index = 1
    for line_number, (files, markdown_on_line) in playlist.items():
        for file in files:
            playlist_id_to_extra_data[file_index] = (
                file,
                unmarkdown and markdown_on_line,
                unmarkdown and markdown_on_line,
            )
            file_index += 1

    return playlist_id_to_extra_data

def construct_mpv_to_extmark_map(preliminary_playlist, lines_ids_zip):
    '''
    Convert the playlist from `construct_playlist_items` to a `playlist_id_to_extmark_id`
    value for MpvPlaylist. This is a dict of tuples from playlist indices (starting with 1)
    to extmark indices.
    '''
    file_index = 1
    playlist_id_to_extmark_id = {}
    for line, extmark in lines_ids_zip:
        for file in preliminary_playlist[line][0]:
            playlist_id_to_extmark_id[file_index] = extmark
            file_index += 1

    return playlist_id_to_extmark_id

def construct_mpv_item_map(preliminary_playlist, lines_ids_zip):
    '''
    Convert the playlist from `construct_playlist_items` to a `playlist_id_to_extmark_id`
    value for MpvPlaylist. This is a dict of tuples from playlist indices (starting with 1)
    to extmark indices.
    '''
    file_index = 1
    playlist_id_to_item = {}
    for line, extmark_id in lines_ids_zip:
        files, rewritable_line = preliminary_playlist[line]
        for file in files:
            playlist_id_to_item[file_index] = MpvItem(
                filename = file,
                extmark_id = extmark_id,
                update_markdown = rewritable_line,
                show_currently_playing = not rewritable_line,
            )
            file_index += 1

    return playlist_id_to_item

def try_smart_youtube(filename):
    '''
    Attempt to generate a "smart Youtube" playlist update action.
    This pastes the first result of "ytsearch://" URLs over the original contents of the line.
    Otherwise, results are opened in a new buffer inside a split.
    '''
    is_search = YTDL_YOUTUBE_SEARCH_RE.match(filename)
    if is_search and is_search.group(1) in ("", "1"):
        return "paste"
    return "new_one"

def create_managed_mpv(
    plugin,
    line_data,
    start_line,
    end_line,
    extra_args,
    ignore_mode,
):
    '''
    Create a MpvManager instance from line data and ranges from the nvim plugin.
    This also spawns a task for creating an mpv subprocess and opening a communication channel.

    The plugin MUST be in a state where its `current` data is accessible, for example, when
    using async_call or in a command callback.
    '''
    current_buffer = plugin.nvim.current.buffer.number
    current_filetype = plugin.nvim.current.buffer.api.get_option("filetype")

    preliminary_playlist = construct_playlist_items(
        plugin,
        line_data,
        start_line,
        end_line,
        ignore_mode
    )
    if len(preliminary_playlist) == 0:
        plugin.show_error(
            ("Lines do" if start_line != end_line else "Line does") + \
            " not contain a file path or valid URL"
        )
        return None

    playlist_lines = list(preliminary_playlist.keys())
    playlist_lines.sort()
    player_id, playlist_extmark_ids = plugin.nvim.lua.neovimpv.create_player(
        current_buffer,
        playlist_lines # only the line number, not the file name
    )

    playlist = MpvPlaylist(
        playlist_id_to_extra_data = convert_playlist(
            preliminary_playlist,
            current_filetype in plugin.do_markdowns,
        ),
        # This is also used to construct the mpv playlist in the subprocess!
        playlist_id_to_extmark_id = construct_mpv_to_extmark_map(
            preliminary_playlist,
            zip(playlist_lines, playlist_extmark_ids)
        )
    )

    # Update actions and "smart youtube"-ness
    update_action = plugin.on_playlist_update
    if plugin.smart_youtube and len(playlist.playlist_id_to_extmark_id) == 1:
        update_action = try_smart_youtube(playlist.playlist_id_to_extra_data[1][0])

    target = MpvManager(
        plugin,
        current_buffer,
        player_id,
        playlist,
        update_action,
        extra_args,
    )
    plugin.nvim.loop.create_task(target.spawn())

    return target


class MpvManager:
    '''
    Manager for an mpv instance, containing options and arguments particular to it.
    '''
    MPV_ARGS = []
    @classmethod
    def set_default_args(cls, new_args):
        '''Set the default arguments to be used by new mpv instances'''
        cls.MPV_ARGS = DEFAULT_MPV_ARGS + new_args

    def __init__(
        self,
        plugin,
        buffer,
        player_id,
        playlist: MpvPlaylist,
        update_action,
        extra_args
    ):
        self.plugin = plugin
        self.buffer = buffer
        self.id = player_id
        self.mpv = None

        self._mpv_args = []
        self._not_spawning_player = asyncio.Event()
        self._not_spawning_player.set()
        self._transitioning_players = False

        self.playlist = playlist

        self._mpv_args, new_update_action = parse_mpvopen_args(
            extra_args,
            len(self.playlist),
            self.MPV_ARGS
        )
        self.update_action = update_action if new_update_action is None else new_update_action

    async def spawn(self, timeout_duration=1):
        '''
        Spawn subprocess and wait `timeout_duration` seconds for error output.
        If the connection is successful, the instance's `protocol` member will be set
        to an MpvProtocol for IPC.
        '''
        self._not_spawning_player.clear()

        ipc_path = os.path.join(self.plugin.mpv_socket_dir, f"{self.id}")
        try:
            _, protocol = await create_mpv(
                self._mpv_args,
                ipc_path,
                read_timeout=timeout_duration,
                loop=self.plugin.nvim.loop
            )
        except MpvError as e:
            self.plugin.show_error(e.args[0])
            log.error("mpv encountered error", exc_info=True)
            self.mpv = None
            self._not_spawning_player.set()
            return

        log.debug("Spawned mpv with args %s", self._mpv_args)

        self.mpv = MpvWrapper(
            self,
            protocol,
        )
        self._not_spawning_player.set()

    # ==========================================================================
    # Convenience functions for accessing from nvim.plugin
    # ==========================================================================

    def send_command(self, command_name, *args):
        '''Send a command to the mpv subprocess.'''
        if self.mpv is None:
            self.plugin.show_error("Mpv not ready yet!")
            return

        self.mpv.protocol.send_command(command_name, *args)

    def set_property(self, property_name, value, update=True, ignore_error=False):
        '''Set a property on the mpv subprocess.'''
        if self.mpv is None:
            self.plugin.show_error("Mpv not ready yet!")
            return
        self.mpv.protocol.set_property(property_name, value, update, ignore_error) # just in case

    async def wait_property(self, command_name, *args):
        '''Asynchronously request a property on the mpv subprocess.'''
        if self.mpv is None:
            self.plugin.show_error("Mpv not ready yet!")
            return

        return await self.mpv.protocol.wait_property(command_name, *args)

    async def send_keypress(self, keypress, ignore_error=False, count=1):
        '''Send a keypress and wait for its properties to be updated.'''
        if keypress == "q":
            await self.close_async()
            return

        if self.mpv is None:
            self.plugin.show_error("Mpv not ready yet!")
            return

        for _ in range(count):
            self.mpv.protocol.send_command("keypress", keypress, ignore_error=ignore_error)

        # some delay is necessary for the keypress to take effect
        await asyncio.sleep(KEYPRESS_DELAY)
        self.mpv.protocol.fetch_subscribed()

    def toggle_pause(self):
        '''Attempt to pause/unpause the mpv subprocess.'''
        if self.mpv is None:
            self.plugin.show_error("Mpv not ready yet!")
            return

        self.mpv.protocol.set_property(
            "pause",
            not self.mpv.protocol.data.get("pause"),
            update=False
        )

    async def toggle_video(self):
        '''Close mpv, then reopen with the same playlist and with video'''
        if self._transitioning_players:
            self.plugin.show_error("Already attempting to show video!")
            return
        if self.mpv is None:
            self.plugin.show_error("Mpv not ready yet!")
            return

        track_list = await self.mpv.protocol.wait_property("track-list")
        has_video_track = any(map(lambda x: x.get("type") == "video", track_list))
        if has_video_track:
            log.info("Player has video track. Cycling video instead.")
            self.mpv.protocol.send_command("cycle", "video")
            return

        current_position = await self.mpv.protocol.wait_property("playlist-pos")
        current_time = await self.mpv.protocol.wait_property("playback-time")
        old_playlist = self.mpv.protocol.data.get("playlist", [])

        log.info("Beginning transition...")
        self._transitioning_players = True
        self.mpv.protocol.send_command("quit")
        # Draw a filler line
        self.playlist.reorder_by_index(old_playlist)
        await self.mpv.protocol.next_event("close")
        self.plugin.nvim.async_call(self.mpv._draw_update, "")

        log.info("Spawning player...")
        self._mpv_args += ["--video=auto"]
        await self.spawn()
        self._transitioning_players = False

        log.info(
            "Transition finished! Setting playlist index to %s...",
            current_position
        )
        self.mpv.protocol.send_command("playlist-play-index", current_position)
        self.mpv.protocol.get_property("playlist")

        log.info("Waiting for file to be loaded...")
        await self.mpv.protocol.next_event("file-loaded")

        log.info("File loaded! Seeking...")
        self.mpv.protocol.send_command("seek", current_time)

    async def set_current_by_playlist_extmark(self, extmark_id):
        '''Set the current file to the mpv file specified by the extmark `playlist_item`'''
        await self._not_spawning_player.wait()
        if self.mpv is None:
            self.plugin.show_error("Could not set playlist index! Mpv is closed.")
            return

        self.playlist.set_current_by_playlist_extmark(self.mpv, extmark_id)

    async def forward_deletions(self, removed_items):
        '''Forward deletions to mpv'''
        await self._not_spawning_player.wait()
        if self.mpv is None:
            self.plugin.show_error("Could not forward deletions! Mpv is closed.")
            return

        self.playlist.forward_deletions(self.mpv, removed_items)

    async def close_async(self):
        '''Defer to the plugin to remove the extmark'''
        await self._not_spawning_player.wait()
        if self.mpv is not None:
            self.mpv.protocol.send_command("quit") # just in case

        self.plugin.nvim.async_call(self.plugin.remove_mpv_instance, self)

    def close(self):
        '''Defer to the plugin to remove the extmark'''
        self.plugin.nvim.loop.create_task(self.close_async())
