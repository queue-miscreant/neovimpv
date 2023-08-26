function s:get_subcommand(cmd_line, cursor_pos)
  let cmd_partial = a:cmd_line[:a:cursor_pos + 1]
  let cmd_split_by_space = filter(split(cmd_partial, " "), "v:val != ''")
  return get(cmd_split_by_space, 1, "")
endfunction

function s:get_argnum(cmd_line, cursor_pos)
  let cmd_partial = a:cmd_line[:a:cursor_pos + 1]
  let cmd_split_by_space = filter(split(cmd_partial, " "), "v:val != ''")
  return len(cmd_split_by_space) - 1 + (cmd_partial[-1:] == " ")
endfunction

function s:match_partial(list, partial)
  return sort(filter(a:list, "v:val =~ '^" . a:partial . "'"))
endfunction

function neovimpv#complete#log_level(arg_lead, cmd_line, cursor_pos)
  " return ["DEBUG", "NOTSET"]
  return ["mpv", "protocol"]
endfunction

function neovimpv#complete#mpv_close_pause(arg_lead, cmd_line, cursor_pos)
  return ["all", ""]
endfunction

" Begin deluge of mpv properties -----------------------------------------------
let s:mpv_writable_properties = [
      \ "percent-pos",
      \ "time-pos",
      \ "playback-time",
      \ "chapter",
      \ "edition",
      \ "edition-list/0/id",
      \ "ao-volume",
      \ "ao-mute",
      \ "hwdec",
      \ "window-scale",
      \ "current-window-scale",
      \ "video-aspect",
      \ "playlist-pos",
      \ "playlist-pos-1",
      \ "playlist-current-pos",
      \ "chapter-list",
      \ "af",
      \ "vf",
      \ "cursor-autohide",
      \ "audio-device",
      \ "shared-script-properties",
      \ "user-data",
      \
      \ "volume",
      \ ]

let mpv_track_properties = [
      \ "id",
      \ "type",
      \ "src-id",
      \ "title",
      \ "lang",
      \ "image",
      \ "albumart",
      \ "default",
      \ "forced",
      \ "auto-forced-only",
      \ "codec",
      \ "external",
      \ "external-filename",
      \ "selected",
      \ "main-selection",
      \ "ff-index",
      \ "decoder-desc",
      \ "demux-w",
      \ "demux-h",
      \ "demux-channel-count",
      \ "demux-channels",
      \ "demux-samplerate",
      \ "demux-fps",
      \ "demux-bitrate",
      \ "demux-rotation",
      \ "demux-par",
      \ "replaygain-track-peak",
      \ "replaygain-track-gain",
      \ "replaygain-album-peak",
      \ "replaygain-album-gain",
      \ ]

