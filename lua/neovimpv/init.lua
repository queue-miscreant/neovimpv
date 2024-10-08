#!/usr/bin/lua
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
local keys = require "neovimpv.keys"

local neovimpv = {
  player = player,
  playlist = playlist,
  youtube = youtube,
  formatting = formatting,
  config = config, -- Temporary
}

function neovimpv.setup(opts)
  config.load_globals(opts)
  formatting.parse_user_settings()
  keys.bind_base()

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
end

vim.neovimpv = neovimpv
return neovimpv
