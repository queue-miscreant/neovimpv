-- completion.lua
-- Completion functions for user commands
--
-- TODO: extend shell lexification to Mpv command parsing

local completion = {}

local list_extend = vim.list_extend
local list_slice = vim.list_slice
local tbl_keys = vim.tbl_keys
local tbl_filter = vim.tbl_filter
local split = vim.split

-- Get first argument to command
---@param cmd_line string
---@param cursor_pos integer
local function get_subcommand(cmd_line, cursor_pos)
  local cmd_partial = cmd_line:sub(1, cursor_pos + 2)
  local cmd_split_by_space = tbl_filter(
    function(val) return val ~= "" end,
    split(cmd_partial, " ")
  )
  return cmd_split_by_space[1] or ""
end

-- Get current argument number
---@param cmd_line string
---@param cursor_pos integer
local function get_argnum(cmd_line, cursor_pos)
  local cmd_partial = cmd_line:sub(1, cursor_pos + 2)
  local cmd_split_by_space = tbl_filter(
    function(val) return val ~= "" end,
    split(cmd_partial, " ")
  )
  return #cmd_split_by_space - 1 + (cmd_partial:sub(-1) == " " and 1 or 0)
end

-- Find entries of `list` which start with `partial` and sort them
---@param list string[]
---@param partial string
local function match_partial(list, partial)
  local partial_pattern = partial:gsub("%%", "%%"):gsub("%.", "%.")
  vim.print(partial_pattern)
  local filtered = tbl_filter(
    function(val)
      return val:find("^" .. partial_pattern)
    end,
    list_slice(list)
  )
  table.sort(filtered)
  return filtered
end

-- Begin deluge of mpv properties -----------------------------------------------
local mpv_writable_properties = {
  "percent-pos",
  "time-pos",
  "playback-time",
  "chapter",
  "edition",
  "edition-list/0/id",
  "ao-volume",
  "ao-mute",
  "hwdec",
  "window-scale",
  "current-window-scale",
  "video-aspect",
  "playlist-pos",
  "playlist-pos-1",
  "playlist-current-pos",
  "chapter-list",
  "af",
  "vf",
  "cursor-autohide",
  "audio-device",
  "shared-script-properties",
  "user-data",
  "volume",
}

local mpv_track_properties = {
  "id",
  "type",
  "src-id",
  "title",
  "lang",
  "image",
  "albumart",
  "default",
  "forced",
  "auto-forced-only",
  "codec",
  "external",
  "external-filename",
  "selected",
  "main-selection",
  "ff-index",
  "decoder-desc",
  "demux-w",
  "demux-h",
  "demux-channel-count",
  "demux-channels",
  "demux-samplerate",
  "demux-fps",
  "demux-bitrate",
  "demux-rotation",
  "demux-par",
  "replaygain-track-peak",
  "replaygain-track-gain",
  "replaygain-album-peak",
  "replaygain-album-gain",
}