let s:mpv_readable_properties = [
      \ "audio-speed-correction",
      \ "video-speed-correction",
      \ "display-sync-active",
      \ "filename",
      \ "filename/no-ext",
      \ "file-size",
      \ "estimated-frame-count",
      \ "estimated-frame-number",
      \ "pid",
      \ "path",
      \ "stream-open-filename",
      \ "media-title",
      \ "file-format",
      \ "current-demuxer",
      \ "stream-path",
      \ "stream-pos",
      \ "stream-end",
      \ "duration",
      \ "avsync",
      \ "total-avsync-change",
      \ "decoder-frame-drop-count",
      \ "frame-drop-count",
      \ "mistimed-frame-count",
      \ "vsync-ratio",
      \ "vo-delayed-frame-count",
      \ "time-start",
      \ "time-remaining",
      \ "audio-pts",
      \ "playtime-remaining",
      \ "current-edition",
      \ "chapters",
      \ "editions",
      \ "edition-list",
      \ "edition-list/count",
      \ "edition-list/0/default",
      \ "edition-list/0/title",
      \ "metadata",
      \ "metadata/list/count",
      \ "metadata/list/0/key",
      \ "metadata/list/0/value",
      \ "filtered-metadata",
      \ "chapter-metadata",
      \ "idle-active",
      \ "core-idle",
      \ "cache-speed",
      \ "demuxer-cache-duration",
      \ "demuxer-cache-time",
      \ "demuxer-cache-idle",
      \ "demuxer-cache-state",
      \ "demuxer-via-network",
      \ "demuxer-start-time",
      \ "paused-for-cache",
      \ "cache-buffering-state",
      \ "eof-reached",
      \ "seeking",
      \ "mixer-active",
      \ "audio-codec",
      \ "audio-codec-name",
      \ "audio-params",
      \ "audio-params/format",
      \ "audio-params/samplerate",
      \ "audio-params/channels",
      \ "audio-params/hr-channels",
      \ "audio-params/channel-count",
      \ "audio-out-params",
      \ "colormatrix",
      \ "colormatrix-input-range",
      \ "colormatrix-primaries",
      \ "hwdec-current",
      \ "hwdec-interop",
      \ "video-format",
      \ "video-codec",
      \ "width",
      \ "height",
      \ "video-params",
      \ "video-params/pixelformat",
      \ "video-params/hw-pixelformat",
      \ "video-params/average-bpp",
      \ "video-params/w, video-params/h",
      \ "video-params/dw, video-params/dh",
      \ "video-params/aspect",
      \ "video-params/par",
      \ "video-params/colormatrix",
      \ "video-params/colorlevels",
      \ "video-params/primaries",
      \ "video-params/gamma",
      \ "video-params/sig-peak",
      \ "video-params/light",
      \ "video-params/chroma-location",
      \ "video-params/rotate",
      \ "video-params/stereo-in",
      \ "video-params/alpha",
      \ "dwidth",
      \ "dheight",
      \ "video-dec-params",
      \ "video-out-params",
      \ "video-frame-info",
      \ "video-frame-info/picture-type",
      \ "video-frame-info/interlaced",
      \ "video-frame-info/tff",
      \ "video-frame-info/repeat",
      \ "container-fps",
      \ "estimated-vf-fps",
      \ "focused",
      \ "display-names",
      \ "display-fps",
      \ "estimated-display-fps",
      \ "vsync-jitter",
      \ "display-width, display-height",
      \ "display-hidpi-scale",
      \ "osd-width",
      \ "osd-height",
      \ "osd-par",
      \ "osd-dimensions",
      \ "osd-dimensions/w",
      \ "osd-dimensions/h",
      \ "osd-dimensions/par",
      \ "osd-dimensions/aspect",
      \ "osd-dimensions/mt",
      \ "osd-dimensions/mb",
      \ "osd-dimensions/ml",
      \ "osd-dimensions/mr",
      \ "window-id",
      \ "mouse-pos",
      \ "mouse-pos/x",
      \ "mouse-pos/y",
      \ "mouse-pos/hover",
      \ "sub-text",
      \ "sub-text-ass",
      \ "secondary-sub-text",
      \ "sub-start",
      \ "secondary-sub-start",
      \ "sub-end",
      \ "secondary-sub-end",
      \ "sub-forced-only-cur",
      \ "playlist-playing-pos",
      \ "playlist-count",
      \ "playlist",
      \ "playlist/count",
      \ "playlist/0/filename",
      \ "playlist/0/playing",
      \ "playlist/0/current",
      \ "playlist/0/title",
      \ "playlist/0/id",
      \ "chapter-list/count",
      \ "chapter-list/0/title",
      \ "chapter-list/0/time",
      \ "seekable",
      \ "partially-seekable",
      \ "playback-abort",
      \ "osd-sym-cc",
      \ "osd-ass-cc",
      \ "vo-configured",
      \ "vo-passes",
      \ "perf-info",
      \ "video-bitrate",
      \ "audio-bitrate",
      \ "sub-bitrate",
      \ "packet-video-bitrate",
      \ "packet-audio-bitrate",
      \ "packet-sub-bitrate",
      \ "audio-device-list",
      \ "current-vo",
      \ "current-ao",
      \ "working-directory",
      \ "protocol-list",
      \ "decoder-list",
      \ "encoder-list",
      \ "demuxer-lavf-list",
      \ "input-key-list",
      \ "mpv-version",
      \ "mpv-configuration",
      \ "ffmpeg-version",
      \ "libass-version",
      \ "platform",
      \ "property-list",
      \ "profile-list",
      \ "command-list",
      \ "input-bindings"
      \ ]

" End deluge of mpv properties -------------------------------------------------

" Add writable properties to readable
call extend(s:mpv_readable_properties, s:mpv_writable_properties)

" add current-tracks and track-list
for i in mpv_track_properties
  for j in ["video", "audio", "sub", "sub2"]
    call add(s:mpv_readable_properties, "current-tracks/" . j . "/" . i)
  endfor
  call add(s:mpv_readable_properties, "track-list/0/" . i)
endfor

