#!/usr/bin/env python3
# TODO: lines changing around moving opened mpv instances

import os
import os.path
import asyncio
from subprocess import PIPE
import json
import re

import logging
import pynvim

log = logging.getLogger(__file__)
log.setLevel(logging.DEBUG)

# Relevant highlights:
# "NonText" (dark comments)
# "LineNr"     (comments)
# "Title"      (functions)
# "Directory"  (functions)
# "Conceal"    (self)

# the most confusing regex possible: [group1](group2)
MARKDOWN_LINK = re.compile(r"\[([^\[\]]*)\]\(([^()]*)\)")

def try_json(arg):
    '''Attempt to read arg as a JSON object. Return the string on failure'''
    try:
        return json.loads(arg)
    except:
        return arg

def sexagesimalize(number):
    '''Convert a number to decimal-coded sexagesimal (i.e., clock format)'''
    seconds = int(number)
    minutes = seconds // 60
    hours = minutes // 60
    if hours:
        return f"{(hours % 60):0{2}}:{(minutes % 60):0{2}}:{(seconds % 60):0{2}}"
    else:
        return f"{(minutes % 60):0{2}}:{(seconds % 60):0{2}}"

class MpvProtocol(asyncio.Protocol):
    '''
    Protocol for interacting with a MPV instance's IPC. Supports event callbacks with
    signature (protocol, data) which can be added with `add_event`.
    '''
    SET = 0
    GET = 1
    def __init__(self):
        self.transport = None
        self.data = {}

        self._properties = {}
        self._reverse_properties = {}
        self._last_property = 20

        self._event_handlers = {}
        self._waiting_properties = {}
        self.add_event("property-change", lambda _, data: self._property_change(data))

    def _property_id(self, property_name):
        '''Keep records of which properties we've sent before and decided on an ID for.'''
        prop_id = self._properties.get(property_name, self._last_property)
        if prop_id == self._last_property:
            self._properties[property_name] = prop_id
            self._reverse_properties[prop_id] = property_name
            self._last_property += 1
        return prop_id

    def add_event(self, event_name, func):
        '''
        Add event handler. All MPV event names are valid, as are "connected", "close", and "error"
        '''
        if event_name not in self._event_handlers:
            self._event_handlers[event_name] = []
        self._event_handlers[event_name].append(func)
        return func

    def _try_handle_event(self, event_name, json_data):
        '''Internal function for calling all event handlers for a given `event_name`'''
        for handler in self._event_handlers.get(event_name, []):
            handler(self, json_data)
        if event_name != "property-change":
            log.debug(f"Received event '{event_name}': {json_data}")

    def connection_made(self, transport):
        '''Process communication initiated. Save transport and send connected event.'''
        self.transport = transport
        self._try_handle_event("connected", {})

    def data_received(self, data):
        '''Split out received data into individual JSONs and send to storage'''
        for datum in data.split(b"\n"):
            if not datum.rstrip(): continue
            datum = json.loads(datum)
            request_id = datum.get("request_id")

            if datum.get("error") not in ("success", None):
                # reverse lookup the property name for convenience
                if (property_name := self._reverse_properties.get(request_id)) is not None:
                    datum.update({"property-name": property_name})
                self._try_handle_event("error", datum)
                continue
            elif (event_name := datum.get("event")) is not None:
                self._try_handle_event(event_name, datum)
                continue
            elif request_id is not None and request_id in self._reverse_properties:
                # reverse lookup the property name for convenience
                property_name = self._reverse_properties[request_id]
                self.data[property_name] = datum.get("data")
                log.debug(f"Got property {property_name}: {datum}")
            elif request_id is not None and request_id in self._waiting_properties:
                type, property_name, future = self._waiting_properties[request_id]
                if type == self.GET:
                    self.data[property_name] = datum.get("data")
                    log.debug(f"Got awaited property {property_name}: {datum}")
                    future.set_result(datum.get("data"))
                elif type == self.SET:
                    self.data[property_name] = future
                    log.debug(f"Successfully set {property_name} to {datum}")
            else:
                log.debug(f"Unknown data received from MPV: {datum}")

    def connection_lost(self, exc):
        '''Process communication closed. Call close event.'''
        self._try_handle_event("close", {})

    def send_command(self, *args, request_id=0):
        '''Write a command to the socket'''
        command = {
            "command": args,
            "request_id": request_id,
        }
        log.debug(f"Sent command {command}")
        self.transport.write((json.dumps(command) + "\n").encode())

    def get_property(self, property_name, request_id=None):
        '''
        Send a command to retrieve a property from the MPV instance.
        Note that this does NOT return the property!
        '''
        if request_id is None:
            request_id = self._property_id(property_name)
        self.send_command(
            "get_property",
            property_name,
            request_id=request_id,
        )

    def set_property(self, property_name, value, update=True):
        '''Send a command to set a property on the MPV instance.'''
        if not update:
            self.send_command("set_property", property_name, value)
            return
        self._waiting_properties[self._last_property] = (self.SET, property_name, value)

        self.send_command("set_property", property_name, value, request_id=self._last_property)
        self._last_property += 1

    async def wait_property(self, property_name):
        future = asyncio.get_event_loop.create_future()
        self._waiting_properties[self._last_property] = (self.GET, property_name, future)

        self.get_property(property_name, request_id=self._last_property)
        self._last_property += 1
        return await future

    def observe_property(self, property_name):
        '''
        Send a command to observe a property from the MPV instance.
        The value in self.data will be updated on "property-change" events.
        '''
        self.send_command(
            "observe_property",
            self._property_id(property_name),
            property_name,
        )

    def _property_change(self, json_data):
        '''Handler for MPV "property-change" events.'''
        property_name = self._reverse_properties.get(json_data.get("id"))
        data = json_data.get("data")
        if property_name is not None and data is not None:
            self.data[property_name] = data

