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

    def __init__(self, plugin, buffer, line, link, mpv_args):
        self.protocol = None

        self.plugin = plugin
        self.buffer = buffer
        self.id = plugin.live_extmark(
            buffer,
            {
                "virt_text": [plugin.formatter.loading],
                "virt_text_pos": "eol",
            },
            line
        )

        link, write_markdown = self._unmarkdown(plugin, buffer, link)
        asyncio.create_task(self.spawn(link, mpv_args, write_markdown=write_markdown))

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
        '''Subscribe to necessary properties on the mpv IPC.'''
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
        # ALWAYS observe this so we can toggle pause
        self.protocol.observe_property("pause")
        # observe everything we need to draw the format string
        for i in self.plugin.formatter.groups:
            self.protocol.observe_property(i)
        self.protocol.add_event("property-change", lambda _, __: self.draw_update())

    def close(self):
        '''Defer to the plugin to remove the extmark'''
        self.plugin.nvim.async_call(self.plugin.remove_mpv_instance, self)

# TODO: this should probably be the base class if we're gonna be overriding all of these methods
# clearly update_extmark isn't as useful as I thought it would be
# current ideas: pass in the list of [line number, line] from the very beginning, then filter

# also should draw extmarks (in the sign column?) for mpv playlists. Maybe a new namespace
# Current player status is shown on the correct line, but key redirection is accepted from anywhere in range
class MpvPlaylistInstance(MpvInstance):
    def __init__(self, plugin, buffer, range_, lines, mpv_args):
        new_lines = []
        for i, link in zip(range(range_[0], range_[1] + 1), lines):
            link, write_markdown = self._unmarkdown(plugin, buffer, link)
            link = validate_link(link)
            if link is None:
                continue
            new_lines.append((i, link, write_markdown))
        if not new_lines:
            self.plugin.show_error("Lines do not contain a file path or valid URL")
            return None
        self.lines = new_lines
        self.start, self.end = range_
        self.current = self.lines[0][0]

        super().__init__(plugin, buffer, range_[0], self.lines[0][1], mpv_args)

    def draw_update(self):
        '''Rerender the extmark that this mpv instance corresponds to'''
        # TODO: if windowed display, do nothing but move the line
        display = {
            "id": self.id,
            "virt_text": self.plugin.formatter.format(self.protocol.data),
            "virt_text_pos": "eol",
        }

        self.plugin.nvim.async_call(
            self.buffer.api.set_extmark,
            self.plugin._plugin_namespace,
            self.current,
            0,
            display
        )

    async def spawn(self, link, mpv_args, timeout_duration=1, write_markdown=False):
        await super().spawn(link, mpv_args, timeout_duration, write_markdown)
        for _, link, _ in self.lines[1:]:
            self.protocol.send_command("loadfile", link, "append")
        # TODO: give extmarks to these lines

    def preamble(self, arg, write_markdown, has_video):
        '''Subscribe to necessary properties on the mpv IPC.'''
        line_num, link, markdown = self.lines.pop(0)
        self.current = line_num
        super().preamble(link, markdown, has_video)
