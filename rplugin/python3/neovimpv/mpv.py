import os.path
import asyncio
import re
import logging

from neovimpv.protocol import create_mpv, MpvError

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

# the most confusing regex possible: [group1](group2)
MARKDOWN_LINK = re.compile(r"\[([^\[\]]*)\]\(([^()]*)\)")
DEFAULT_MPV_ARGS = ["--no-video"]

def args_open_window(args):
    '''Determine whether a list of arguments will open an mpv window'''
    for arg in reversed(args):
        if arg in ("--vid=no", "--video=no", "--no-video"):
            return False
        if arg in ("--vid=auto", "--video=auto"):
            return True
    return False

def validate_link(link):
    if os.path.exists(file_link := os.path.expanduser(link)):
        return file_link
    # protocols are 5 characters long at max
    if 0 <= link.find("://") <= 5:
        return link
    return None

class MpvInstance:
    '''
    An instance of mpv which is aware of the nvim plugin. Should only be
    instantiated when nvim is available for communication.
    Automatically creates a task for launching the mpv instance.
    '''
    MPV_ARGS = None
    @classmethod
    def setDefaultArgs(cls, new_args):
        '''Set the default arguments to be used by new mpv instances'''
        cls.MPV_ARGS = DEFAULT_MPV_ARGS + new_args

    def __init__(self, plugin, buffer, lines, link, mpv_args):
        self.protocol = None

        self.plugin = plugin
        self.buffer = buffer

        self.id = -1
        self.playlist_ids = []
        self._init_extmarks(lines)

        self.no_draw = False

        link, write_markdown = self._unmarkdown(plugin, buffer, link)
        asyncio.create_task(self.spawn(link, mpv_args, write_markdown=write_markdown))

    def _init_extmarks(self, lines):
        '''Create extmarks for displaying data from the mpv instance'''
        self.id, self.playlist_ids = self.plugin.nvim.lua.neovimpv.create_player(self.buffer.number, lines)

    def update_playlist(self, new_playlist):
        new_playlist.sort(key=lambda x: self.playlist_ids.index(x))
        self.playlist_ids = new_playlist

    @staticmethod
    def _unmarkdown(plugin, buffer, link):
        write_markdown = False
        # if we've allowed this buffer to read/edit things into markdown
        if buffer.api.get_option("filetype") in plugin.do_markdowns:
            unmarkdown = MARKDOWN_LINK.search(link)
            if unmarkdown:
                link = unmarkdown.group(2)
            else:
                write_markdown = True
        return link, write_markdown

    def toggle_pause(self):
        self.protocol.set_property("pause", not self.protocol.data.get("pause"), update=False)

    def draw_update(self):
        '''Rerender the extmark that this mpv instance corresponds to'''
        if self.no_draw:
            return
        display = {
            "id": self.id,
            "virt_text": self.plugin.formatter.format(self.protocol.data),
            "virt_text_pos": "eol",
        }

        self.plugin.nvim.async_call(
            self.plugin.live_extmark,
            self.buffer.number,
            display
        )

    async def update_markdown(self, arg):
        '''
        Wait until we've got the title and filename, then format the line where
        mpv is being displayed as markdown.
        '''
        media_title = await self.protocol.wait_property("media-title")
        filename = await self.protocol.wait_property("filename")
        if media_title == filename:
            return

        self.plugin.nvim.async_call(
            self.plugin.write_line_of_extmark,
            self.buffer,
            self.id,
            [f"[{media_title.replace('[', '(').replace(']',')')}]({arg})"],
        )

    async def spawn(self, link, mpv_args, timeout_duration=1, write_markdown=False):
        '''
        Spawn subprocess and wait `timeout_duration` seconds for error output.
        If the connection is successful, the instance's `protocol` member will be set
        to an MpvProtocol for IPC.
        '''
        # don't try to open non-files
        if (link := validate_link(link)) is None:
            self.plugin.show_error("Line does not contain a file path or valid URL")
            self.close()
            return

        ipc_path = os.path.join(self.plugin.mpv_socket_dir, f"{self.id}")
        args = self.MPV_ARGS + mpv_args
        has_video = args_open_window(args)

        try:
            _, protocol = await create_mpv(
                args,
                ipc_path,
                read_timeout=timeout_duration,
                loop=self.plugin.nvim.loop
            )
            self.protocol = protocol

            protocol.send_command("loadfile", link)
            # default event handling
            protocol.add_event("error", lambda _, err: self._show_error(err))
            protocol.add_event("end-file", lambda _, arg: self._on_end_file(arg))
            protocol.add_event("file-loaded", lambda _, __: self.preamble(link, write_markdown, has_video))
            protocol.add_event("close", lambda _, __: self.close())
            # ALWAYS observe this so we can toggle pause
            protocol.observe_property("pause")
            # observe everything we need to draw the format string
            for i in self.plugin.formatter.groups:
                protocol.observe_property(i)
            protocol.add_event("property-change", lambda _, __: self.draw_update())
        except MpvError as e:
            self.plugin.show_error(e.args[0])
            log.error("mpv encountered error", exc_info=True)
            if self.id is not None:
                self.close()

    def _show_error(self, err):
        '''Report error contents to nvim'''
        additional_info = ""
        if (property_name := err.get("property-name")) is not None:
            additional_info = f" to request for property '{property_name}'"

        self.plugin.show_error(
            f"mpv responded '{err.get('error')}'{additional_info}",
        )

    def _on_end_file(self, arg):
        '''Report an error to nvim if the file ended because of an error.'''
        if arg.get("reason") == "error" and (error := arg.get("file_error")):
            self.plugin.show_error(f"File ended: {error}")

    def preamble(self, arg, write_markdown, has_video):
        '''Update state after new file loaded'''
        if write_markdown:
            self.plugin.nvim.loop.create_task(self.update_markdown(arg))
        if has_video:
            self.plugin.nvim.async_call(
                self.plugin.live_extmark,
                self.buffer.number,
                {
                    "id": self.id,
                    "virt_text": [self.plugin.formatter.external],
                    "virt_text_pos": "eol",
                }
            )
            return

    def close(self):
        '''Defer to the plugin to remove the extmark'''
        self.plugin.nvim.async_call(self.plugin.remove_mpv_instance, self)