EXTMARK_LOADING = {
    "virt_text": [["[ ... ]", "Whitespace"]],
    "virt_text_pos": "eol",
}

class MpvInstance:
    '''
    An instance of MPV which is aware of the nvim plugin.
    Await `spawn` to create the subprocess and begin communication.
    '''
    # TODO configurable
    MPV_ARGS = ["mpv", "--no-video"]
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

    #TODO: heuristic timeout (longer for urls)
    async def _spawn(self, arg, timeout_duration, has_markdown):
        '''Backend for `spawn`'''
        ipc_path = os.path.join(self.plugin.mpv_socket_dir, f"{self.id}")
        process = await asyncio.create_subprocess_exec(
            *self.MPV_ARGS,
            f"--input-ipc-server={ipc_path}",
            "--idle=once",
            stdout=PIPE,
        )

        # timeout a read from the subprocess's stdout (for errors)
        read_task = asyncio.create_task(process.stdout.read())
        done, pending = await asyncio.wait(
            [read_task],
            timeout=timeout_duration
        )
        if done:
            error = read_task.result()
            log.debug(error)
            self.plugin.show_error(error)
            return False
        else:
            read_task.cancel()
            try:
                await read_task
            except asyncio.CancelledError:
                pass

        try:
            _, protocol = await self.plugin.nvim.loop.create_unix_connection(
                MpvProtocol,
                path=ipc_path,
            )
        except ConnectionRefusedError:
            self.plugin.show_error("Could not connect to MPV!")
            return False

        self.protocol = protocol
        protocol.send_command("loadfile", os.path.expanduser(arg))
        protocol.add_event("property-change", lambda _, __: self.draw_update())
        if not has_markdown:
            protocol.add_event("playback-restart", lambda _, __: self.write_as_markdown(arg))
        protocol.add_event("error", lambda _, err: self._show_error(err))
        protocol.add_event("end-file", lambda _, arg: self._on_end_file(arg))
        protocol.add_event("file-loaded", lambda _, __: self.preamble())
        protocol.add_event("close", lambda _, __: self.close())

        return True

    async def spawn(self, arg, timeout_duration=1, has_markdown=True):
        '''
        Spawn subprocess and wait `timeout_duration` seconds for error output.
        If the connection is successful, the instance's `protocol` member will be set
        to an MpvProtocol for IPC.
        '''
        success = await self._spawn(arg, timeout_duration, has_markdown)
        if not success and self.id is not None:
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

