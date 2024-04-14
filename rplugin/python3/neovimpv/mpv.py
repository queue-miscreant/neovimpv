"""
neovimpv.mpv

Implements a plugin-aware container for an mpv asyncio protocol object and a manager
for playlist extmarks.
"""
import logging

from typing import TYPE_CHECKING
from neovimpv.protocol import MpvProtocol

if TYPE_CHECKING:
    from neovimpv.player import MpvManager

log = logging.getLogger(__name__)
log.setLevel("DEBUG")

class MpvWrapper:
    '''
    An instance of mpv which is aware of the nvim plugin. Should only be
    instantiated when nvim is available for communication.
    Automatically creates a task for launching the mpv instance.
    '''
    def __init__(self, manager: "MpvManager", protocol: MpvProtocol):
        self.manager = manager
        self.protocol = protocol

        self.no_draw = True

        self._add_events()
        self._load_playlist(manager.playlist)

    def _add_events(self):
        # default event handling
        self.protocol.add_event("error", lambda _, err: self._show_error(err))
        self.protocol.add_event("end-file", lambda _, arg: self._on_end_file(arg))
        self.protocol.add_event("start-file", lambda _, data: self._on_start_file(data))
        self.protocol.add_event("file-loaded", lambda _, __: self._preamble())
        self.protocol.add_event("close", lambda _, __: self.manager.close())
        self.protocol.add_event(
            "property-change",
            lambda _, __: self.manager.plugin.nvim.async_call(self._draw_update)
        )
        self.protocol.add_event(
            "got-playlist",
            lambda _, data: self.manager.playlist.update(self, data)
        )

        # ALWAYS observe this so we can toggle pause
        self.protocol.observe_property("pause")
        # necessary for retaining playlist position
        self.protocol.observe_property("playlist")
        # for drawing [Window] instead, toggling video
        self.protocol.observe_property("video-format")
        # observe everything we need to draw the format string
        for i in self.manager.plugin.formatter.groups:
            self.protocol.observe_property(i)

    def _load_playlist(self, playlist):
        log.info("Loading playlist!")
        log.debug(list(playlist.playlist_id_to_extra_data.items()))

        #start playing the files
        for _, file in sorted(playlist.playlist_id_to_extra_data.items(), key=lambda x: x[0]):
            self.protocol.send_command("loadfile", file[0], "append-play")

    def _draw_update(self, force_virt_text=None):
        '''Rerender the player extmark to which this mpv instance corresponds'''
        if self.no_draw and force_virt_text is None:
            return

        display = {
            "id": self.manager.id,
            "virt_text_pos": "eol",
        }

        video = bool(self.protocol.data.get("video-format"))
        if force_virt_text is not None:
            display["virt_text"] = force_virt_text
        elif video:
            display["virt_text"] = [["[ Window ]", "MpvDefault"]]
        else:
            display["virt_text"] = self.manager.plugin.formatter.format(self.protocol.data)

        # _draw_update is called asynchronously, so protect against errors from this call
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

    async def try_update_markdown(self, playlist_id):
        '''
        Wait until we've got the title and filename, then format the line where
        mpv is being displayed as markdown.
        '''
        extmark_id = self.manager.playlist.playlist_id_to_extmark_id.get(playlist_id)
        if extmark_id is None:
            self.manager.plugin.show_error("Playlist transition failed!")
            log.debug(
                "Playlist transition failed! Mpv id %s does not exist in %s",
                playlist_id,
                self.manager.playlist.playlist_id_to_extmark_id
            )
            return

        link, write_markdown, _ = self.manager.playlist.playlist_id_to_extra_data[playlist_id]

        media_title = await self.protocol.wait_property("media-title")
        filename = await self.protocol.wait_property("filename")
        if not write_markdown or media_title == filename or "(" in link or ")" in link:
            return

        self.manager.plugin.nvim.async_call(
            self.manager.plugin.nvim.lua.neovimpv.write_line_of_playlist_item,
            self.manager.buffer,
            extmark_id,
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
        self.no_draw = True
        self.manager.plugin.nvim.async_call(self._draw_update, "")
        if arg.get("reason") == "error" and (error := arg.get("file_error")):
            self.manager.plugin.show_error(f"File ended: {error}")

    def _on_start_file(self, arg):
        '''
        Update state after new file started.
        Move the player to new playlist item and suspend drawing until complete.
        '''
        # Starting the file is enough information to move the player, but not enough
        # to update the title of the video.
        self.no_draw = True
        current_playlist_id = arg.get("playlist_entry_id")

        if (
            self.protocol.playlist_new is not None
            and current_playlist_id == self.protocol.playlist_new.get("playlist_insert_id")
        ):
            return
        redirected_playlist_id = self.manager.playlist.playlist_id_remap.get(current_playlist_id)
        # use the extmark of this mpv id to move the player
        if redirected_playlist_id is not None:
            current_playlist_id = redirected_playlist_id

        self.manager.plugin.nvim.async_call(
            self.manager.playlist.move_player_extmark,
            self,
            current_playlist_id
        )

    def _preamble(self):
        '''Update buffer text after new file loaded.'''
        # Have enough information to update with video title
        current_playlist_id = self.protocol.last_playlist_entry_id
        extra_data = self.manager.playlist.playlist_id_to_extra_data.get(current_playlist_id)
        redirected_playlist_id = self.manager.playlist.playlist_id_remap.get(current_playlist_id)
        if extra_data is not None and extra_data[2] == "STAY":
            self.manager.plugin.nvim.async_call(
                self.manager.playlist.update_currently_playing,
                self,
                current_playlist_id,
                None,
            )
        elif redirected_playlist_id is not None:
            self.manager.plugin.nvim.async_call(
                self.manager.playlist.update_currently_playing,
                self,
                current_playlist_id,
                redirected_playlist_id,
            )
        else:
            self.manager.plugin.nvim.loop.create_task(
                self.try_update_markdown(current_playlist_id)
            )


class MpvPlaylist:
    '''
    Object containing state about current state of an mpv playlist.
    Responsible for remembering how to map mpv ids to extmark ids in nvim.
    '''
    def __init__(
        self,
        playlist_id_to_extra_data,
        playlist_id_to_extmark_id
    ):
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

    def move_player_extmark(self, mpv: MpvWrapper, playlist_id, show_text=None):
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

        success = mpv.manager.plugin.nvim.lua.neovimpv.move_player(
            mpv.manager.buffer,
            mpv.manager.id,
            self.playlist_id_to_extmark_id.get(playlist_id),
            show_text
        )
        if not success:
            try:
                filename = self.playlist_id_to_extra_data[playlist_id][0]
            except IndexError:
                filename = None
            mpv.manager.plugin.show_error(f"Could not move the player (current file: {filename})!")
            log.debug(
                "Could not move the player!\n" \
                "filename: %s\n" \
                "playlist_id: %s\n" \
                "playlist: %s",
                filename,
                playlist_id,
                mpv.protocol.data.get('playlist')
            )
        mpv.no_draw = False

    def update_currently_playing(
        self,
        mpv: MpvWrapper,
        current_playlist_id,
        redirected_playlist_id
    ):
        '''Invoke the Lua callback for updating the currently playing text'''
        playlist_from_mpv = mpv.protocol.data.get("playlist", [])
        current_title = next(
            # attempt to get the title of the content
            # if it's been loaded before, use the entry specified by the filename as backup
            (item.get("title", self._loaded_titles.get(item.get("filename")))
                for item in playlist_from_mpv if item.get("id") == current_playlist_id),
            None
        )
        log.debug(
            "current_playlist_id: %s\n" \
            "redirected_playlist_id: %s\n",
            current_playlist_id,
            redirected_playlist_id,
        )

        if redirected_playlist_id is None:
            extmark_id = self.playlist_id_to_extmark_id.get(current_playlist_id)
        else:
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
            mpv.manager.plugin.show_error("Error updating currently playing title!")
            log.error("Could not find extmark id from mpv playlist_id")
            return

        mpv.manager.plugin.nvim.lua.neovimpv.show_playlist_current(
            mpv.manager.buffer,
            extmark_id,
            current_title
        )
        mpv.no_draw = False

    def _paste_playlist(self, mpv: MpvWrapper, new_playlist, playlist_id):
        '''Paste the playlist items on top of the playlist'''
        # make sure we get the right index for currently-playing
        playlist_current = next(
            (i for i, j in enumerate(new_playlist) if j.get("current")),
            None
        )
        if playlist_current is None:
            mpv.manager.plugin.log_error("Could not get current playlist index!")
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

        new_extmarks = mpv.manager.plugin.nvim.lua.neovimpv.paste_playlist(
            mpv.manager.buffer,
            mpv.manager.id,
            self.playlist_id_to_extmark_id.get(playlist_id),
            write_lines,
            playlist_current + 1,
        )
        mpv.no_draw = False

        # bind the new extmarks to their mpv ids
        for mpv_item, extmark_id in zip(new_playlist, new_extmarks):
            self.playlist_id_to_extmark_id[mpv_item["id"]] = extmark_id
            self.playlist_id_to_extra_data[mpv_item["id"]] = (mpv_item["filename"], False, use_markdown)

    def _new_playlist_buffer(self, mpv: MpvWrapper, new_playlist, playlist_id):
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
            mpv.manager.plugin.nvim.lua.neovimpv.new_playlist_buffer(
                mpv.manager.buffer,
                mpv.manager.id,
                self.playlist_id_to_extmark_id.get(playlist_id),
                write_lines
            )
        mpv.no_draw = False

        log.debug(
            "Got new playlist buffer\n" \
            "new_buffer_id: %s\n" \
            "new_display: %s\n" \
            "new_extmarks: %s",
            new_buffer_id,
            new_display,
            new_extmarks
        )

        mpv.manager.plugin.set_new_buffer(mpv.manager, new_buffer_id, new_display)

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

    def update(self, mpv: MpvWrapper, data):
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
        do_stay = mpv.manager.update_action == "stay" or \
                len(self.playlist_id_to_extmark_id) > 1 and mpv.manager.update_action in ("paste_one", "new_one")

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
        elif mpv.manager.update_action in ("paste", "paste_one"):
            mpv.no_draw = True
            mpv.manager.plugin.nvim.async_call(
                self._paste_playlist,
                mpv,
                [i for i in data["playlist"] if i["id"] in range(start, end)],
                original_entry,
            )
        elif mpv.manager.update_action == "new_one":
            mpv.no_draw = True
            mpv.manager.plugin.nvim.async_call(
                self._new_playlist_buffer,
                mpv,
                [i for i in data["playlist"] if i["id"] in range(start, end)],
                original_entry,
            )

    def set_current_by_playlist_extmark(self, mpv: MpvWrapper, extmark_id):
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
        playlist = mpv.protocol.data.get("playlist", [])
        if len(playlist) <= 1:
            mpv.manager.plugin.show_error("Refusing to set playlist index on small playlist!", 3)
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
            mpv.manager.plugin.show_error("Could not find mpv item!")
            log.error("Entry %s does not exist in playlist!\n%s", playlist_id, playlist)
            return

        mpv.protocol.send_command("playlist-play-index", playlist_index)

    def forward_deletions(self, mpv: MpvWrapper, removed_items):
        '''Forward deletions to mpv'''
        playlist_ids = [i for i,j in self.playlist_id_to_extmark_id.items() if j in removed_items]

        # reverse-lookup for remapped extmarks
        static_deletions = [
            j
            for i in removed_items
            for j, k in self.playlist_id_remap.items() if k == i
        ]
        playlist_ids += static_deletions

        # get deleted indexes
        removed_indices = [index
            for index, item in enumerate(mpv.protocol.data.get("playlist", []))
            if item["id"] in playlist_ids
        ]

        log.debug(
            "Removing mpv ids!\n" \
            "playlist_ids: %s\n" \
            "playlist: %s",
            playlist_ids,
            mpv.protocol.data.get('playlist')
        )

        removed_indices.sort(reverse=True)
        for index in removed_indices:
            mpv.protocol.send_command("playlist-remove", index)
