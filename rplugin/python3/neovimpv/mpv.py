import os.path
import asyncio
import re
import logging

from neovimpv.protocol import create_mpv, MpvError

log = logging.getLogger(__name__)

# the most confusing regex possible: [group1](group2)
MARKDOWN_LINK = re.compile(r"\[([^\[\]]*)\]\(([^()]*)\)")

class MpvInstance:
    '''
    An instance of mpv which is aware of the nvim plugin. Should only be
    instantiated when nvim is available for communication.
    Automatically creates a task for launching the mpv instance.
    '''
    MPV_ARGS = ["--no-video"]
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

        write_markdown = False
        # if we've allowed the current buffer to read/edit things into markdown
        if plugin.nvim.current.buffer.api.get_option("filetype") in plugin.do_markdowns:
            unmarkdown = MARKDOWN_LINK.search(link)
            if unmarkdown:
                link = unmarkdown.group(2)
            else:
                write_markdown = True

        asyncio.create_task(self.spawn(link, mpv_args, write_markdown=write_markdown))

    def toggle_pause(self):
        self.protocol.set_property("pause", not self.protocol.data.get("pause"), update=False)

    def fetch_properties(self):
        '''Fetch all properties being displayed, in case we got desynced'''
        for i in self.plugin.formatter.groups:
            self.protocol.get_property(i, ignore_error=True)

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
        if os.path.exists(file_link := os.path.expanduser(link)):
            link = file_link
        # protocols are 5 characters long at max
        elif len(link.split("://")[0]) <= 5:
            pass
        else:
            self.plugin.show_error("Line does not contain a file path or valid URL")
            return

        ipc_path = os.path.join(self.plugin.mpv_socket_dir, f"{self.id}")

        try:
            _, protocol = await create_mpv(
                self.MPV_ARGS + mpv_args,
                ipc_path,
                read_timeout=timeout_duration,
                loop=self.plugin.nvim.loop
            )
            self.protocol = protocol

            protocol.send_command("loadfile", link)
            # default event handling
            protocol.add_event("property-change", lambda _, __: self.draw_update())
            protocol.add_event("error", lambda _, err: self._show_error(err))
            protocol.add_event("end-file", lambda _, link: self._on_end_file(link))
            protocol.add_event("file-loaded", lambda _, __: self.preamble(link, write_markdown))
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

    def preamble(self, arg, write_markdown):
        '''Subscribe to necessary properties on the mpv IPC.'''
        # ALWAYS observe this so we can toggle pause
        self.protocol.observe_property("pause")
        # observe everything we need to draw the format string
        for i in self.plugin.formatter.groups:
            self.protocol.observe_property(i)
        if write_markdown:
            self.plugin.nvim.loop.create_task(self.update_markdown(arg))

    def close(self):
        '''Defer to the plugin to remove the extmark'''
        self.plugin.nvim.async_call(self.plugin.remove_mpv_instance, self)
