neovimpv
========

![example](./neovimpv_example.png)

An nvim plugin for opening mpv instances based on buffer contents. Simply type a file
path into a buffer and type `:MpvOpen` to open the file in mpv as if you had
invoked it from the command line. The plugin also features the ability to open
content from YouTube searches.

Multiple lines of text can be opened as an mpv playlist. The playback display
will be drawn as the same line as the current file in mpv. If the line is deleted,
it will be removed from the playlist. Undoing will not restore the playlist.

Note that playlist content comes from the content of the lines when mpv is first
opened -- updating lines will NOT change the playlist.


Features
--------
- Open mpv with or without video from nvim buffer
- Draw configurable mpv attributes (position, duration, etc) as extmarks
- Interface with mpv keybinds using "omnikey"
    - Smart bindings available based on `<leader>` (see `g:mpv_smart_bindings`)
- Interface with mpv playlists when opening multiple lines at once
    - Change current playlist item (see `g:mpv_playlist_key`)
- Can replace paths and URLs with a markdown link to the content with the title as the displayed text
    - This is intended to display the title in filetypes which conceal the actual link
- Dynamic playlist updates (e.g., YouTube playlists when using mpv's yt-dlp plugin).
    - Several options available, see `g:mpv_on_playlist_update`


Dependencies
------------

- mpv (other media players not supported, nor planned to be supported)
- pynvim
- (Optional) youtube-dl or yt-dlp
- (Optional) lxml, for YouTube results


Installation
------------

### Vundle

Place the following in `~/.config/nvim/init.vim`:
```vim
Plugin 'queue-miscreant/neovimpv', {'do': ':UpdateRemotePlugins'}
```
Make sure the file is sourced and run `:PluginInstall`.


### Suggested Use

For the least amount of setup possible, create a keybind in your `init.vim` to
the omnikey. This allows you to open an mpv instance the first time the
sequence is pressed. Pressing the same sequence again (without moving to
another line) will attempt to capture a keypress to send to mpv.

```vim
nnoremap <silent> <leader>\ <Plug>(mpv_omnikey)
vnoremap <silent> <leader>\ <Plug>(mpv_omnikey)
```

For additional movement fidelity and access to a YouTube search prompt, add
```vim
nnoremap <silent><buffer> <leader>[ <Plug>(mpv_goto_earlier)
nnoremap <silent><buffer> <leader>] <Plug>(mpv_goto_later)
nnoremap <silent><buffer> <leader>yt <Plug>(mpv_youtube_prompt)
```

You can also set these bindings up automatically by, adding a filetype to
`g:mpv_smart_filetypes`
It will also work if the filetype is specified in `g:mpv_markdown_writable` and 
`g:mpv_markdown_smart_bindings` is set to 1.

```vim
g:mpv_smart_filetypes = ["markdown"]
-- Or, if you prefer markdown-styled links
-- g:mpv_markdown_smart_bindings = 1
-- g:mpv_markdown_writable = ["markdown"]
```

This will set the same bindings as above in files with the given filetypes.


#### Vimwiki

It's possible to configure [vimwiki](https://github.com/vimwiki/vimwiki) to
open YouTube links, assuming you have a youtube-dl equivalent that works with
mpv. Add the following to your `.vimrc` if you want `<Enter>` to run `MpvOpen`:


```vim
" Open vimwiki links to youtube in Mpv
function! VimwikiLinkHandler(link)
  if a:link =~ "\\mhttps\\?://\\(www\\.\\)\\?youtu\\(\\.be/\\|be\\.com/\\)"
    execute "MpvOpen video --"
    return 1
  endif
endfunction
```


Commands
--------

### `:MpvOpen [{local-args}] [-- {mpv-args}]`

Open an mpv instance using the string on the current line, as if invoking `mpv`
from the command line with the `--no-video` flag. URLs may be used if
youtube-dl or yt-dlp has been set up.

To decrease reliance on IPC, some rudimentary checks are performed to ensure 
that the file exists or is a URL.

If the line contains multiple URLs, the one closest to the current cursor
position is used as an argument.

A range can also be passed, in which case the lines are opened as a playlist.
The previous remark about searching for links does not apply.

Optionally `mpv-args` may be given, which are passed as command line
arguments. This can be used to override `--no-video`, for example, by
calling `:MpvOpen --video=auto`

If `{mpv-args}` overrides the default `--no-video` flag (i.e., if a
window is anticipated to open), the media data will NOT be rendered in
an extmark.

`{local-args}`, if given (by placing them before a `--` in the command),
apply local settings to the plugin mpv handler. They include


| Local argument  | Description
|-----------------|-----------------------------------------------------
| `video`         | Will open the buffer as a video. Same as supplying `--video=auto`.
| `stay`          | Override `g:mpv_on_playlist_update` to `stay` for this player.
| `paste`         | Override `g:mpv_on_playlist_update` to `paste` for this player.
| `new`           | Override `g:mpv_on_playlist_update` to `new_one` for this player. If the initial playlist is longer than one entry, an error is thrown.


### `:MpvNewAtLine file [{mpv-args}] [-- {local-args}]`

Similar to `MpvOpen`, but the file is specified as part of the command.
The Mpv instance is opened at the current line of the cursor, and `{mpv-args}`
and `{local-args}` behave the same as `MpvOpen`.


### `:MpvClose [{buffer}]`

Close an mpv instance displayed on the current line.

If `{buffer}` is specified and a number, it closes all mpvs which were
bound to that buffer number. `0` signifies the current buffer.
`{buffer}` can also be `all`, in which case all known mpv instances are
closed.


### `:MpvSend command-name [...command-args]`

Send a command to the mpv instance running on the current line. See
[this](https://mpv.io/manual/stable/#json-ipc) part of the mpv
documentation for more information about commands.

Some example commands include `seek {seconds}` and `quit`.


### `:MpvSetProperty property-name property-value`

Set a property on the mpv instance running on the current line. See
[this](https://mpv.io/manual/stable/#property-list) part of the mpv
documentation for more information about properties.

Property values are evaluated to their JSON value prior to being reserialized
and sent to mpv. For example, the literal `60` will send a number, while `"60"`
and `foo` will send strings.

Some useful example properties:

- `volume`
    - Percentage volume, ranging from 0-100.
- `loop`
    - Number of times the content should loop. Valid values include numbers, `"none"`, and `"inf"`.
- `playback-time`
    - Current playback position. You can change this relatively using the `seek` command.

This command is equivalent to using MpvSend with first argument `set_property`.

### `:MpvGetProperty {property-name}`

Get a property of the mpv instance running on the current line. The
result will be displayed as if the `echo` command had been used.

See [this](https://mpv.io/manual/stable/#property-list) part of
the mpv documentation for more information about properties.

This command is NOT equivalent to using MpvSend with first argument
`get_property`. In this command, the response from mpv is not ignored.


### `:MpvPause [{buffer}]`

Toggle the pause status of the mpv instance running on the current line.

If {buffer} is specified and a number, it pauses (NOT toggles) all mpvs which
were bound to that buffer number. `0` signifies the current buffer.
{buffer} can also be `all`, in which case all known mpv instances are
paused.

This command is equivalent to `:MpvSend set_property pause <not pause state>`


### `:MpvYoutubeSearch {query}`

Do a YouTube search for `{query}`, then open a split containing the
results. See YouTube splits below for info.

As a !-command (`MpvYoutubeSearch!`), retrieves the first result and pastes it
in the current window.


### `:MpvLogLevel {logger} {level}`

Set the logging level for a Python logger.
`{logger}` should be one of `mpv`, `protocol`, `youtube`, or `all`.
`{level}` should be a valid Python `logging` level.


Functions
---------

### `MpvSendNvimKeys(extmark_id, keypress_string)`

Send `keypress_string`, a string signifying a nvim keypress event, to
the mpv instance identified by `extmark_id`.

The plugin is able to translate SOME of these into mpv equivalents,
but not all. You should not rely on proper handling of modifier keys
(Ctrl, Alt, Shift, Super).

### `MpvUpdatePlaylists(updated_playlists)`

Update player's playlists on the Python side. `updated_playlists` is a
dictionary where the keys are playlist ids and values are a list of
playlist items. This function does NOT change extmarks, but it will
modify the mpv playlist.


Keys
----

### `<Plug>(mpv_omnikey)`

Capture a keypress and send it to the mpv instance running on the
current line. If there is no instance, `g:mpv_omni_open_new_if_empty`
decides whether or not to call `:MpvOpen` or report an error. Can be
used in visual mode to open a playlist.

The special key specified by `g:mpv_playlist_key` will NOT be sent to
mpv, and instead sets the current playlist item to the one on the line
of the cursor.

Giving a count beforehand will be acknowledged, with the key repeatedly
sent to mpv that number of times.


### `<Plug>(mpv_omnikey_video)`

Same as `<Plug>(mpv_omnikey)`, but opens the line with `--video=auto`
appended to the mpv arguments.

When the cursor is on a line with a playlist and this sequence is
typed, this attempts to toggle the mpv playlist between video and
audio modes. This is mostly equivalent to the `_` keybind in mpv.
However, when mpv uses the youtube-dl plugin in audio-only mode, it
will typically try to download a stream without video. To get around
this, the plugin will close the player and reopen it with the same
playlist (with changes to reflect dynamic updates).


### `<Plug>(mpv_youtube_prompt)`

Open a prompt for a YouTube search. This is equivalent to using the
command `:MpvYoutubeSearch` with the on the contents of the prompt.
See also `neovimpv-youtube-splits`.


### `<Plug>(mpv_goto_earlier)`

Jump to the latest line before the cursor in the current buffer which
has an mpv instance.


### `<Plug>(mpv_goto_later)`

Jump to the earliest line after the cursor in the current buffer which
has an mpv instance.


YouTube Results
---------------

While searching for content on youtube with 'ytdl://ytsearch:' is possible, the
results you get are more or less a guessing game. Worse still, getting video
attributes (like description, title, view count) with `youtube-dl` (and its
forks) is generally very slow with multiple prompts.

To alleviate these problems, the plugin includes YouTube searching built-in.
The command `:MpvYoutubeSearch` and the key `<Plug>(mpv_youtube_prompt)` allow
you to open a split which contains the results of a YouTube search.

The name of the YouTube video is displayed on each line, with additional video
information available by moving the cursor to that line.

The keys available in YouTube splits are as follows:

### `<enter>`

Copy the video URL into the buffer the split was originally opened from and open
the video using `MpvOpen`.


### `<s-enter>`, `v`

Same as `<enter>`, but calls `:MpvOpen` with `--video=auto` instead, which opens
the result with video rather than audio only.


### `p`, `P`

Same as `<enter>`, but works as though `g:mpv_on_playlist_update` was set to
"paste", which pastes playlists into the buffer.

`P` opens the results with video.


### `n`, `N`
Same as `<enter>`, but works as though `g:mpv_on_playlist_update` was set to
"new", which opens a new buffer for the playlist contents.

`N` opens the results with video.


### `i`

Download the thumbnail of the video and display it with the default system viewer


### `q`

Exit the split


### Yanking

If the yank motion is "y" (i.e., the whole line), then the URL of the result
under the cursor is pasted into the register that was used. For example, to copy
the result into the system clipboard, using `"+yy` will grab the URL, rather
than the line content.


Configuration
-------------

The following global variables may be placed in your vim init script. If they
are changed while Neovim is running, they will NOT take effect.


### `g:mpv_loading`

String to be displayed while an mpv instance is still loading.
The default value is `"[ ... ]"`, displayed with highlight `MpvDefault`.


### `g:mpv_format`

Format string to use when drawing text for an mpv instance. Each
field which is intended to represent an mpv property must be
surrounded by curly braces ({}).

Some formats are drawn internally to the plugin:
- `duration` and `playback-time` will both render in a familiar time
  format.

- `pause` will render using typical pause and play symbols, instead of
  the string representations "True" and "False".

The default value is `"[ {pause} {playback-time} / {duration} {loop} ]"`


### `g:mpv_style`

Style to use when drawing pictographic fields. Possible values are
`"unicode"`, `"ligature"`, and `"emoji"`.
Currently, the only pictographic field is "pause".

The default value is `"unicode"`


### `g:mpv_markdown_writable`

List of filetypes (strings) which, when a line is opened using `:MpvOpen`,
will format the line into markdown, if it isn't already. The format
used is `[{mpv-title}]({original-link})`.

This option is best used in files which support syntax that hides link contents.


### `g:mpv_default_args`

List of arguments to be supplied to mpv when an instance is opened
with `:MpvOpen`. Note that `--no-video` is always implied, unless it
is overridden by `--video=auto`.


### `g:mpv_property_thresholds`

Dictionary where the keys are mpv properties. The values are lists of
numbers which control which highlight will be used when rendering the
property.

If the list contains one entry, the highlight is partitioned into "Low"
and "High", which are appended to the usual name (e.g., `MpvPlaybackTime`
becomes `MpvPlaybackTimeLow` and `...High`). Values less than the entry
are given "Low" while values greater than it are given "High".

If the list contains two entries, the value is partitioned into "Low",
"Middle", and "High" instead.


### `g:mpv_draw_playlist_extmarks`

String which is either `"always"`, `"multiple"`, or `"never"`.
Controls whether playlist extmarks are drawn in the sign column.
The default value is `"multiple"`.

| Value        | Description
|--------------|-----------------------------------------------------
| `"always"`   | Signs will be drawn regardless of playlist length.
| `"multiple"` | Signs will not be drawn if there is only one playlist item.
| `"never"`    | Signs will never be drawn.


### `g:mpv_on_playlist_update`

String which is either `"stay"`, `"paste"`, `"paste_one"`, or
`"new_one"`. Controls what happens when mpv dynamically loads a
playlist.

The default value is `"stay"`.

| Value         | Description
|---------------|-----------------------------------------------------
| `"stay"`      | The playlist "file" will be retained in the buffer and the title of the current file will be drawn in an extmark below.
| `"paste"`     | The dynamic content is inserted in place of the playlist file. All items in the playlist are queued and displayed in the buffer.
| `"paste_one"` | The plugin behaves in `"paste"` mode when the initial playlist has only one item. Otherwise, it behaves in `"stay"` mode.
| `"new_one"`   | A single-item playlist will paste the dynamic content in a new split. All content is queued and the player is moved to the new buffer. Otherwise, it behaves in `"stay"` mode.


### `g:mpv_playlist_key`

A special key (stored in a string) which changes the functionality of
the omnikey. When waiting for a keypress to send to mpv, if this key
is pressed, the key will NOT be sent, and instead scrolls the current
mpv item to the one at the row of the cursor.

The default value is backslash (i.e., `"\\"`).


### `g:mpv_playlist_key_video`

A second special key (stored in a string) which changes the functionality of
the omnikey. This key is intended to be the "video" counterpart to
`g:mpv_playlist_key`.

The default value depends on the value of `g:mpv_playlist_key`:

| `g:mpv_playlist_key` | `g:mpv_playlist_key_video`
|----------------------|-----------------------------------------------------
| `"\\"`               | `"<bar>"` (i.e., `|` as a key)
| `","`                | `"."`
| `"~"`                | `"``"`
| (Other)              | `""` (Unused)


### `g:mpv_smart_filetypes`

A list of filetypes (strings) which should have smart default bindings set.

| Binding                              | Description
|--------------------------------------|-----------------------------------------------
| `<leader>[g:mpv_playlist_key]`       | Omnikey
| `<leader>[g:mpv_playlist_key_video]` | Omnikey (video)
| `<leader>yt`                         | Open YouTube search
| `<leader>Yt`                         | Open YouTube search and paste first result
| `<leader>[`                          | Move cursor to earlier line with mpv instance
| `<leader>]`                          | Move cursor to later line with mpv instance

Default value is `[]` (empty).

### `g:mpv_markdown_smart_bindings`

Boolean value which, when true, attempts to set smart bindings in filetypes
included in |g:mpv_markdown_writable|.

Default value is 0 (false).


### `g:mpv_smart_youtube_playlist`

A boolean value which affects the `g:mpv_on_playlist_update` semantics
for opening a single YouTube playlist.
Playlists from "ytsearch{count}:" will open as 'paste' if count is not
given or 1.
Other single-item playlists are opened as `new_one`.


Highlights
----------

General-purpose highlight groups defined by this plugin are `MpvDefault` and
`MpvPlaylistSign`. The former is, as its name suggests, the default choice
for extmarks in the plugin. The latter is the default choice for playlist
extmarks in the sign column.

The highlight used to draw an mpv property is user-controllable. All
highlights begin with "Mpv", followed by the property name. Properties in mpv
are given in kebab-case, but the corresponding highlights in Vim will be in
CamelCase. For example, the property `playback-time` becomes the highlight
`MpvPlaybackTime`.

All properties which occur in `g:mpv_format` are given highlights that link
to bound to the plugin default highlight `MpvDefault`, unless they have
already been defaulted in the plugin. The following defaults additional
defaults exist:

- MpvPauseTrue -> Conceal
- MpvPauseFalse -> Title
- MpvPlaybackTime -> Conceal
- MpvDuration -> Conceal

When using `g:mpv_property_thresholds`, the original highlight for the
property will not be used. Instead, only the partitioned highlights will exist
(with defaults appropriately defined).

For example, the following will cause the first 10 seconds of playback time to
be drawn with the highlight `ErrorMsg`, while the remaining time will be drawn
with `MpvPlaybackTimeHigh (-> MpvDefault)` (instead of `MpvPlaybackTime`):

```vim
  let g:mpv_property_thresholds = { "playback-time": [10] }
  hi! link MpvPlaybackTimeLow ErrorMsg
```

The following highlights are used for extra video info in YouTube results:

| Property name   | Highlight name          | Explanation
|-----------------|-------------------------|---------------------------
| `length`        | `MpvYoutubeLength`      | Length of the video
| `channel_name`  | `MpvYoutubeChannelName` | Channel name of uploader
| `views`         | `MpvYoutubeViews`       | View count of the video


TODOs
-----

- Improve sending keys to mpv
- Folds?
- Play by searching selection (or line) for URL
- Close invisible players
