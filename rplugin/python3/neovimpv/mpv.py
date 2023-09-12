import os.path
import asyncio
import re
import logging

from neovimpv.protocol import create_mpv, MpvError

log = logging.getLogger(__name__)

# the most confusing regex possible: [group1](group2)
MARKDOWN_LINK = re.compile(r"\[([^\[\]]*)\]\(([^()]*)\)")
YTDL_YOUTUBE_SEARCH = re.compile(r"^ytdl://\s*ytsearch(\d*):")
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

    def __init__(self, plugin, buffer, filenames, line_numbers, extra_args, unmarkdown=False):
        self.protocol = None
        self.plugin = plugin
        self.buffer = buffer
        self.id = -1

        self.playlist = MpvPlaylist(self, filenames, line_numbers, unmarkdown)
        if not self.playlist:
            self.plugin.show_error(
                "Lines do not contain a file path or valid URL" if len(filenames) > 1 else
                "Line does not contain a file path or valid URL"
            )

        mpv_args = self._parse_args(extra_args)
        self.has_window = args_open_window(mpv_args)
        self.no_draw = False

        plugin.nvim.loop.create_task(self.spawn(mpv_args))

    def _parse_args(self, args):
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

        if "stay" in local_args:
            self.playlist.update_action = "stay"
        elif "paste" in local_args:
            self.playlist.update_action = "paste"
        elif "new" in local_args:
            if len(self.playlist) != 1:
                raise ValueError(
                    f"Cannot create new buffer for playlist of initial size {len(self.playlist)}!"
                )
            self.playlist.update_action = "new_one"

        if "video" in local_args:
            mpv_args += "--video=auto"

        return self.MPV_ARGS + mpv_args

    def _draw_update(self):
        '''Rerender the player extmark to which this mpv instance corresponds'''
        if self.no_draw:
            return

        display = {
            "id": self.id,
            "virt_text": self.plugin.formatter.format(self.protocol.data),
            "virt_text_pos": "eol",
        }

        if self.has_window:
            display["virt_text"] = [["[ Window ]", "MpvDefault"]]
            self.no_draw = True

        # this method is called asynchronously, so protect against errors
        try:
            self.plugin.nvim.lua.neovimpv.update_extmark(
                self.buffer,
                self.id,
                display
            )
        except:
            pass

    # ==========================================================================
    # The following methods do not assume that nvim is in an interactable state
    # ==========================================================================

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

            log.debug("Spawned mpv with args %s", mpv_args)
            # default event handling
            protocol.add_event("error", lambda _, err: self._show_error(err))
            protocol.add_event("end-file", lambda _, arg: self._on_end_file(arg))
            protocol.add_event("file-loaded", lambda _, data: self._preamble(data))
            protocol.add_event("close", lambda _, __: self.close())
            protocol.add_event(
                "property-change",
                lambda _, __: self.plugin.nvim.async_call(self._draw_update)
            )
            protocol.add_event("got-playlist", lambda _, data: self.playlist.update(data))

            # ALWAYS observe this so we can toggle pause
            protocol.observe_property("pause")
            # necessary for retaining playlist position
            protocol.observe_property("playlist")
            # observe everything we need to draw the format string
            for i in self.plugin.formatter.groups:
                protocol.observe_property(i)

            #start playing the files
            for _, file in sorted(self.playlist.mpv_id_to_extra_data.items(), key=lambda x: x[0]):
                protocol.send_command("loadfile", file[0], "append-play")
        except MpvError as e:
            self.plugin.show_error(e.args[0])
            log.error("mpv encountered error", exc_info=True)
            self.close()

    async def update_markdown(self, link, playlist_id):
        '''
        Wait until we've got the title and filename, then format the line where
        mpv is being displayed as markdown.
        '''
        media_title = await self.protocol.wait_property("media-title")
        filename = await self.protocol.wait_property("filename")
        if media_title == filename:
            return

        self.plugin.nvim.async_call(
            lambda x,y,z: self.plugin.nvim.lua.neovimpv.write_line_of_playlist_item(x,y,z),
            self.buffer,
            playlist_id,
            f"[{media_title.replace('[', '(').replace(']',')')}]({link})"
        )

    def toggle_pause(self):
        self.protocol.set_property("pause", not self.protocol.data.get("pause"), update=False)

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

    def _preamble(self, data):
        '''
        Update state after new file loaded.
        Move the player to new playlist item and suspend drawing until complete.
        '''
        self.no_draw = True
        current_mpv_id = self.protocol.last_playlist_entry_id
        override_markdown = False
        redirected_mpv_id = self.playlist.mpv_id_remap.get(current_mpv_id)
        if redirected_mpv_id is not None:
            self.plugin.nvim.async_call(
                self.playlist.update_currently_playing,
                current_mpv_id,
                redirected_mpv_id
            )
            # use the extmark of this mpv id to move the player
            current_mpv_id = redirected_mpv_id
            override_markdown = True
        elif current_mpv_id not in self.playlist.mpv_id_to_extmark_id:
            self.plugin.show_error("Playlist transition failed!")
            log.debug(
                "Playlist transition failed! Mpv id %s does not exist in %s",
                current_mpv_id,
                self.playlist.mpv_id_to_extmark_id
            )
            self.no_draw = False
            return

        self.plugin.nvim.async_call(self.playlist.move_player_extmark, current_mpv_id)

        filename, write_markdown, _ = self.playlist.mpv_id_to_extra_data[current_mpv_id]
        if write_markdown and not override_markdown:
            self.plugin.nvim.loop.create_task(self.update_markdown(
                filename,
                self.playlist.mpv_id_to_extmark_id[current_mpv_id]
            ))

    def close(self):
        '''Defer to the plugin to remove the extmark'''
        self.protocol.send_command("quit") # just in case
        self.plugin.nvim.async_call(self.plugin.remove_mpv_instance, self)

    async def close_async(self, sleep_duration_seconds=0.1):
        '''Wait for mpv to be open for communication, then close it'''
        while self.protocol is None or self.protocol.transport is None:
            await asyncio.sleep(sleep_duration_seconds)
        self.close()


