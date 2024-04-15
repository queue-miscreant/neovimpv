import asyncio
import json
import logging
from subprocess import PIPE

log = logging.getLogger(__name__)

class MpvError(Exception):
    pass

class MpvProtocol(asyncio.Protocol):
    '''
    Protocol and storage for interacting with a mpv instance's IPC.
    Supports event callbacks with signature (protocol, data) which can be added with `add_event`.
    '''
    SET = 0
    GET = 1
    def __init__(self):
        self.transport = None
        self.data = {}
        self.ready = asyncio.Event()
        # general properties
        self._properties = {}
        self._reverse_properties = {}
        self._last_property = 20
        # events and async support
        self._event_handlers = {}
        self._waiting_properties = {}
        self._ignore_errors = []
        self._waiting_events = {}
        # playlist support
        self._playlist_request = -1
        self.playlist_new = None
        self.last_playlist_entry_id = -1
        # default events
        self.add_event("property-change", lambda _, data: self._property_change(data))
        self.add_event("start-file", lambda _, data: self._remember_playlist_id(data))
        self.add_event("end-file", lambda _, data: self._try_playlist(data))

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
        Add event handler. All mpv event names are valid, as are "connected", "close", and "error"
        '''
        if event_name not in self._event_handlers:
            self._event_handlers[event_name] = []
        self._event_handlers[event_name].append(func)
        return func

    def _try_handle_event(self, event_name, json_data):
        '''Internal function for calling all event handlers for a given `event_name`'''
        for handler in self._event_handlers.get(event_name, []):
            handler(self, json_data)
        # set futures
        for future in self._waiting_events.get(event_name, []):
            log.info("%s %s %s", event_name, future, future.done())
            if not future.done():
                future.set_result(True)
        self._waiting_events[event_name] = []

        if event_name != "property-change":
            log.info("Received event %s: %s", event_name, json_data)

    def connection_made(self, transport):
        '''Process communication initiated. Save transport and send connected event.'''
        log.debug("Connected to mpv!")
        self.transport = transport
        self.ready.set()
        self._try_handle_event("connected", {})

    def data_received(self, data):
        '''Split out received data into individual JSONs and send to storage'''
        for datum in data.split(b"\n"):
            if not datum.rstrip():
                continue
            # parse response
            datum = json.loads(datum)
            request_id = datum.get("request_id")
            consumed_error = False
            # pop request id from error list
            try:
                self._ignore_errors.remove(request_id)
                consumed_error = True
            except ValueError:
                pass

            # handle response
            if datum.get("error") not in ("success", None):
                if consumed_error:
                    log.debug("Ignoring errorful response %s", datum)
                    continue
                # reverse lookup the property name for convenience
                if (property_name := self._reverse_properties.get(request_id)) is not None:
                    datum.update({"property-name": property_name})
                self._try_handle_event("error", datum)
            elif (event_name := datum.get("event")) is not None:
                self._try_handle_event(event_name, datum)
            elif request_id is not None and request_id in self._reverse_properties:
                # reverse lookup the property name for convenience
                property_name = self._reverse_properties[request_id]
                self.data[property_name] = datum.get("data")
                log.debug("Got property %s: %s", property_name, datum)
            elif request_id is not None and request_id == self._playlist_request:
                self._try_handle_event("got-playlist", {
                    "playlist": datum.get("data"),
                    "new": self.playlist_new
                })
                self._playlist_request = -1
                self.playlist_new = None
            elif request_id is not None and request_id in self._waiting_properties:
                # we received a message about something we're waiting for
                type_, property_name, future = self._waiting_properties[request_id]
                del self._waiting_properties[request_id]

                if type_ == self.GET:
                    self.data[property_name] = datum.get("data")
                    log.debug("Got awaited property %s: %s", property_name, datum)
                    future.set_result(datum.get("data"))
                elif type_ == self.SET:
                    self.data[property_name] = future
                    log.debug("Successfully set %s to %s", property_name, datum)
            else:
                log.debug("Unknown data received from mpv: %s", datum)

    def connection_lost(self, exc):
        '''Process communication closed. Call close event.'''
        self._try_handle_event("close", {})
        for _, __, future in self._waiting_properties.values():
            future.cancel()
        for event in self._waiting_events.values():
            for future in event:
                future.cancel()

    def send_command(self, *args, request_id=0, ignore_error=False):
        '''Write a command to the socket'''
        if self.transport is None or self.transport.is_closing():
            return
        command = {
            "command": args,
            "request_id": request_id,
        }
        if ignore_error:
            self._ignore_errors.append(request_id)
        log.debug("Sent command %s", command)
        self.transport.write((json.dumps(command) + "\n").encode()) # type: ignore

    def get_property(self, property_name, request_id=None, ignore_error=False):
        '''
        Send a command to retrieve a property from the mpv instance.
        Note that this does NOT return the property!
        '''
        if request_id is None:
            request_id = self._property_id(property_name)
        self.send_command(
            "get_property",
            property_name,
            request_id=request_id,
            ignore_error=ignore_error
        )

    async def wait_property(self, property_name, ignore_error=False):
        '''Request property `property_name` and wait for the response from mpv.'''
        future = asyncio.get_event_loop().create_future()
        self._waiting_properties[self._last_property] = (self.GET, property_name, future)

        self.get_property(
            property_name,
            request_id=self._last_property,
            ignore_error=ignore_error
        )
        self._last_property += 1
        return await future

    async def next_event(self, event_name):
        '''Wait for the next event which happens with name `event_name`.'''
        future = asyncio.get_event_loop().create_future()
        if self._waiting_events.get(event_name) is None:
            self._waiting_events[event_name] = []

        self._waiting_events[event_name].append(future)
        return await future

    def fetch_subscribed(self):
        '''Fetch all properties we've sent a request for, if we've gotten desynced'''
        for prop in self._properties:
            self.get_property(prop, ignore_error=True)

    def set_property(self, property_name, value, update=True, ignore_error=False):
        '''Send a command to set a property on the mpv instance.'''
        if not update:
            self.send_command(
                "set_property",
                property_name,
                value,
                ignore_error=ignore_error
            )
            return
        self._waiting_properties[self._last_property] = (self.SET, property_name, value)

        self.send_command(
            "set_property",
            property_name,
            value,
            request_id=self._last_property,
            ignore_error=ignore_error
        )
        self._last_property += 1

    def observe_property(self, property_name, ignore_error=False):
        '''
        Send a command to observe a property from the mpv instance.
        The value in self.data will be updated on "property-change" events.
        '''
        self.send_command(
            "observe_property",
            self._property_id(property_name),
            property_name,
            ignore_error=ignore_error
        )

    def _property_change(self, json_data):
        '''Handler for mpv "property-change" events.'''
        property_name = self._reverse_properties.get(json_data.get("id"))
        data = json_data.get("data")
        if property_name is not None:
            self.data[property_name] = data

    def _remember_playlist_id(self, data):
        '''Remember the last playlist_entry_id for when the file gets loaded'''
        self.last_playlist_entry_id = data.get("playlist_entry_id", -1)

    def _try_playlist(self, json_data):
        '''Handler for file-close events with reason redirect'''
        if json_data.get("reason") != "redirect":
            return
        self._playlist_request = self._last_property
        self.playlist_new = { i: json_data.get(i)
            for i in ["playlist_entry_id", "playlist_insert_id", "playlist_insert_num_entries"] }
        self.get_property("playlist", request_id=self._playlist_request)
        self._last_property += 1
        self._try_handle_event("pre-got-playlist", {})

async def create_mpv(mpv_args, ipc_path, read_timeout=1, loop=None):
    '''
    Create an instance of mpv which uses MpvProtocol for IPC at the UNIX path `ipc_path`
    Returns tuple of asyncio Process and MpvProtocol in use.
    '''
    if loop is None:
        loop = asyncio.get_event_loop()

    process = await asyncio.create_subprocess_exec(
        "mpv",
        *mpv_args,
        f"--input-ipc-server={ipc_path}",
        "--idle=once",
        stdout=PIPE,
    )

    # timeout a read from the subprocess's stdout (for errors)
    assert process.stdout is not None
    try:
        error = await asyncio.wait_for(process.stdout.read(), timeout=read_timeout)
        raise MpvError(error)
    except TimeoutError:
        pass

    try:
        _, protocol = await loop.create_unix_connection(
            MpvProtocol,
            path=ipc_path,
        )
        await asyncio.wait_for(protocol.ready.wait(), timeout=read_timeout)

        return process, protocol
    except ConnectionRefusedError as e:
        raise MpvError("Could not connect to mpv!") from e
    except TimeoutError as e:
        raise MpvError("Timed out connecting to protocol!") from e
