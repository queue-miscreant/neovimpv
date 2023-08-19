import os.path
import asyncio
import re
import logging

from neovimpv.protocol import create_mpv, MpvError

log = logging.getLogger(__name__)

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

    def __init__(self, plugin, buffer, line_range, filenames, extra_args):
        self.protocol = None
        self.plugin = plugin
        self.buffer = buffer

        mpv_args = self.MPV_ARGS + extra_args
        self.no_draw = False
        self.has_window = args_open_window(mpv_args)

        self.id = -1
        self.playlist_ids = []

        playlist = []
        lines_with_links = []
        for i, link in zip(line_range, filenames):
            link, write_markdown = self._unmarkdown(plugin, buffer, link)
            link = validate_link(link)
            if link is None:
                continue
            playlist.append((link, write_markdown))
            lines_with_links.append(i)
        if not playlist:
            self.plugin.show_error(
                "Lines do not contain a file path or valid URL" if len(filenames) > 1 else
                "Line does not contain a file path or valid URL"
            )
            return None
        self.playlist_items = playlist

        self._init_extmarks(lines_with_links)
        plugin.nvim.loop.create_task(self.spawn(mpv_args))

    def _init_extmarks(self, lines):
        '''Create extmarks for displaying data from the mpv instance'''
        self.id, self.playlist_ids = self.plugin.nvim.lua.neovimpv.create_player(self.buffer.number, lines)

    def move_player_extmark(self, playlist_id, show_text=None):
        '''Invoke the Lua callback for moving the player to the line of the extmark playlist_id.'''
        success = self.plugin.nvim.lua.neovimpv.move_player(
            self.buffer,
            self.id,
            playlist_id,
            show_text
        )
        if not success:
            self.plugin.show_error(f"Could not move the player (current file: {self.protocol.data.get('filename')})")
        self.no_draw = False

    def update_playlist(self, new_playlist):
        '''Update the instance's internal playlist and forward deletions to mpv'''
        new_playlist.sort(key=lambda x: self.playlist_ids.index(x))

        removed_indices = []
        new_current = 0
        for old_current, i in enumerate(self.playlist_ids):
            if new_playlist[new_current] == i:
                new_current += 1
                continue
            removed_indices.append(old_current)

        for i in removed_indices:
            self.protocol.send_command("playlist-remove", i)

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
        if self.no_draw or self.has_window:
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

    async def spawn(self, mpv_args, timeout_duration=1):
        '''
        Spawn subprocess and wait `timeout_duration` seconds for error output.
        If the connection is successful, the instance's `protocol` member will be set
        to an MpvProtocol for IPC.
        '''
        ipc_path = os.path.join(self.plugin.mpv_socket_dir, f"{self.id}")
        try:
            _, protocol = await create_mpv(
                mpv_args,
                ipc_path,
                read_timeout=timeout_duration,
                loop=self.plugin.nvim.loop
            )
            self.protocol = protocol
            self.no_draw = True

            # default event handling
            protocol.add_event("error", lambda _, err: self._show_error(err))
            protocol.add_event("end-file", lambda _, arg: self._on_end_file(arg))
            protocol.add_event("file-loaded", lambda _, __: self.preamble())
            protocol.add_event("close", lambda _, __: self.close())
            protocol.add_event("property-change", lambda _, __: self.draw_update())

            # ALWAYS observe this so we can toggle pause
            protocol.observe_property("pause")
            # necessary for retaining playlist position
            protocol.observe_property("playlist-pos")
            # observe everything we need to draw the format string
            for i in self.plugin.formatter.groups:
                protocol.observe_property(i)

            #start playing the files
            for link, _ in self.playlist_items:
                protocol.send_command("loadfile", link, "append-play")
        except MpvError as e:
            self.plugin.show_error(e.args[0])
            log.error("mpv encountered error", exc_info=True)
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

    def preamble(self):
        '''
        Update state after new file loaded.
        Move the player to new playlist item and suspend drawing until complete.
        '''
        self.no_draw = True
        link, write_markdown = self.playlist_items.pop(0)
        current = self.protocol.data.get("playlist-pos")
        if current is None:
            self.plugin.show_error("Playlist transition failed!")
            return

        self.plugin.nvim.async_call(
            self.move_player_extmark,
            self.playlist_ids[current],
            self.has_window and "[ Window ]" or None
        )

        if write_markdown:
            self.plugin.nvim.loop.create_task(self.update_markdown(link))

    def close(self):
        '''Defer to the plugin to remove the extmark'''
        self.protocol.send_command("quit") # just in case
        self.plugin.nvim.async_call(self.plugin.remove_mpv_instance, self)
