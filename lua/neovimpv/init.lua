-- neovimpv
--
-- Collects all Lua functionality into a single file for import.
-- Lua functions are used to reduce IPC with for repeated editor
-- manipulations, such as setting buffer contents or getting/setting extmarks.

local config = require "neovimpv.config"
local actions = require "neovimpv.helpers"
local keys = require "neovimpv.keys"
local formatting = require "neovimpv.formatting"
local youtube_interact = require "neovimpv.youtube.interact"


local neovimpv = {
  formatting = formatting,
  config = config, -- Temporary
  paste_and_play = actions.paste_and_play,
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
      callback = youtube_interact.bind_buffer_results,
    }
  )
  vim.api.nvim_create_autocmd(
    "FileType",
    {
      pattern = "youtube_playlist",
      callback = youtube_interact.bind_buffer_playlist,
    }
  )
  vim.api.nvim_create_autocmd(
    "VimEnter",
    {
      callback = function() pcall(push_python_options) end,
    }
  )

  if vim.list_contains(config.smart_filetypes, vim.bo.filetype) then
    keys.bind_smart_local()
  end
end

-- Exposed callbacks for Python
vim._neovimpv_callbacks = require "neovimpv.python_callbacks"

return neovimpv
