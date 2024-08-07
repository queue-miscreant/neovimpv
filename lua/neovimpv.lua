#!/usr/bin/lua
-- neovimpv.lua
--
-- Collects all Lua functionality into a single file for import.
-- Lua functions are used to reduce IPC with for repeated vim-related
-- manipulations, such as setting buffer contents or getting/setting extmarks.

local player = require "neovimpv.player"
local playlist = require "neovimpv.playlist"
local youtube = require "neovimpv.youtube"
local formatting = require "neovimpv.formatting"

neovimpv = {
  player = player,
  playlist = playlist,
  youtube = youtube,
  formatting = formatting,
}
neovimpv.formatting.parse_user_settings()