" Begin mpv commands -----------------------------------------------------------

let screenshot_args = ["subtitles", "video", "window", "each-frame"]
let sub_add_args = [[], ["select", "auto", "cached"], [], []]

let s:mpv_commands = {
      \ "seek": [
          \ [],
          \ ["relative", "absolute", "absolute-percent", "relative-percent", "keyframes", "exact"]
      \ ],
      \ "revert-seek": [
          \ ["mark", "mark-permanent"]
      \ ],
      \ "frame-step": [],
      \ "frame-step-back": [],
      \ "set": [s:mpv_writable_properties],
      \ "del": [s:mpv_writable_properties],
      \ "add": [s:mpv_writable_properties],
      \ "cycle": [s:mpv_writable_properties],
      \ "multiply": [s:mpv_writable_properties],
      \ "screenshot": [screenshot_args],
      \ "screenshot-to-file": [[], screenshot_args],
      \ "playlist-next": [["weak", "force"]],
      \ "loadfile": [[], ["replace", "append", "append-play"]],
      \ "loadlist": [[], ["replace", "append", "append-play"]],
      \ "playlist-clear": [],
      \ "playlist-remove": [],
      \ "playlist-move": [],
      \ "playlist-shuffle": [],
      \ "playlist-unshuffle": [],
      \ "run": [],
      \ "subprocess": [],
      \ "quit": [],
      \ "quit-watch-later": [],
      \ "sub-add": sub_add_args,
      \ "sub-remove": [],
      \ "sub-reload": [],
      \ "sub-step": [[], ["primary", "secondary"]],
      \ "sub-seek": [[], ["primary", "secondary"]],
      \ "print-text": [],
      \ "show-text": [],
      \ "expand-text": [],
      \ "expand-path": [],
      \ "show-progress": [],
      \ "write-watch-later-config": [],
      \ "delete-watch-later-config": [],
      \ "stop": [["keep-playlist"]],
      \ "mouse": [[], [], [], ["single", "double"]],
      \ "keypress": [],
      \ "keydown": [],
      \ "keyup": [],
      \ "keybind": [],
      \ "audio-add": sub_add_args,
      \ "audio-remove": [],
      \ "audio-reload": [],
      \ "video-add": sub_add_args,
      \ "video-remove": [],
      \ "video-reload": [],
      \ "rescan-external-files": [["reselect", "keep-selection"]],
      \
      \ "client_name": [],
      \ "get_time_us": [],
      \ "get_property": [s:mpv_readable_properties],
      \ "get_property_string": [s:mpv_readable_properties],
      \ "set_property": [s:mpv_writable_properties],
      \ "set_property_string": [s:mpv_writable_properties],
      \ "observe_property": [s:mpv_readable_properties],
      \ "observe_property_string": [s:mpv_readable_properties],
      \ "unobserve_property": [s:mpv_readable_properties],
      \ "request_log_messages": [],
      \ "enable_event": [],
      \ "disable_event": [],
      \ "get_version": [],
      \ }
" End mpv commands -------------------------------------------------------------

function neovimpv#complete#mpv_command(arg_lead, cmd_line, cursor_pos)
  let argnumber = s:get_argnum(a:cmd_line, a:cursor_pos)

  if argnumber == 1
    return s:match_partial(s:mpv_commands, a:arg_lead)
  endif

  " complete a subcommand, using s:mpv_commands
  let subcommand = s:get_subcommand(a:cmd_line, a:cursor_pos)
  let command_completer = get(s:mpv_commands, subcommand, [])
  return s:match_partial(get(command_completer, argnumber - 2, []), a:arg_lead)
endfunction

function neovimpv#complete#mpv_get_property(arg_lead, cmd_line, cursor_pos)
  let cmd_partial = a:cmd_line[:a:cursor_pos + 1]
  let cmd_split_by_space = filter(split(cmd_partial, " "), "v:val != ''")
  let argnumber = s:get_argnum(a:cmd_line, a:cursor_pos)

  if argnumber == 1
    return s:match_partial(s:mpv_readable_properties, a:arg_lead)
  endif
  return []
endfunction

function neovimpv#complete#mpv_set_property(arg_lead, cmd_line, cursor_pos)
  let argnumber = s:get_argnum(a:cmd_line, a:cursor_pos)

  if argnumber == 1
    return s:match_partial(s:mpv_writable_properties, a:arg_lead)
  endif
  return []
endfunction
