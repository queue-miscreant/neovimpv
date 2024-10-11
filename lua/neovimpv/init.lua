-- neovimpv.lua
--
-- Collects all Lua functionality into a single file for import.
-- Lua functions are used to reduce IPC with for repeated editor
-- manipulations, such as setting buffer contents or getting/setting extmarks.

local player = require "neovimpv.player"
local playlist = require "neovimpv.playlist"
local youtube = require "neovimpv.youtube"
local formatting = require "neovimpv.formatting"
local config = require "neovimpv.config"
local consts = require "neovimpv.consts"

local keys = require "neovimpv.keys"

local neovimpv = {
  player = player,
  playlist = playlist,
  youtube = youtube,
  formatting = formatting,
  config = config, -- Temporary
  consts = consts,
}

local function push_python_options()
  vim.fn.MpvSetOptions{
    mpv_properties = formatting.mpv_properties,
    markdown_writable = config.markdown_writable,
    on_playlist_update = config.on_playlist_update,
    smart_youtube = config.smart_youtube_playlist,
    default_mpv_args = config.default_args,
  }
end

function neovimpv.setup(opts)
  config.load_globals(opts)
  formatting.parse_user_settings()
  keys.bind_base()

  pcall(push_python_options)

  vim.api.nvim_create_augroup("MpvSmartBindings", {clear = true})
  vim.api.nvim_create_autocmd(
    "FileType",
    {
      group = "MpvSmartBindings",
      pattern = config.smart_filetypes,
      callback = function()
        keys.bind_smart_local()
      end
    }
  )
  vim.api.nvim_create_autocmd(
    "FileType",
    {
      pattern = "youtube_results",
      callback = youtube.bind_buffer_results,
    }
  )
  vim.api.nvim_create_autocmd(
    "FileType",
    {
      pattern = "youtube_playlist",
      callback = youtube.bind_buffer_playlist,
    }
  )
  vim.api.nvim_create_autocmd(
    "VimEnter",
    {
      callback = push_python_options
    }
  )
end

vim.neovimpv = neovimpv
return neovimpv
