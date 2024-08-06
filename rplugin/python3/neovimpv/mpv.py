"""
neovimpv.mpv

Implements a plugin-aware container for an mpv asyncio protocol object and a manager
for playlist extmarks.
"""

from dataclasses import dataclass
import logging
from typing import TYPE_CHECKING

import pynvim

from neovimpv.protocol import MpvProtocol

if TYPE_CHECKING:
    from neovimpv.player import MpvManager

log = logging.getLogger(__name__)
log.setLevel("ERROR")

# Example behavior of multiline playlist:
#
# (link without markdown 1)   ---->     Try markdown, no "currently playing"
# (link 2) (link 3)           --|->     No markdown, currently playing
#                               |->     No markdown, currently playing
# (playlist 4, ...)           ---->     No markdown, no "currently playing"
#                                       Player arrives, sees playlist, updates "currently playing"
#                                       Item 5 has markdown, "currently playing" if "stay" mode

@dataclass
class MpvItem:
    filename: str
    extmark_id: int
    update_markdown: bool
    show_currently_playing: bool


class MpvWrapper:
    """
    An instance of mpv which is aware of the nvim plugin. Should only be
    instantiated when nvim is available for communication.
    Automatically creates a task for launching the mpv instance.
    """

    def __init__(self, manager: "MpvManager", protocol: MpvProtocol):
        self.manager = manager
        self.protocol = protocol

        self.no_draw = True

        self._add_events()
        self._load_playlist(manager.playlist)  # type: ignore

    def _add_events(self):
        # default event handling
        self.protocol.add_event("error", lambda _, err: self._show_error(err))
        self.protocol.add_event("end-file", lambda _, arg: self._on_end_file(arg))
        self.protocol.add_event("start-file", lambda _, data: self._on_start_file(data))
        self.protocol.add_event("file-loaded", lambda _, __: self._preamble())
        self.protocol.add_event("close", lambda _, __: self.manager.close())
        self.protocol.add_event(
            "property-change",
            lambda _, __: self.manager.plugin.nvim.async_call(self.draw_update),
        )
        self.protocol.add_event(
            "got-playlist", lambda _, data: self.manager.playlist.update(self, data)
        )

        # ALWAYS observe this so we can toggle pause
        self.protocol.observe_property("pause")
        # necessary for retaining playlist position
        self.protocol.observe_property("playlist")
        # for drawing [Window] instead, toggling video
        self.protocol.observe_property("video-format")
        # observe everything we need to draw the format string
        for i in self.manager.plugin.format_groups:
            self.protocol.observe_property(i)

    def _load_playlist(self, playlist):
        log.info("Loading playlist!")
        log.debug(list(playlist.playlist_id_to_item.items()))

        # start playing the files
        for _, item in sorted(playlist.playlist_id_to_item.items(), key=lambda x: x[0]):
            self.protocol.send_command("loadfile", item.filename, "append-play")

    def draw_update(self, force_virt_text=None):
        """Rerender the player extmark to which this mpv instance corresponds"""
        if self.no_draw and force_virt_text is None:
            return

        # draw_update is called asynchronously, so protect against errors from this call
        try:
            self.manager.plugin.nvim.lua.neovimpv.update_extmark(
                self.manager.buffer,
                self.manager.id,
                # Remove the playlist, since it can get long and shouldn't be drawn
                {k: v for k, v in self.protocol.data.items() if k != "playlist"},
                force_virt_text,
            )
        except pynvim.NvimError:
            pass

    # ==========================================================================
    # The following methods do not assume that nvim is in an interactable state
    # ==========================================================================

    async def try_update_markdown(self, playlist_id):
        """
        Wait until we've got the title and filename, then format the line where
        mpv is being displayed as markdown.
        """
        mpv_item = self.manager.playlist.playlist_id_to_item.get(playlist_id)
        if mpv_item is None:
            self.manager.plugin.show_error("Playlist transition failed!")
            log.debug(
                "Playlist transition failed! Mpv id %s does not exist in %s",
                playlist_id,
                self.manager.playlist.playlist_id_to_item,
            )
            return

        media_title = await self.protocol.wait_property("media-title")
        mpv_filename = await self.protocol.wait_property("filename")
        cannot_markdown = "(" in mpv_item.filename or ")" in mpv_item.filename
        if (
            not mpv_item.update_markdown
            or media_title == mpv_filename
            or cannot_markdown
        ):
            return

        self.manager.plugin.nvim.async_call(
            self.manager.plugin.nvim.lua.neovimpv.write_line_of_playlist_item,
            self.manager.buffer,
            mpv_item.extmark_id,
            f"[{media_title.replace('[', '(').replace(']',')')}]({mpv_item.filename})",
        )

    def _show_error(self, err):
        """Report error contents to nvim"""
        additional_info = ""
        if (property_name := err.get("property-name")) is not None:
            additional_info = f" to request for property '{property_name}'"

        self.manager.plugin.show_error(
            f"mpv responded '{err.get('error')}'{additional_info}",
        )
        log.error("Error occurred: %s", err)

    def _on_end_file(self, arg):
        """Report an error to nvim if the file ended because of an error."""
        self.no_draw = True
        self.manager.plugin.nvim.async_call(self.draw_update, "")
        if arg.get("reason") == "error" and (error := arg.get("file_error")):
            self.manager.plugin.show_error(f"File ended: {error}")

    def _on_start_file(self, arg):
        """
        Update state after new file started.
        Move the player to new playlist item and suspend drawing until complete.
        """
        # Starting the file is enough information to move the player, but not enough
        # to update the title of the video.
        self.no_draw = True
        current_playlist_id = arg.get("playlist_entry_id")

        if (
            self.protocol.playlist_new is not None
            and current_playlist_id
            == self.protocol.playlist_new.get("playlist_insert_id")
        ):
            return
        redirected_playlist_id = self.manager.playlist.playlist_id_remap.get(
            current_playlist_id
        )
        # use the extmark of this mpv id to move the player
        if redirected_playlist_id is not None:
            current_playlist_id = redirected_playlist_id

        self.manager.plugin.nvim.async_call(
            self.manager.playlist.move_player_extmark, self, current_playlist_id
        )

    def _preamble(self):
        """Update buffer text after new file loaded."""
        # Have enough information to update with video title
        current_playlist_id = self.protocol.last_playlist_entry_id
        playlist_item = self.manager.playlist.playlist_id_to_item.get(
            current_playlist_id
        )
        redirected_playlist_id = self.manager.playlist.playlist_id_remap.get(
            current_playlist_id
        )
        if playlist_item is not None and playlist_item.show_currently_playing:
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
    """
    Object containing state about current state of an mpv playlist.
    Responsible for remembering how to map mpv ids to extmark ids in nvim.
    """

    def __init__(
        self,
        playlist_id_to_item,
    ):
        # playlist information cached in the plugin, such as filenames, extmark id, and
        # whether the line can be rewritten in markdown
        self.playlist_id_to_item = playlist_id_to_item

        # remaps from one mpv id to another
        self.playlist_id_remap = {}
        # for "stay" mode, map the old playlist id to first new item
        self._updated_indices = {}

        # temporary object containing `playlist_id_to_extra_data` for reopening the player
        self._new_items = None
        # dict mapping filenames to titles, in case we have to reopen the player
        self._loaded_titles = {}

    def __len__(self):
        # number of extmarks plus number of remaps minus unique remap targets
        return (
            len(self.playlist_id_to_item)
            + len(self.playlist_id_remap)
            - len(set(self.playlist_id_remap.values()))
        )

    def reorder_by_index(self, old_playlist):
        """
        Reorder playlist_ids by their index in the playlist.
        This is used when transitioning between two mpv instances while maintaining the playlist.
        """
        new_remap = {}
        new_items = {}
        mapped = set()
        for i, item in enumerate(old_playlist):
            playlist_id = item.get("id")
            if playlist_id in self.playlist_id_remap:
                new_remap[i + 1] = self.playlist_id_remap[playlist_id]
                mapped.add(self.playlist_id_remap[playlist_id])
            if playlist_id in self.playlist_id_to_item:
                # create a new MpvItem instance
                new_items[i + 1] = self.playlist_id_to_item[playlist_id]._replace()

        for extmark_id in mapped:
            # attempt to find remapped extmarks and assign them in the item dict
            find_remap = next(
                (
                    new_playlist_id
                    for new_playlist_id, playlist_extmark_id in new_remap.items()
                    if playlist_extmark_id == extmark_id
                ),
                None,
            )
            if find_remap is not None:
                new_items[find_remap].extmark_id = extmark_id

        log.info("Reordered playlist!")
        log.debug("playlist_id_remap: %s\nnew_items: %s", new_remap, new_items)

        if self._new_items is not None:
            self.playlist_id_to_item = self._new_items
            self._new_items = None

        self.playlist_id_remap = new_remap
        self.playlist_id_to_item = new_items
        self._updated_indices.clear()

    def move_player_extmark(self, mpv: MpvWrapper, playlist_id, show_text=None):
        """
        Invoke the Lua callback for moving the player to the line of a playlist extmark.
        Used when the mpv subprocess starts a queued item to move the player to the correct line.
        """
        log.debug(
            "Moving player!\n"
            "playlist_id: %s\n"
            "playlist_id_to_item: %s\n"
            "playlist_id_remap: %s",
            playlist_id,
            self.playlist_id_to_item,
            self.playlist_id_remap,
        )
        mpv_item = self.playlist_id_to_item.get(playlist_id)
        success = True
        if mpv_item is None:
            success = False
        else:
            success = mpv.manager.plugin.nvim.lua.neovimpv.move_player(
                mpv.manager.buffer,
                mpv.manager.id,
                mpv_item.extmark_id,
                show_text,
            )

        if not success:
            try:
                filename = self.playlist_id_to_item[playlist_id].filename
            except (AttributeError, KeyError):
                filename = None
            mpv.manager.plugin.show_error(
                f"Could not move the player (current file: {filename})!"
            )
            log.debug(
                "Could not move the player!\n"
                "filename: %s\n"
                "playlist_id: %s\n"
                "playlist: %s",
                filename,
                playlist_id,
                mpv.protocol.data.get("playlist"),
            )
        mpv.no_draw = False

    def update_currently_playing(
        self, mpv: MpvWrapper, current_playlist_id, redirected_playlist_id
    ):
        """
        Invoke the Lua callback for updating the currently playing text.
        Used when the mpv subprocess loads a queued item to update a "Currently Playing" display.
        """
        playlist_from_mpv = mpv.protocol.data.get("playlist", [])
        current_title = next(
            # attempt to get the title of the content
            # if it's been loaded before, use the entry specified by the filename as backup
            (
                item.get("title", self._loaded_titles.get(item.get("filename")))
                for item in playlist_from_mpv
                if item.get("id") == current_playlist_id
            ),
            None,
        )
        log.debug(
            "current_playlist_id: %s\n" "redirected_playlist_id: %s\n",  # pylint: disable=implicit-str-concat
            current_playlist_id,
            redirected_playlist_id,
        )

        mpv_item = None
        if redirected_playlist_id is None:
            mpv_item = self.playlist_id_to_item.get(current_playlist_id)
        else:
            mpv_item = self.playlist_id_to_item.get(redirected_playlist_id)

        if mpv_item is None:
            mpv.manager.plugin.show_error("Error updating currently playing title!")
            log.error("Could not find extmark id from mpv playlist_id")
            return

        log.info("Updating currently playing!")
        log.debug(
            "current_playlist_id: %s, current_title: %s\n"
            "redirected_playlist_id: %s\n"
            "playlist_id_to_item: %s\n",
            current_playlist_id,
            current_title,
            redirected_playlist_id,
            self.playlist_id_to_item,
        )

        if current_title is None:
            log.info(
                "Currently playing title is None.\nIgnoring currently playing update!"
            )
            return

        mpv.manager.plugin.nvim.lua.neovimpv.show_playlist_current(
            mpv.manager.buffer, mpv_item.extmark_id, current_title
        )
        mpv.no_draw = False

    def _paste_playlist(self, mpv: MpvWrapper, new_playlist, playlist_id):
        """
        Paste the playlist items on top of the playlist
        Used when the mpv subprocess receives new playlist data and updates the buffer
        ("paste", "paste-one").
        """
        log.info("Pasting new playlist!")
        log.debug("new_playlist: %s", new_playlist)
        # make sure we get the right index for currently-playing
        playlist_current = next(
            (i for i, j in enumerate(new_playlist) if j.get("current")), None
        )
        if playlist_current is None:
            mpv.manager.plugin.log_error("Could not get current playlist index!")
            return

        # get markdown, if applicable
        mpv_item = self.playlist_id_to_item.get(playlist_id)
        if mpv_item is None:
            log.error(
                "Attempted to paste playlist, but could not find original player!"
            )
            return
        use_markdown = mpv_item.update_markdown

        write_lines = (
            [i["filename"] for i in new_playlist]
            if not use_markdown
            else [
                f"[{i['title'].replace('[', '(').replace(']',')')}]({i['filename']})"
                for i in new_playlist
            ]
        )

        new_extmarks = mpv.manager.plugin.nvim.lua.neovimpv.paste_playlist(
            mpv.manager.buffer,
            mpv.manager.id,
            mpv_item.extmark_id,
            write_lines,
            playlist_current + 1,
        )
        log.info("Got new extmarks!")
        log.debug("write_lines: %s\nnew_extmarks: %s", write_lines, new_extmarks)
        mpv.no_draw = False

        # bind the new extmarks to their mpv ids
        for mpv_item, extmark_id in zip(new_playlist, new_extmarks):
            self.playlist_id_to_item[mpv_item["id"]] = MpvItem(
                filename=mpv_item["filename"],
                extmark_id=extmark_id,
                update_markdown=use_markdown,
                show_currently_playing=False,
            )

    def _new_playlist_buffer(self, mpv: MpvWrapper, new_playlist, playlist_id):
        """
        Create a new buffer and paste the playlist items.
        Used when the mpv subprocess receives new playlist data and updates the buffer ("new-one").
        """
        log.info("Creating new playlist buffer!")
        log.debug("new_playlist: %s", new_playlist)
        # get markdown, if applicable
        mpv_item = self.playlist_id_to_item.get(playlist_id)
        if mpv_item is None:
            log.error(
                "Attempted to create playlist buffer, but could not find original player!"
            )
            return

        use_markdown = mpv_item.update_markdown
        write_lines = (
            [i["filename"] for i in new_playlist]
            if not use_markdown
            else [
                f"[{i['title'].replace('[', '(').replace(']',')')}]({i['filename']})"
                for i in new_playlist
            ]
        )

        new_buffer_id, new_display, new_extmarks = (
            mpv.manager.plugin.nvim.lua.neovimpv.new_playlist_buffer(
                mpv.manager.buffer,
                mpv.manager.id,
                mpv_item.extmark_id,
                write_lines,
            )
        )
        log.info("Got new playlist buffer")
        log.debug(
            "Got new playlist buffer\n"
            "new_buffer_id: %s\n"
            "new_display: %s\n"
            "new_extmarks: %s",
            new_buffer_id,
            new_display,
            new_extmarks,
        )
        mpv.no_draw = False

        mpv.manager.plugin.set_new_buffer(mpv.manager, new_buffer_id, new_display)

        # bind the new extmarks to their mpv ids
        self.playlist_id_to_item.clear()
        for playlist_item, extmark_id in zip(new_playlist, new_extmarks):
            self.playlist_id_to_item[playlist_item["id"]] = MpvItem(
                filename=playlist_item["filename"],
                extmark_id=extmark_id,
                update_markdown=False,
                show_currently_playing=False,
            )

    # ==========================================================================
    # The following methods do not assume that nvim is in an interactable state
    # ==========================================================================

    def update(self, mpv: MpvWrapper, data):
        """
        Update state after playlist loaded.
        The playlist retrieved from MpvProtocol is raw, so we need to do a bit of extra processing.
        """
        log.debug("Got updated playlist!\n" "playlist: %s", data)  # pylint: disable=implicit-str-concat

        # the mpv video id which triggered the new playlist
        # should correspond to the index in self.playlist_id_to_item
        original_entry = data["new"]["playlist_entry_id"]
        start = data["new"]["playlist_insert_id"]
        end = start + data["new"]["playlist_insert_num_entries"]
        new_playlist_items = [
            i for i in data["playlist"] if i["id"] in range(start, end)
        ]

        # "stay" if we've been told to or we're not a single playlist
        do_stay = (
            mpv.manager.update_action == "stay"
            or len(self.playlist_id_to_item) > 1
            and mpv.manager.update_action in ("paste_one", "new_one")
        )

        # map the old playlist id to the first item in the new one
        self._updated_indices[original_entry] = start

        if do_stay:
            # add remaps (i.e., old playlist id to new playlist id)
            for i in range(start, end):
                self.playlist_id_remap[i] = original_entry
        elif mpv.manager.update_action in ("paste", "paste_one"):
            mpv.no_draw = True
            mpv.manager.plugin.nvim.async_call(
                self._paste_playlist,
                mpv,
                new_playlist_items,
                original_entry,
            )
        elif mpv.manager.update_action == "new_one":
            mpv.no_draw = True
            mpv.manager.plugin.nvim.async_call(
                self._new_playlist_buffer,
                mpv,
                new_playlist_items,
                original_entry,
            )

    def set_current_by_playlist_extmark(self, mpv: MpvWrapper, extmark_id):
        """Set the current file to the mpv file specified by the extmark `playlist_item`"""
        # try to remap the extmark to the one it came from
        try_remap = next(
            (
                remapped_id
                for remapped_id in self.playlist_id_remap.values()
                # j for i, j in self.playlist_id_remap.items()
                if remapped_id == extmark_id
            ),
            extmark_id,
        )
        # then get the mpv id from it
        playlist_id = next(
            (
                i
                for i, mpv_item in self.playlist_id_to_item.items()
                if mpv_item.extmark_id == try_remap
            ),
            None,
        )

        # adjustment for updated playlists
        if playlist_id in self._updated_indices:
            playlist_id = self._updated_indices[playlist_id]

        # then index into the current playlist
        playlist = mpv.protocol.data.get("playlist", [])
        if len(playlist) <= 1:
            mpv.manager.plugin.show_error(
                "Refusing to set playlist index on small playlist!", 3
            )
            return

        playlist_index = next(
            (index for index, item in enumerate(playlist) if item["id"] == playlist_id),
            None,
        )

        log.debug(
            "Setting current playlist item!\n"
            "extmark_id: %s\n"
            "try_remap: %s\n"
            "playlist_id: %s\n"
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
        """
        Forward deletions to mpv.
        Used when deletions or changes occur in the buffer.
        """
        playlist_ids = [
            i
            for i, mpv_item in self.playlist_id_to_item.items()
            if mpv_item in removed_items
        ]

        # reverse-lookup for remapped extmarks
        static_deletions = [
            j
            for i in removed_items
            for j, k in self.playlist_id_remap.items()
            if k == i
        ]
        playlist_ids += static_deletions

        # get deleted indexes
        removed_indices = [
            index
            for index, item in enumerate(mpv.protocol.data.get("playlist", []))
            if item["id"] in playlist_ids
        ]

        log.debug(
            "Removing mpv ids!\n" "playlist_ids: %s\n" "playlist: %s",  # pylint: disable=implicit-str-concat
            playlist_ids,
            mpv.protocol.data.get("playlist"),
        )

        removed_indices.sort(reverse=True)
        for index in removed_indices:
            mpv.protocol.send_command("playlist-remove", index)
