import os.path

from neovimpv.protocol import create_mpv, MpvError

# Relevant highlights:
# "NonText" (dark comments)
# "LineNr"     (comments)
# "Title"      (functions)
# "Directory"  (functions)
# "Conceal"    (self)

EXTMARK_LOADING = {
    "virt_text": [["[ ... ]", "Whitespace"]],
    "virt_text_pos": "eol",
}

def sexagesimalize(number):
    '''Convert a number to decimal-coded sexagesimal (i.e., clock format)'''
    seconds = int(number)
    minutes = seconds // 60
    hours = minutes // 60
    if hours:
        return f"{(hours % 60):0{2}}:{(minutes % 60):0{2}}:{(seconds % 60):0{2}}"
    else:
        return f"{(minutes % 60):0{2}}:{(seconds % 60):0{2}}"

class MpvInstance:
    '''
    An instance of MPV which is aware of the nvim plugin.
    Await `spawn` to create the subprocess and begin communication.
    '''
    # TODO configurable
    MPV_ARGS = ["--no-video"]
    def __init__(self, plugin, buffer, line):
        self.protocol = None

        self.plugin = plugin
        self.buffer = buffer
        self.id = plugin.live_extmark(buffer, EXTMARK_LOADING, line)

    # TODO this should be configurable
    def format_data(self):
        paused = [" || ", "Conceal"] if self.protocol.data.get("pause") \
            else [" |> ", "Title"]
        position = sexagesimalize(self.protocol.data.get("playback-time", 0))
        duration = sexagesimalize(self.protocol.data.get("duration", 0))
        show_loop = ""
        if (loop := self.protocol.data.get("loop")) == "inf":
            show_loop = "∞"
        elif loop:
            show_loop = str(loop)

        return [i for i in [
            ["[", "LineNr"],
            paused,
            [f"{position} ", "Conceal"],
            ["/ ", "LineNr"],
            [f"{duration} ", "Conceal"],
            [f"({show_loop}) ", "LineNr"] if show_loop else None,
            ["]", "LineNr"],
        ] if i]

    def toggle_pause(self):
        self.protocol.set_property("pause", not self.protocol.data.get("pause"), update=False)

    def draw_update(self):
        display = {
            "id": self.id,
            "virt_text": self.format_data(),
            "virt_text_pos": "eol",
        }

        self.plugin.nvim.async_call(
            self.plugin.live_extmark,
            self.buffer.number,
            display
        )

    def write_as_markdown(self, arg):
        media_title = self.protocol.data.get("media-title")
        filename = self.protocol.data.get("filename")
        if media_title == filename:
            return

        self.plugin.nvim.async_call(
            self.plugin.write_line_of_extmark,
            self.buffer,
            self.id,
            [f"[{media_title.replace('[', '(').replace(']',')')}]({arg})"],
        )

    async def spawn(self, arg, timeout_duration=1, has_markdown=True):
        '''
        Spawn subprocess and wait `timeout_duration` seconds for error output.
        If the connection is successful, the instance's `protocol` member will be set
        to an MpvProtocol for IPC.
        '''
        ipc_path = os.path.join(self.plugin.mpv_socket_dir, f"{self.id}")

        try:
            process, protocol = await create_mpv(
                self.MPV_ARGS,
                ipc_path,
                read_timeout=timeout_duration,
                loop=self.plugin.nvim.loop
            )
            self.protocol = protocol

            protocol.send_command("loadfile", os.path.expanduser(arg))
            protocol.add_event("property-change", lambda _, __: self.draw_update())
            # TODO: it would be nice to, if the buffer was unmodified before this, save changes afterward
            if not has_markdown:
                protocol.add_event("playback-restart", lambda _, __: self.write_as_markdown(arg))
            protocol.add_event("error", lambda _, err: self._show_error(err))
            protocol.add_event("end-file", lambda _, arg: self._on_end_file(arg))
            protocol.add_event("file-loaded", lambda _, __: self.preamble())
            protocol.add_event("close", lambda _, __: self.close())
        except MpvError as e:
            self.plugin.show_error(e.args[0])
            if self.id is not None:
                self.close()

    def _show_error(self, err):
        additional_info = ""
        if (property_name := err.get("property-name")) is not None:
            additional_info = f" to request for property '{property_name}'"

        self.plugin.show_error(
            f"MPV responded '{err.get('error')}'{additional_info}",
        )

    def _on_end_file(self, arg):
        if arg.get("reason") == "error" and (error := arg.get("file_error")):
            self.plugin.show_error(f"File ended: {error}")

    def preamble(self):
        self.protocol.observe_property("playback-time")
        self.protocol.observe_property("pause")
        self.protocol.observe_property("loop")
        self.protocol.get_property("duration")
        self.protocol.get_property("filename")
        self.protocol.get_property("media-title")

    def close(self):
        self.plugin.nvim.async_call(self.plugin.remove_mpv_instance, self)