# TODO: this should probably be the base class if we're gonna be overriding all of these methods
class MpvPlaylistInstance(MpvInstance):
    def __init__(self, plugin, buffer, range_, lines, mpv_args):
        playlist = []
        line_numbers = []
        for i, link in zip(range(range_[0], range_[1] + 1), lines):
            link, write_markdown = self._unmarkdown(plugin, buffer, link)
            link = validate_link(link)
            if link is None:
                continue
            playlist.append((link, write_markdown))
            line_numbers.append(i)
        if not playlist:
            self.plugin.show_error("Lines do not contain a file path or valid URL")
            return None
        self.playlist_items = playlist
        self.current = 0

        super().__init__(
            plugin,
            buffer,
            line_numbers,
            self.playlist_items[0][0],
            mpv_args
        )

    async def spawn(self, link, mpv_args, timeout_duration=1, write_markdown=False):
        await super().spawn(link, mpv_args, timeout_duration, write_markdown)
        for link, _ in self.playlist_items[1:]:
            self.protocol.send_command("loadfile", link, "append")
        self.protocol.observe_property("playlist-pos")

    def preamble(self, arg, write_markdown, has_video):
        '''Transition the player to the next playlist item. Suspend drawing until move_player_extmark returns'''
        link, markdown = self.playlist_items.pop(0)
        self.current = self.protocol.data.get("playlist-pos")
        self.plugin.nvim.async_call(
            self.move_player_extmark,
            self.playlist_ids[self.current]
        )
        self.no_draw = True
        super().preamble(link, markdown, has_video)

    def move_player_extmark(self, playlist_id):
        '''Invoke the Lua callback for moving the player to the line of the extmark playlist_id.'''
        success = self.plugin.nvim.lua.neovimpv.move_player(
            self.buffer,
            self.id,
            playlist_id
        )
        not success
        self.no_draw = False

    def update_playlist(self, new_playlist):
        old = self.playlist_ids
        super().update_playlist(new_playlist)

        removed_indices = []
        new_current = 0
        for old_current, i in enumerate(old):
            if self.playlist_ids[new_current] == i:
                new_current += 1
                continue
            removed_indices.append(old_current)

        for i in removed_indices:
            self.protocol.send_command("playlist-remove", i)
