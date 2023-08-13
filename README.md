neovimpv
========

![example](./neovimpv_example.png)

A plugin for opening mpv instances based on buffer contents. Simply type a file
path into a buffer and type `:MpvOpen` to open the file in mpv as if you had
invoked it from the command line. The plugin also features the ability to open
content from YouTube searches.


Requirements
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
Plugin 'queue-miscreant/neovimpv', {'do', ':UpdateRemotePlugins'}
```
Make sure the file is sourced and run `:PluginInstall`.


Suggested Use
-------------

For the least amount of setup possible, create a keybind in your `init.vim` to
omnikey. This allows you to open an mpv instance the first time the sequence is
pressed. Pressing the same sequence again (without moving to another line) will
attempt to capture a keypress to send to mpv.

```vim
nnoremap <silent> <leader>\ <Plug>(mpv_omnikey)
```


Commands
--------

### `:MpvOpen [mpv-args]`

Open an mpv instance using the string on the current line, as if invoking `mpv`
from the command line with the `--no-video` flag. URLs may be used if youtube-dl
or yt-dlp has been set up.

To decrease reliance on IPC, some rudimentary checks are performed to ensure that
the file exists or is a URL.

Optionally `mpv-args` may be given, which are passed as command line
arguments. This can be used to override `--no-video`, for example, by
calling `:MpvOpen --video=auto`

If {mpv-args} overrides the default `--no-video` flag (i.e., if a
window is anticipated to open), the media data will NOT be rendered in
an extmark.


### `:MpvClose [all]`

Close an mpv instance displayed on the current line.

If `all` is specified, every mpv instance bound to the current buffer is closed.


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


### `:MpvPause [all]`

Toggle the pause status of the mpv instance running on the current line. If `all` is
specified, every mpv instance bound to the current buffer is paused (NOT toggled).

This command is equivalent to `:MpvSend set_property pause <not pause state>`

### `:MpvYoutubeSearch {query}`

Do a YouTube search for `{query}`, then open a split containing the
results. See YouTube splits below for info.


Functions
---------

### `MpvSendNvimKeys(extmark_id, keypress_string)`

Send `keypress_string`, a string signifying a nvim keypress event, to
the mpv instance identified by `extmark_id`.

The plugin is able to translate SOME of these into mpv equivalents,
but not all. You should not rely on proper handling of modifier keys
(Ctrl, Alt, Shift, Super).


Keys
----

### `<Plug>(mpv_omnikey)`

Capture a keypress and send it to the mpv instance running on the
current line. If there is no instance, `g:mpv_omni_open_new_if_empty`
decides whether or not to call `:MpvOpen` or report an error.

Giving a count beforehand will be acknowledged, with the key repeatedly
sent to mpv that number of times.

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

While specifying content with 'ytdl://ytsearch:' is possible, the results you
get are more or less a guessing game. Worse still, getting video attributes
(like description, title, view count) with `youtube-dl` (and its forks) is
generally very slow with multiple prompts.

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


### `i`

Download the thumbnail of the video and display it with the default system viewer


### `q`

Exit the split


### {yank-motion}

If the yank motion is a single line, then the result's video URL is pasted into
the register that was used. For example, to copy the result into the system
clipboard, using `"+yy` will grab the URL, rather than the line content.


Configuration
-------------

The following global variables may be placed in your vim init script. If they
are changed while Neovim is running, they will NOT take effect.


### `g:mpv_loading`

String to be displayed while an mpv instance is still loading. Uses
the default highlight defined in `g:mpv_default_highlight`.

The default value is `"[ ... ]"`


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

List of filetypes which, when a line is opened using `:MpvOpen`,
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


Highlights
----------

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

- Mpv playlists
- Improve sending keys
