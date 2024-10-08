local default_config = {
  -- Formatting variables
  -- These ones are settable from vimrc and have no special interpretation
  loading = "[ ... ]",
  format = "[ {pause} {playback-time} / {duration} {loop} ]",
  style = "unicode",
  property_thresholds = {},
  omni_open_new_if_empty = true,

  -- Markdown-writable files
  markdown_writable = {},

  -- Default arguments for mpv instances
  default_args = {},

  -- When to show playlist extmarks in the sign column
  -- Possible values: "always", "multiple", "never"
  ---@type "always" | "multiple" | "never"
  draw_playlist_extmarks = "multiple",

  -- Controls how playlist updates from mpv can affect changes in the buffer
  on_playlist_update = "stay",

  -- Whether or not YouTube playlists are opened 'smartly'.
  smart_youtube_playlist = true,

  -- Key for scrolling a player to a playlist index
  playlist_key = "\\",
  playlist_key_video = "",

  -- Bind things in `markdown_writable` filetypes
  markdown_smart_bindings = false,

  -- Filetypes which should have smart bindings added by default
  smart_filetypes = {},
}

-- Start with defaults
local config = default_config

function config.load_globals(opts)
  -- Load the new options or global variables
  for option, default_value in pairs(default_config) do
    local global_value = vim.g["mpv_" .. option]
    local lazy_value = opts[option]
    if global_value ~= nil then
      config[option] = global_value
    elseif lazy_value ~= nil then
      config[option] = lazy_value
    end

    if config[option] == nil then
      config[option] = default_value
    end
  end

  table.insert(config.markdown_writable, "youtube_playlist")
  table.insert(config.smart_filetypes, "youtube_playlist")

  -- Key for assigning current playlist item
  if config.playlist_key_video == "" then
    if config.playlist_key == "\\" then
      config.playlist_key_video = "<bar>"
    elseif config.playlist_key == "," then
      config.playlist_key_video = "."
    elseif config.playlist_key == "~" then
      config.playlist_key_video = "`"
    end
  end

  if config.markdown_smart_bindings then
    for _, i in pairs(config.markdown_writable) do
      table.insert(config.smart_filetypes, i)
    end
    config.smart_filetypes = vim.fn.uniq(
      vim.fn.sort(config.smart_filetypes)
    )
  end
end

return config
