-- neovimpv
--
-- Collects all Lua functionality into a single file for import.
-- Lua functions are used to reduce IPC with for repeated editor
-- manipulations, such as setting buffer contents or getting/setting extmarks.

local config = require "neovimpv.config"
local actions = require "neovimpv.actions"
local keys = require "neovimpv.keys"
local formatting = require "neovimpv.formatting"
local youtube_push_results = require "neovimpv.youtube.push_results"
local youtube_interact = require "neovimpv.youtube.interact"
local from_python = require "neovimpv.from_python"


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

  from_python.setup_commands()
end

-- Exposed Lua callbacks for Python
vim._neovimpv_callbacks = {
  -- youtube.py
  open_youtube_select_split = youtube_push_results.open_select_split,
  paste_youtube_result = youtube_push_results.paste_result,
  open_youtube_playlist_results = youtube_push_results.open_playlist_results,
}

return neovimpv