local mpv_readable_properties = {
  "audio-speed-correction",
  "video-speed-correction",
  "display-sync-active",
  "filename",
  "filename/no-ext",
  "file-size",
  "estimated-frame-count",
  "estimated-frame-number",
  "pid",
  "path",
  "stream-open-filename",
  "media-title",
  "file-format",
  "current-demuxer",
  "stream-path",
  "stream-pos",
  "stream-end",
  "duration",
  "avsync",
  "total-avsync-change",
  "decoder-frame-drop-count",
  "frame-drop-count",
  "mistimed-frame-count",
  "vsync-ratio",
  "vo-delayed-frame-count",
  "time-start",
  "time-remaining",
  "audio-pts",
  "playtime-remaining",
  "current-edition",
  "chapters",
  "editions",
  "edition-list",
  "edition-list/count",
  "edition-list/0/default",
  "edition-list/0/title",
  "metadata",
  "metadata/list/count",
  "metadata/list/0/key",
  "metadata/list/0/value",
  "filtered-metadata",
  "chapter-metadata",
  "idle-active",
  "core-idle",
  "cache-speed",
  "demuxer-cache-duration",
  "demuxer-cache-time",
  "demuxer-cache-idle",
  "demuxer-cache-state",
  "demuxer-via-network",
  "demuxer-start-time",
  "paused-for-cache",
  "cache-buffering-state",
  "eof-reached",
  "seeking",
  "mixer-active",
  "audio-codec",
  "audio-codec-name",
  "audio-params",
  "audio-params/format",
  "audio-params/samplerate",
  "audio-params/channels",
  "audio-params/hr-channels",
  "audio-params/channel-count",
  "audio-out-params",
  "colormatrix",
  "colormatrix-input-range",
  "colormatrix-primaries",
  "hwdec-current",
  "hwdec-interop",
  "video-format",
  "video-codec",
  "width",
  "height",
  "video-params",
  "video-params/pixelformat",
  "video-params/hw-pixelformat",
  "video-params/average-bpp",
  "video-params/w, video-params/h",
  "video-params/dw, video-params/dh",
  "video-params/aspect",
  "video-params/par",
  "video-params/colormatrix",
  "video-params/colorlevels",
  "video-params/primaries",
  "video-params/gamma",
  "video-params/sig-peak",
  "video-params/light",
  "video-params/chroma-location",
  "video-params/rotate",
  "video-params/stereo-in",
  "video-params/alpha",
  "dwidth",
  "dheight",
  "video-dec-params",
  "video-out-params",
  "video-frame-info",
  "video-frame-info/picture-type",
  "video-frame-info/interlaced",
  "video-frame-info/tff",
  "video-frame-info/repeat",
  "container-fps",
  "estimated-vf-fps",
  "focused",
  "display-names",
  "display-fps",
  "estimated-display-fps",
  "vsync-jitter",
  "display-width, display-height",
  "display-hidpi-scale",
  "osd-width",
  "osd-height",
  "osd-par",
  "osd-dimensions",
  "osd-dimensions/w",
  "osd-dimensions/h",
  "osd-dimensions/par",
  "osd-dimensions/aspect",
  "osd-dimensions/mt",
  "osd-dimensions/mb",
  "osd-dimensions/ml",
  "osd-dimensions/mr",
  "window-id",
  "mouse-pos",
  "mouse-pos/x",
  "mouse-pos/y",
  "mouse-pos/hover",
  "sub-text",
  "sub-text-ass",
  "secondary-sub-text",
  "sub-start",
  "secondary-sub-start",
  "sub-end",
  "secondary-sub-end",
  "sub-forced-only-cur",
  "playlist-playing-pos",
  "playlist-count",
  "playlist",
  "playlist/count",
  "playlist/0/filename",
  "playlist/0/playing",
  "playlist/0/current",
  "playlist/0/title",
  "playlist/0/id",
  "chapter-list/count",
  "chapter-list/0/title",
  "chapter-list/0/time",
  "seekable",
  "partially-seekable",
  "playback-abort",
  "osd-sym-cc",
  "osd-ass-cc",
  "vo-configured",
  "vo-passes",
  "perf-info",
  "video-bitrate",
  "audio-bitrate",
  "sub-bitrate",
  "packet-video-bitrate",
  "packet-audio-bitrate",
  "packet-sub-bitrate",
  "audio-device-list",
  "current-vo",
  "current-ao",
  "working-directory",
  "protocol-list",
  "decoder-list",
  "encoder-list",
  "demuxer-lavf-list",
  "input-key-list",
  "mpv-version",
  "mpv-configuration",
  "ffmpeg-version",
  "libass-version",
  "platform",
  "property-list",
  "profile-list",
  "command-list",
  "input-bindings"
}

-- End deluge of mpv properties -------------------------------------------------

-- Add writable properties to readable
list_extend(mpv_readable_properties, mpv_writable_properties)

-- add current-tracks and track-list
for _, i in ipairs(mpv_track_properties) do
  for _, j in ipairs{"video", "audio", "sub", "sub2"} do
    table.insert(mpv_readable_properties, "current-tracks/" .. j .. "/" .. i)
  end
  table.insert(mpv_readable_properties, "track-list/0/" .. i)
end