class MpvPlaylist:
    '''
    Object containing state about current state of an mpv playlist.
    Responsible for remembering how to map mpv ids to extmark ids in nvim.
    '''
    def __init__(self, parent, filenames, line_numbers, unmarkdown):
        self.parent = parent

        self.mpv_id_to_extmark_id = {}      # mapping from mpv ids to playlist extmark ids
        self.mpv_id_to_extra_data = {}      # extra data about initial information provided, like whether to
                                            #   replace a line with markdown when we get a title
        self.mpv_id_remap = {}              # remaps from one mpv id to another
        self.update_action = self.parent.plugin.on_playlist_update

        playlist_item_lines = self._construct_playlist(filenames, line_numbers, unmarkdown)
        if not playlist_item_lines:
            return None
        log.debug("Found playlist items: %s", self.mpv_id_to_extra_data)
        self._init_extmarks(playlist_item_lines)

    def __len__(self):
        # number of extmarks plus number of remaps minus unique remap targets
        return len(self.mpv_id_to_extmark_id) + \
                len(self.mpv_id_remap) - \
                len(set(self.mpv_id_remap.values()))

    def _construct_playlist(self, filenames, line_numbers, unmarkdown):
        '''
        Read over the list of lines, skipping those which are not files or URLs.
        Make note of which need to be turned into markdown.
        '''
        playlist = {}
        playlist_item_lines = []
        for i, (line_number, filename) in enumerate(zip(line_numbers, filenames)):
            write_markdown = False
            # if we've allowed this buffer to read/edit things into markdown
            if unmarkdown:
                try_markdown = MARKDOWN_LINK.search(filename)
                if try_markdown:
                    filename = try_markdown.group(2)
                else:
                    write_markdown = True
            filename = validate_link(filename)
            if filename is None:
                continue
            playlist[i + 1] = (filename, write_markdown, unmarkdown)
            playlist_item_lines.append(line_number)
        self.mpv_id_to_extra_data = playlist

        if len(playlist) == 1 and self.parent.plugin.smart_youtube:
            self._try_smart_youtube(playlist[1][0])

        return playlist_item_lines

    def _init_extmarks(self, lines):
        '''Create extmarks for displaying data from the mpv instance'''
        self.parent.id, playlist_ids = self.parent.plugin.nvim.lua.neovimpv.create_player(
            self.parent.buffer,
            [i for i in lines] # only the line number, not the file name
        )
        # initial mpv ids are 1-indexed, but match the playlist
        self.mpv_id_to_extmark_id = {(i + 1): j for i, j in enumerate(playlist_ids)}
        log.debug(
            "Initialized extmarks!\n" \
            "mpv_id_to_extmark_id = %s",
            self.mpv_id_to_extmark_id
        )

    def move_player_extmark(self, playlist_mpv_id, show_text=None):
        '''Invoke the Lua callback for moving the player to the line of a playlist extmark.'''
        log.debug(
            "Moving player!\n" \
            "playlist_mpv_id: %s\n" \
            "mpv_id_to_extmark_id: %s\n" \
            "mpv_id_remap: %s",
            playlist_mpv_id,
            self.mpv_id_to_extmark_id,
            self.mpv_id_remap,
        )
        success = self.parent.plugin.nvim.lua.neovimpv.move_player(
            self.parent.buffer,
            self.parent.id,
            self.mpv_id_to_extmark_id[playlist_mpv_id],
            show_text
        )
        if not success:
            try:
                filename = self.mpv_id_to_extra_data[playlist_mpv_id][0]
            except IndexError:
                filename = None
            self.parent.plugin.show_error(f"Could not move the player (current file: {filename})!")
            log.debug(
                "Could not move the player!\n" \
                "filename: %s\n" \
                "playlist_mpv_id: %s\n" \
                "playlist: %s",
                filename,
                playlist_mpv_id,
                self.parent.protocol.data.get('playlist')
            )
        self.parent.no_draw = False

    def update_currently_playing(self, current_mpv_id, redirected_mpv_id):
        '''Invoke the Lua callback for updating the currently playing text'''
        playlist = self.parent.protocol.data.get("playlist", [])
        current_title = next(
            (item.get("title") for item in playlist if item.get("id") == current_mpv_id),
            None
        )
        playlist_item = self.mpv_id_to_extmark_id.get(redirected_mpv_id)
        log.debug(
            "Updating currently playing!\n" \
            "current_mpv_id: %s, current_title: %s\n" \
            "redirected_mpv_id: %s\n" \
            "mpv_id_to_extmark_id: %s\n",
            current_mpv_id, current_title,
            redirected_mpv_id,
            self.mpv_id_to_extmark_id,
        )

        self.parent.plugin.nvim.lua.neovimpv.show_playlist_current(
            self.parent.buffer,
            playlist_item,
            current_title
        )

    def _paste_playlist(self, new_playlist, playlist_mpv_id):
        '''Paste the playlist items on top of the playlist'''
        # make sure we get the right index for currently-playing
        playlist_current = next(
            (i for i, j in enumerate(new_playlist) if j.get("current")),
            None
        )
        # get markdown, if applicable
        use_markdown = self.mpv_id_to_extra_data.get(playlist_mpv_id, ["", False, False])[2]
        write_lines = [i["filename"] for i in new_playlist] if not use_markdown \
            else [
                f"[{i['title'].replace('[', '(').replace(']',')')}]({i['filename']})"
                for i in new_playlist
            ]
        log.debug(
            "Pasting new playlist!\n" \
            "write_lines: %s",
            write_lines
        )

        new_extmarks = self.parent.plugin.nvim.lua.neovimpv.paste_playlist(
            self.parent.buffer,
            self.parent.id,
            self.mpv_id_to_extmark_id.get(playlist_mpv_id),
            write_lines,
            playlist_current + 1,
        )
        self.parent.no_draw = False

        # bind the new extmarks to their mpv ids
        for mpv, extmark_id in zip(new_playlist, new_extmarks):
            self.mpv_id_to_extmark_id[mpv["id"]] = extmark_id
            self.mpv_id_to_extra_data[mpv["id"]] = (mpv["filename"], False, use_markdown)

    def _new_playlist_buffer(self, new_playlist, playlist_mpv_id):
        '''Create a new buffer and paste the playlist items'''
        # get markdown, if applicable
        use_markdown = self.mpv_id_to_extra_data.get(playlist_mpv_id, ["", False, False])[2]
        write_lines = [i["filename"] for i in new_playlist] if not use_markdown \
            else [
                f"[{i['title'].replace('[', '(').replace(']',')')}]({i['filename']})"
                for i in new_playlist
            ]
        log.debug(
            "Pasting new playlist!\n" \
            "write_lines: %s",
            write_lines
        )

        new_buffer_id, new_display, new_extmarks = \
            self.parent.plugin.nvim.lua.neovimpv.new_playlist_buffer(
                self.parent.buffer,
                self.parent.id,
                self.mpv_id_to_extmark_id.get(playlist_mpv_id),
                write_lines
            )
        log.debug(
            "Got new playlist buffer\n" \
            "new_buffer_id: %s\n" \
            "new_display: %s\n" \
            "new_extmarks: %s",
            new_buffer_id,
            new_display,
            new_extmarks
        )

        self.parent.plugin.set_new_buffer(self.parent, new_buffer_id, new_display)

        # bind the new extmarks to their mpv ids
        self.mpv_id_to_extmark_id.clear()
        self.mpv_id_to_extra_data.clear()
        for mpv, extmark_id in zip(new_playlist, new_extmarks):
            self.mpv_id_to_extmark_id[mpv["id"]] = extmark_id
            self.mpv_id_to_extra_data[mpv["id"]] = (mpv["filename"], False, use_markdown)

    # ==========================================================================
    # The following methods do not assume that nvim is in an interactable state
    # ==========================================================================

    def update(self, data):
        '''
        Update state after playlist loaded.
        The playlist retrieved from MpvProtocol is raw, so we need to do a bit of extra processing.
        '''
        log.debug(
            "Got updated playlist!\n" \
            "playlist: %s",
            data
        )

        # the mpv video id which triggered the new playlist
        # should correspond to the index in self.mpv_id_to_extmark_id
        original_entry = data["new"]["playlist_entry_id"]
        start = data["new"]["playlist_insert_id"]
        end = start + data["new"]["playlist_insert_num_entries"]

        # "stay" if we've been told to or we're not a single playlist
        do_stay = self.update_action == "stay" or \
                len(self.mpv_id_to_extmark_id) > 1 and self.update_action in ("paste_one", "new_one")

        if do_stay:
            for i in range(start, end):
                self.mpv_id_remap[i] = original_entry
        elif self.update_action in ("paste", "paste_one"):
            self.parent.no_draw = True
            self.parent.plugin.nvim.async_call(
                self._paste_playlist,
                [i for i in data["playlist"] if i["id"] in range(start, end)],
                original_entry,
            )
        elif self.update_action == "new_one":
            self.parent.plugin.nvim.async_call(
                self._new_playlist_buffer,
                [i for i in data["playlist"] if i["id"] in range(start, end)],
                original_entry,
            )

    def set_current_by_playlist_extmark(self, playlist_item):
        '''Set the current file to the mpv file specified by the extmark `playlist_item`'''
        # try to remap the extmark to the one it came from
        try_remap = next(
            (j for i, j in self.mpv_id_remap.items() if j == playlist_item),
            playlist_item
        )
        # then get the mpv id from it
        mpv_id = next(
            (i for i,j in self.mpv_id_to_extmark_id.items() if j == playlist_item),
            None
        )
        # then index into the current playlist
        playlist = self.parent.protocol.data.get("playlist", [])
        if len(playlist) <= 1:
            self.parent.plugin.show_error("Refusing to set playlist index on small playlist!", 3)
            log.debug("Refusing to set playlist index on small playlist!")
            return

        index = next((index
            for index, item in enumerate(playlist)
            if item["id"] == mpv_id
        ), None)

        log.debug(
            "Setting current playlist item!\n" \
            "playlist_item: %s\n" \
            "try_remap: %s\n" \
            "mpv_id: %s\n" \
            "index: %s",
            playlist_item,
            try_remap,
            mpv_id,
            index,
        )

        if index is None:
            self.parent.plugin.show_error("Could not find mpv item!")
            return

        self.parent.protocol.send_command("playlist-play-index", index)

    def forward_deletions(self, removed_items):
        '''Forward deletions to mpv'''
        mpv_ids = [i for i,j in self.mpv_id_to_extmark_id.items() if j in removed_items]

        # reverse-lookup for remapped extmarks
        static_deletions = [j for i in removed_items for j, k in self.mpv_id_remap.items() if k == i]
        mpv_ids += static_deletions

        # get deleted indexes
        removed_indices = [index
            for index, item in enumerate(self.parent.protocol.data.get("playlist", []))
            if item["id"] in mpv_ids
        ]

        log.debug(
            "Removing mpv ids!\n" \
            "mpv_ids: %s\n" \
            "playlist: %s",
            mpv_ids,
            self.parent.protocol.data.get('playlist')
        )

        removed_indices.sort(reverse=True)
        for index in removed_indices:
            self.parent.protocol.send_command("playlist-remove", index)

    def _try_smart_youtube(self, filename):
        '''Smart Youtube playlist actions: typically `new_one` and `stay`'''
        is_search = YTDL_YOUTUBE_SEARCH.match(filename)
        if is_search and is_search.group(1) in ("", "1"):
            self.update_action = "stay"
            return
        self.update_action = "new_one"
