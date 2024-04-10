import os.path
import asyncio
import re
import logging

from neovimpv.protocol import create_mpv, MpvError, MpvProtocol

# TODO: strange delay between Mpvopen and extmarks created
# TODO: move things into MpvWrapper?
# TODO: diagram of MpvManager and children
# TODO: 0:00 time appears for too long in extmark
# TODO: fix omnikey shenanigans

log = logging.getLogger(__name__)
log.setLevel("DEBUG")

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

class MpvWrapper:
    '''
    An instance of mpv which is aware of the nvim plugin. Should only be
    instantiated when nvim is available for communication.
    Automatically creates a task for launching the mpv instance.
    '''
    def __init__(self, manager, protocol: MpvProtocol, mpv_args: list):
        self.manager = manager
        self.protocol = protocol

        self._mpv_args = mpv_args
        self.no_draw = False
        self._old_video = False
        self._transitioning_players = False

        self._add_events()
        self._load_playlist(manager.playlist)

    def _add_events(self):
        # default event handling
        self.protocol.add_event("error", lambda _, err: self._show_error(err))
        self.protocol.add_event("end-file", lambda _, arg: self._on_end_file(arg))
        self.protocol.add_event("file-loaded", lambda _, data: self._preamble(data))
        self.protocol.add_event("close", lambda _, __: self.close(False))
        self.protocol.add_event(
            "property-change",
            lambda _, __: self.manager.plugin.nvim.async_call(self._draw_update)
        )
        self.protocol.add_event("got-playlist", lambda _, data: self.manager.playlist.update(data))

        # ALWAYS observe this so we can toggle pause
        self.protocol.observe_property("pause")
        # necessary for retaining playlist position
        self.protocol.observe_property("playlist")
        # for drawing [Window] instead, toggling video
        self.protocol.observe_property("video")
        # observe everything we need to draw the format string
        for i in self.manager.plugin.formatter.groups:
            self.protocol.observe_property(i)

    def _load_playlist(self, playlist):
        log.info("Loading playlist!")
        log.debug(list(playlist.playlist_id_to_extra_data.items()))

        #start playing the files
        for _, file in sorted(playlist.playlist_id_to_extra_data.items(), key=lambda x: x[0]):
            self.protocol.send_command("loadfile", file[0], "append-play")

    def _draw_update(self):
        '''Rerender the player extmark to which this mpv instance corresponds'''
        video = self.protocol.data.get("video")
        if self.no_draw or (video and self._old_video):
            return
        self._old_video = video

        display = {
            "id": self.manager.id,
            "virt_text_pos": "eol",
        }

        if video:
            display["virt_text"] = [["[ Window ]", "MpvDefault"]]
        elif self._transitioning_players:
            display["virt_text"] = None
        else:
            display["virt_text"] = self.manager.plugin.formatter.format(self.protocol.data)

        # this method is called asynchronously, so protect against errors
        try:
            self.manager.plugin.nvim.lua.neovimpv.update_extmark(
                self.manager.buffer,
                self.manager.id,
                display
            )
        except:
            pass

    # ==========================================================================
    # The following methods do not assume that nvim is in an interactable state
    # ==========================================================================

    async def update_markdown(self, link, playlist_id):
        '''
        Wait until we've got the title and filename, then format the line where
        mpv is being displayed as markdown.
        '''
        media_title = await self.protocol.wait_property("media-title")
        filename = await self.protocol.wait_property("filename")
        if media_title == filename:
            return

        self.manager.plugin.nvim.async_call(
            lambda x,y,z: self.manager.plugin.nvim.lua.neovimpv.write_line_of_playlist_item(x,y,z),
            self.manager.buffer,
            playlist_id,
            f"[{media_title.replace('[', '(').replace(']',')')}]({link})"
        )

    def _show_error(self, err):
        '''Report error contents to nvim'''
        additional_info = ""
        if (property_name := err.get("property-name")) is not None:
            additional_info = f" to request for property '{property_name}'"

        self.manager.plugin.show_error(
            f"mpv responded '{err.get('error')}'{additional_info}",
        )
        log.error("Error occurred: %s", err)

    def _on_end_file(self, arg):
        '''Report an error to nvim if the file ended because of an error.'''
        if arg.get("reason") == "error" and (error := arg.get("file_error")):
            self.manager.plugin.show_error(f"File ended: {error}")

    def _preamble(self, data):
        '''
        Update state after new file loaded.
        Move the player to new playlist item and suspend drawing until complete.
        '''
        self.no_draw = True
        current_playlist_id = self.protocol.last_playlist_entry_id
        override_markdown = False
        redirected_playlist_id = self.manager.playlist.playlist_id_remap.get(current_playlist_id)
        if redirected_playlist_id is not None:
            self.manager.plugin.nvim.async_call(
                self.manager.playlist.update_currently_playing,
                current_playlist_id,
                redirected_playlist_id
            )
            # use the extmark of this mpv id to move the player
            current_playlist_id = redirected_playlist_id
            override_markdown = True
        elif current_playlist_id not in self.manager.playlist.playlist_id_to_extmark_id:
            self.manager.plugin.show_error("Playlist transition failed!")
            log.debug(
                "Playlist transition failed! Mpv id %s does not exist in %s",
                current_playlist_id,
                self.manager.playlist.playlist_id_to_extmark_id
            )
            self.no_draw = False
            return

        self.manager.plugin.nvim.async_call(
            self.manager.playlist.move_player_extmark,
            current_playlist_id
        )

        filename, write_markdown, _ = self.manager.playlist.playlist_id_to_extra_data[current_playlist_id]
        if write_markdown and not override_markdown:
            self.manager.plugin.nvim.loop.create_task(self.update_markdown(
                filename,
                self.manager.playlist.playlist_id_to_extmark_id[current_playlist_id]
            ))

    def set_property(self, property_name, value, update=True, ignore_error=False):
        '''Check that the protocol is defined'''
        if self._transitioning_players:
            return
        self.protocol.set_property(property_name, value, update, ignore_error) # just in case

    def close(self, force=True):
        '''Defer to the plugin to remove the extmark'''
        if self._transitioning_players and not force:
            return
        self.protocol.send_command("quit") # just in case
        self.manager.plugin.nvim.async_call(self.manager.plugin.remove_mpv_instance, self.manager)