-- Begin mpv commands -----------------------------------------------------------

local screenshot_args = {"subtitles", "video", "window", "each-frame"}
local sub_add_args = {{}, {"select", "auto", "cached"}, {}, {}}

local mpv_commands = {
  seek = {
    {},
    {"relative", "absolute", "absolute-percent", "relative-percent", "keyframes", "exact"}
  },
  ["revert-seek"] = {
    {"mark", "mark-permanent"}
  },
  ["frame-step"] = {},
  ["frame-step-back"] = {},
  set = {mpv_writable_properties},
  del = {mpv_writable_properties},
  add = {mpv_writable_properties},
  cycle = {mpv_writable_properties},
  multiply = {mpv_writable_properties},
  screenshot = {screenshot_args},
  ["screenshot-to-file"] = {{}, screenshot_args},
  ["playlist-next"] = {{"weak", "force"}},
  loadfile = {{}, {"replace", "append", "append-play"}},
  loadlist = {{}, {"replace", "append", "append-play"}},
  ["playlist-clear"] = {},
  ["playlist-remove"] = {},
  ["playlist-move"] = {},
  ["playlist-shuffle"] = {},
  ["playlist-unshuffle"] = {},
  run = {},
  subprocess = {},
  quit = {},
  ["quit-watch-later"] = {},
  ["sub-add"] = sub_add_args,
  ["sub-remove"] = {},
  ["sub-reload"] = {},
  ["sub-step"] = {{}, {"primary", "secondary"}},
  ["sub-seek"] = {{}, {"primary", "secondary"}},
  ["print-text"] = {},
  ["show-text"] = {},
  ["expand-text"] = {},
  ["expand-path"] = {},
  ["show-progress"] = {},
  ["write-watch-later-config"] = {},
  ["delete-watch-later-config"] = {},
  stop = {{"keep-playlist"}},
  mouse = {{}, {}, {}, {"single", "double"}},
  keypress = {},
  keydown = {},
  keyup = {},
  keybind = {},
  ["audio-add"] = sub_add_args,
  ["audio-remove"] = {},
  ["audio-reload"] = {},
  ["video-add"] = sub_add_args,
  ["video-remove"] = {},
  ["video-reload"] = {},
  ["rescan-external-files"] = {{"reselect", "keep-selection"}},

  client_name = {},
  get_time_us = {},
  get_property = {mpv_readable_properties},
  get_property_string = {mpv_readable_properties},
  set_property = {mpv_writable_properties},
  set_property_string = {mpv_writable_properties},
  observe_property = {mpv_readable_properties},
  observe_property_string = {mpv_readable_properties},
  unobserve_property = {mpv_readable_properties},
  request_log_messages = {},
  enable_event = {},
  disable_event = {},
  get_version = {},
}
-- End mpv commands -------------------------------------------------------------


function completion.mpv_close_pause(arg_lead, cmd_line, cursor_pos)
  -- TODO: buffer numbers recognized by the plugin
  return {"all", "buffer", ""}
end

-- Complete mpv command
function completion.mpv_command(arg_lead, cmd_line, cursor_pos)
  local argnumber = get_argnum(cmd_line, cursor_pos)

  if argnumber == 1 then
    return match_partial(tbl_keys(mpv_commands), arg_lead)
  end

  -- complete a subcommand, using mpv_commands
  local subcommand = get_subcommand(cmd_line, cursor_pos)
  local command_completer = mpv_commands[subcommand] or {}
  return match_partial(command_completer[argnumber - 2] or {}, arg_lead)
end

-- Complete readable properties
function completion.mpv_get_property(arg_lead, cmd_line, cursor_pos)
  local argnumber = get_argnum(cmd_line, cursor_pos)

  if argnumber == 1 then
    return match_partial(mpv_readable_properties, arg_lead)
  end
  return {}
end

-- Complete writable properties
function completion.mpv_set_property(arg_lead, cmd_line, cursor_pos)
  local argnumber = get_argnum(cmd_line, cursor_pos)

  if argnumber == 1 then
    return match_partial(mpv_writable_properties, arg_lead)
  end
  return {}
end

return completion