@pynvim.plugin
class NeoviMPV:
    def __init__(self, nvim):
        self.nvim = nvim
        self._plugin_namespace = nvim.api.create_namespace(self.__class__.__name__)

        # setup temp dir
        tempname = nvim.call("tempname")
        self.mpv_socket_dir = os.path.join(
            os.path.dirname(tempname),
            self.__class__.__name__.lower()
        )
        os.makedirs(self.mpv_socket_dir)

        self._mpv_instances = {}
        # nvim.exec_lua("_export = require('bufchange')")

        self._virtual_text_locked = False
        nvim.exec_lua(
            '''
            function extmark_on_line(buffer, namespace, extmark_ids, target_line)
                for i = 1, #extmark_ids do
                    id = extmark_ids[i]
                    local loc = vim.api.nvim_buf_get_extmark_by_id(buffer, namespace, id, {})
                    if loc[1] == target_line then
                        return id
                    end
                end
                return nil
            end

            function update_extmark(buffer, namespace, extmark_id, content)
                loc = vim.api.nvim_buf_get_extmark_by_id(buffer, namespace, extmark_id, {})
                if loc ~= nil then
                    vim.api.nvim_buf_set_extmark(buffer, namespace, loc[1], loc[2], content)
                end
            end
            '''
        )

    def get_mpv_by_line(self, line, show_error=True):
        '''Get the MPV instance on the current line of the buffer, if such an instance exists.'''
        extmark_id = self.nvim.lua.extmark_on_line(
            self.nvim.current.buffer,
            self._plugin_namespace,
            list(self._mpv_instances.keys()),
            line
        )
        if extmark_id is None:
            if show_error:
                self.show_error("No MPV found running on that line")
            return None
        return self._mpv_instances[extmark_id]

    def remove_mpv_instance(self, instance):
        del self._mpv_instances[instance.id]
        instance.buffer.api.del_extmark(
            self._plugin_namespace,
            instance.id,
        )

    @pynvim.command("MpvOpen", nargs="*", range="")
    def open_in_mpv(self, args, range):
        '''Open current line as a file in MPV. '''
        line = range[0] - 1
        if (target := self.get_mpv_by_line(line, show_error=False)):
            self.show_error("Mpv is already open on this line!")
            return

        link = self.nvim.current.line
        unmarkdown = MARKDOWN_LINK.search(link)
        if unmarkdown:
            link = unmarkdown.group(2)

        target = MpvInstance(
            self,
            self.nvim.current.buffer,
            line,
        )
        asyncio.create_task(
            target.spawn(link, has_markdown=bool(unmarkdown))
        )
        self._mpv_instances[target.id] = target

    @pynvim.command("MpvPause", nargs="*", range="")
    def pause_mpv(self, args, range):
        '''Pause/unpause the MPV instance on the current line'''
        line = range[0] - 1
        if (target := self.get_mpv_by_line(line)):
            target.toggle_pause()

    @pynvim.command("MpvClose", nargs="*", range="")
    def close_mpv(self, args, range):
        '''Close MPV instance on the current line'''
        line = range[0] - 1
        if (target := self.get_mpv_by_line(line)):
            target.protocol.send_command("quit")

    @pynvim.command("MpvSetProperty", nargs="*", range="")
    def mpv_set_property(self, args, range):
        '''Send commands to the MPV instance on the current line'''
        line = range[0] - 1
        if (target := self.get_mpv_by_line(line)):
            target.protocol.set_property(*[try_json(i) for i in args])

    @pynvim.command("MpvSend", nargs="*", range="")
    def send_mpv_command(self, args, range):
        '''Send commands to the MPV instance on the current line'''
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
        self.nvim.lua.update_extmark(buffer, self._plugin_namespace, extmark_id, content)

    def write_line_of_extmark(self, buffer, extmark_id, content):
        '''Write `content` to the line of an extmark with `nvim_buf_set_lines`'''
        line, _ = buffer.api.get_extmark_by_id(self._plugin_namespace, extmark_id, {})

        if line == len(buffer) - 1:
            # hack that I don't like for the last line of the buffer
            buffer.api.set_text(
                line,
                0,
                line,
                len(buffer[line]),
                content,
            )
            return

        buffer.api.set_lines(
            line,
            line+1,
            False,
            content,
        )