class MpvPlaylist:
    '''
    Object containing state about current state of an mpv playlist.
    Responsible for remembering how to map mpv ids to extmark ids in nvim.
    '''
    def __init__(
        self,
        manager,
        playlist_item_lines,
        playlist_id_to_extra_data,
        playlist_id_to_extmark_id
    ):
        self.manager = manager

        # line numbers of each element of the playlist
        self.playlist_item_lines = playlist_item_lines
        # extra data about initial information provided, like whether to
        #   replace a line with markdown when we get a title
        self.playlist_id_to_extra_data = playlist_id_to_extra_data
        # mapping from mpv playlist ids to extmark playlist ids
        self.playlist_id_to_extmark_id = playlist_id_to_extmark_id

        # remaps from one mpv id to another
        self.playlist_id_remap = {}
        # for "stay" mode, map the old playlist id to first new item
        self._updated_indices = {}

        # temporary object containing `playlist_id_to_extra_data` for reopening the player
        self._new_extra_data = None
        # dict mapping filenames to titles, in case we have to reopen the player
        self._loaded_titles = {}

    def __len__(self):
        # number of extmarks plus number of remaps minus unique remap targets
        return len(self.playlist_id_to_extmark_id) + \
                len(self.playlist_id_remap) - \
                len(set(self.playlist_id_remap.values()))

    def reorder_by_index(self, old_playlist):
        '''Reorder playlist_ids by their index in the playlist'''
        new_remap = {}
        new_extmark_ids = {}
        mapped = set()
        for i, item in enumerate(old_playlist):
            playlist_id = item.get("id")
            if playlist_id in self.playlist_id_remap:
                new_remap[i + 1] = self.playlist_id_remap[playlist_id]
                mapped.add(self.playlist_id_remap[playlist_id])
            if playlist_id in self.playlist_id_to_extmark_id:
                new_extmark_ids[i + 1] = self.playlist_id_to_extmark_id[playlist_id]

        for i in mapped:
            find_remap = next(
                (new_playlist_id for new_playlist_id, extmark_id in new_remap.items() if extmark_id == i),
                None
            )
            if find_remap is not None:
                new_extmark_ids[find_remap] = i

        log.info("Reordered playlist!")
        log.debug("playlist_id_remap: %s\nnew_extmark_ids: %s", new_remap, new_extmark_ids)

        if self._new_extra_data is not None:
            self.playlist_id_to_extra_data = self._new_extra_data
            self._new_extra_data = None

        self.playlist_id_remap = new_remap
        self.playlist_id_to_extmark_id = new_extmark_ids
        self._updated_indices.clear()

    def move_player_extmark(self, playlist_id, show_text=None):
        '''Invoke the Lua callback for moving the player to the line of a playlist extmark.'''
        log.debug(
            "Moving player!\n" \
            "playlist_id: %s\n" \
            "playlist_id_to_extmark_id: %s\n" \
            "playlist_id_remap: %s",
            playlist_id,
            self.playlist_id_to_extmark_id,
            self.playlist_id_remap,
        )
        success = self.manager.plugin.nvim.lua.neovimpv.move_player(
            self.manager.buffer,
            self.manager.id,
            self.playlist_id_to_extmark_id[playlist_id],
            show_text
        )
        if not success:
            try:
                filename = self.playlist_id_to_extra_data[playlist_id][0]
            except IndexError:
                filename = None
            self.manager.plugin.show_error(f"Could not move the player (current file: {filename})!")
            log.debug(
                "Could not move the player!\n" \
                "filename: %s\n" \
                "playlist_id: %s\n" \
                "playlist: %s",
                filename,
                playlist_id,
                # TODO: protocol access
                self.manager.mpv.protocol.data.get('playlist')
            )
        # TODO: mpv access
        self.manager.mpv.no_draw = False
        self.manager.mpv._old_video = False

    def update_currently_playing(self, current_playlist_id, redirected_playlist_id):
        '''Invoke the Lua callback for updating the currently playing text'''
        # TODO: protocol access
        playlist = self.manager.mpv.protocol.data.get("playlist", [])
        current_title = next(
            # attempt to get the title of the content
            # if it's been loaded before, use the entry specified by the filename as backup
            (item.get("title", self._loaded_titles.get(item.get("filename")))
                for item in playlist if item.get("id") == current_playlist_id),
            None
        )
        log.debug(
            "current_playlist_id: %s\n" \
            "redirected_playlist_id: %s\n" \
            "playlist: %s\n",
            current_playlist_id,
            redirected_playlist_id,
            playlist
        )

        extmark_id = self.playlist_id_to_extmark_id.get(redirected_playlist_id)
        log.info("Updating currently playing!")
        log.debug(
            "current_playlist_id: %s, current_title: %s\n" \
            "redirected_playlist_id: %s\n" \
            "playlist_id_to_extmark_id: %s\n",
            current_playlist_id, current_title,
            redirected_playlist_id,
            self.playlist_id_to_extmark_id,
        )

        if current_title is None:
            log.info(
                "Currently playing title is None.\nIgnoring currently playing update!"
            )
            return

        if extmark_id is None:
            self.manager.plugin.show_error("Error updating currently playing title!")
            log.error("Could not find extmark id from mpv playlist_id")
            return

        self.manager.plugin.nvim.lua.neovimpv.show_playlist_current(
            self.manager.buffer,
            extmark_id,
            current_title
        )

    def _paste_playlist(self, new_playlist, playlist_id):
        '''Paste the playlist items on top of the playlist'''
        # make sure we get the right index for currently-playing
        playlist_current = next(
            (i for i, j in enumerate(new_playlist) if j.get("current")),
            None
        )
        if playlist_current is None:
            self.manager.plugin.log_error("Could not get current playlist index!")
            return

        # get markdown, if applicable
        use_markdown = self.playlist_id_to_extra_data.get(playlist_id, ["", False, False])[2]
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

        new_extmarks = self.manager.plugin.nvim.lua.neovimpv.paste_playlist(
            self.manager.buffer,
            self.manager.id,
            self.playlist_id_to_extmark_id.get(playlist_id),
            write_lines,
            playlist_current + 1,
        )
        self.manager.mpv.no_draw = False

        # bind the new extmarks to their mpv ids
        for mpv, extmark_id in zip(new_playlist, new_extmarks):
            self.playlist_id_to_extmark_id[mpv["id"]] = extmark_id
            self.playlist_id_to_extra_data[mpv["id"]] = (mpv["filename"], False, use_markdown)

    def _new_playlist_buffer(self, new_playlist, playlist_id):
        '''Create a new buffer and paste the playlist items'''
        # get markdown, if applicable
        use_markdown = self.playlist_id_to_extra_data.get(playlist_id, ["", False, False])[2]
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
            self.manager.plugin.nvim.lua.neovimpv.new_playlist_buffer(
                self.manager.buffer,
                self.manager.id,
                self.playlist_id_to_extmark_id.get(playlist_id),
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

        self.manager.plugin.set_new_buffer(self.manager, new_buffer_id, new_display)

        # bind the new extmarks to their mpv ids
        self.playlist_id_to_extmark_id.clear()
        self.playlist_id_to_extra_data.clear()
        for playlist_item, extmark_id in zip(new_playlist, new_extmarks):
            self.playlist_id_to_extmark_id[playlist_item["id"]] = extmark_id
            self.playlist_id_to_extra_data[playlist_item["id"]] = (
                playlist_item["filename"],
                False,
                use_markdown
            )

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
        # should correspond to the index in self.playlist_id_to_extmark_id
        original_entry = data["new"]["playlist_entry_id"]
        start = data["new"]["playlist_insert_id"]
        end = start + data["new"]["playlist_insert_num_entries"]

        # "stay" if we've been told to or we're not a single playlist
        do_stay = self.manager.update_action == "stay" or \
                len(self.playlist_id_to_extmark_id) > 1 and self.manager.update_action in ("paste_one", "new_one")

        # map the old playlist id to the first item in the new one
        self._updated_indices[original_entry] = start

        # prepare for the user reopening the player for video
        new_extra_data = {}
        for i, playlist_entry in enumerate(data["playlist"]):
            if (playlist_id := playlist_entry["id"]) not in range(start, end):
                # Carry over the old playlist
                new_extra_data[i + 1] = self.playlist_id_to_extra_data.get(playlist_id)
                continue
            # add in the new playlist items
            new_extra_data[i + 1] = [
                playlist_entry["filename"],
                False,
                False
            ]
            self._loaded_titles[playlist_entry["filename"]] = playlist_entry["title"]

        self._new_extra_data = new_extra_data

        log.info("Prepared extra data from playlist update!")
        log.debug("_new_extra_data: %s", self._new_extra_data)

        if do_stay:
            # add remaps (i.e., old playlist id to new playlist id)
            for i in range(start, end):
                self.playlist_id_remap[i] = original_entry
        elif self.manager.update_action in ("paste", "paste_one"):
            self.manager.mpv.no_draw = True
            self.manager.plugin.nvim.async_call(
                self._paste_playlist,
                [i for i in data["playlist"] if i["id"] in range(start, end)],
                original_entry,
            )
        elif self.manager.update_action == "new_one":
            self.manager.plugin.nvim.async_call(
                self._new_playlist_buffer,
                [i for i in data["playlist"] if i["id"] in range(start, end)],
                original_entry,
            )

    def set_current_by_playlist_extmark(self, extmark_id):
        '''Set the current file to the mpv file specified by the extmark `playlist_item`'''
        # try to remap the extmark to the one it came from
        try_remap = next(
            (j for i, j in self.playlist_id_remap.items() if j == extmark_id),
            extmark_id
        )
        # then get the mpv id from it
        playlist_id = next(
            (i for i, j in self.playlist_id_to_extmark_id.items() if j == try_remap),
            None
        )

        # adjustment for updated playlists
        if playlist_id in self._updated_indices:
            playlist_id = self._updated_indices[playlist_id]

        # then index into the current playlist
        playlist = self.manager.mpv.protocol.data.get("playlist", [])
        if len(playlist) <= 1:
            self.manager.parent.plugin.show_error("Refusing to set playlist index on small playlist!", 3)
            return

        playlist_index = next((index
            for index, item in enumerate(playlist)
            if item["id"] == playlist_id
        ), None)

        log.debug(
            "Setting current playlist item!\n" \
            "extmark_id: %s\n" \
            "try_remap: %s\n" \
            "playlist_id: %s\n" \
            "playlist_index: %s",
            extmark_id,
            try_remap,
            playlist_id,
            playlist_index,
        )

        if playlist_index is None:
            self.manager.plugin.show_error("Could not find mpv item!")
            log.error("Entry %s does not exist in playlist!\n%s", playlist_id, playlist)
            return

        self.manager.mpv.protocol.send_command("playlist-play-index", playlist_index)

    def forward_deletions(self, removed_items):
        '''Forward deletions to mpv'''
        playlist_ids = [i for i,j in self.playlist_id_to_extmark_id.items() if j in removed_items]

        # reverse-lookup for remapped extmarks
        static_deletions = [j for i in removed_items for j, k in self.playlist_id_remap.items() if k == i]
        playlist_ids += static_deletions

        # get deleted indexes
        removed_indices = [index
            for index, item in enumerate(self.manager.mpv.protocol.data.get("playlist", []))
            if item["id"] in playlist_ids
        ]

        log.debug(
            "Removing mpv ids!\n" \
            "playlist_ids: %s\n" \
            "playlist: %s",
            playlist_ids,
            self.manager.mpv.protocol.data.get('playlist')
        )

        removed_indices.sort(reverse=True)
        for index in removed_indices:
            self.manager.mpv.protocol.send_command("playlist-remove", index)

class MpvManager:
    '''
    Manager for an mpv instance, containing options and arguments particular to it.
    '''
    MPV_ARGS = []
    @classmethod
    def set_default_args(cls, new_args):
        '''Set the default arguments to be used by new mpv instances'''
        cls.MPV_ARGS = DEFAULT_MPV_ARGS + new_args

    def __init__(self, plugin, buffer, filenames, line_numbers, unmarkdown):
        self.mpv = None
        self.plugin = plugin
        self.buffer = buffer
        self.id = -1

        self.update_action = plugin.on_playlist_update
        self.playlist = self._construct_playlist(filenames, line_numbers, unmarkdown)
        if self.playlist is None:
            return None
        log.debug("Found playlist items: %s", self.playlist.playlist_id_to_extra_data)

    def _construct_playlist(self, filenames, line_numbers, unmarkdown):
        '''
        Read over the list of lines, skipping those which are not files or URLs.
        Make note of which need to be turned into markdown.
        Based on these lines, create extmarks and a playlist manager.
        '''
        playlist_id_to_extra_data = {}
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
            playlist_id_to_extra_data[i + 1] = (filename, write_markdown, unmarkdown)
            playlist_item_lines.append(line_number)

        if len(playlist_id_to_extra_data) == 1 and self.plugin.smart_youtube:
            self._try_smart_youtube(playlist_id_to_extra_data[1][0])

        if not playlist_item_lines:
            self.plugin.show_error(
                ("Lines do" if len(filenames) > 1 else "Line does") + \
                " not contain a file path or valid URL"
            )
            return None

        playlist_id_to_extmark_id = self._init_extmarks(playlist_item_lines)

        return MpvPlaylist(
            self,
            playlist_item_lines,
            playlist_id_to_extra_data,
            playlist_id_to_extmark_id
        )

    def _try_smart_youtube(self, filename):
        '''Smart Youtube playlist actions: typically `new_one` and `paste`'''
        is_search = YTDL_YOUTUBE_SEARCH.match(filename)
        if is_search and is_search.group(1) in ("", "1"):
            self.update_action = "paste"
            return
        self.update_action = "new_one"

    def _init_extmarks(self, playlist_item_lines):
        '''Create extmarks for displaying data from the mpv instance'''
        self.id, playlist_ids = self.plugin.nvim.lua.neovimpv.create_player(
            self.buffer,
            [i for i in playlist_item_lines] # only the line number, not the file name
        )
        # initial mpv ids are 1-indexed, but match the playlist
        playlist_id_to_extmark_id = {(i + 1): j for i, j in enumerate(playlist_ids)}

        log.debug(
            "Initialized extmarks!\n" \
            "playlist_id_to_extmark_id = %s",
            playlist_id_to_extmark_id
        )
        return playlist_id_to_extmark_id

    def _parse_args(self, args, playlist_length):
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
        mpv_args = self.MPV_ARGS + mpv_args

        if "stay" in local_args:
            self.update_action = "stay"
        elif "paste" in local_args:
            self.update_action = "paste"
        elif "new" in local_args:
            if playlist_length != 1:
                raise ValueError(
                    f"Cannot create new buffer for playlist of initial size {len(playlist_length)}!"
                )
            self.update_action = "new_one"

        if "video" in local_args:
            mpv_args = [i for i in mpv_args if not i.startswith("--vid") and i != "--no-video"]
            mpv_args.append("--video=auto")

        return mpv_args

    async def spawn(self, extra_args, timeout_duration=1):
        '''
        Spawn subprocess and wait `timeout_duration` seconds for error output.
        If the connection is successful, the instance's `protocol` member will be set
        to an MpvProtocol for IPC.
        '''
        assert self.playlist is not None
        mpv_args = self._parse_args(extra_args, len(self.playlist))

        ipc_path = os.path.join(self.plugin.mpv_socket_dir, f"{self.id}")
        try:
            _, protocol = await create_mpv(
                mpv_args,
                ipc_path,
                read_timeout=timeout_duration,
                loop=self.plugin.nvim.loop
            )
        except MpvError as e:
            self.plugin.show_error(e.args[0])
            log.error("mpv encountered error", exc_info=True)
            # TODO: close
            # self.close()
            return

        log.debug("Spawned mpv with args %s", mpv_args)

        self.mpv = MpvWrapper(
            self,
            protocol,
            mpv_args,
        )

    def toggle_pause(self):
        if self.mpv is None:
            self.plugin.show_error("Mpv not ready yet!")
            return

        self.mpv.protocol.set_property("pause", not self.mpv.protocol.data.get("pause"), update=False)

    async def toggle_video(self):
        '''Close mpv, then reopen with the same playlist and with video'''
        if self._transitioning_players:
            self.plugin.show_error("Already attempting to show video!")
            return
        if self.mpv is None:
            self.plugin.show_error("Mpv not ready yet!")
            return

        # TODO better principles for mpv.protocol
        track_list = await self.mpv.protocol.wait_property("track-list")
        has_video_track = any(map(lambda x: x.get("type") == "video", track_list))
        if has_video_track:
            log.info("Player has video track. Cycling video instead.")
            self.mpv.protocol.send_command("cycle", "video")
            self._old_video = False
            self.mpv._draw_update()
            return

        current_position = await self.mpv.protocol.wait_property("playlist-pos")
        current_time = await self.mpv.protocol.wait_property("playback-time")
        old_playlist = self.mpv.protocol.data.get("playlist", [])

        log.info("Beginning transition...")
        self._transitioning_players = True
        self.mpv.protocol.send_command("quit")
        self.mpv._draw_update()
        self.mpv.manager.playlist.reorder_by_index(old_playlist)
        await asyncio.sleep(0.1)

        log.info("Spawning player...")
        # TODO: location of mpv_args
        await self.spawn(self.mpv._mpv_args + ["--video=auto"])
        self._transitioning_players = False
        self._old_video = False
        self.mpv._draw_update()

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
