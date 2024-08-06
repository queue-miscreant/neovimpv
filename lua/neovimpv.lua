#!/usr/bin/lua
-- neovimpv.lua
--
-- Collects all Lua functionality into a single file for import.
-- Lua functions are used to reduce IPC with for repeated vim-related
-- manipulations, such as setting buffer contents or getting/setting extmarks.

require"neovimpv/player"
require"neovimpv/playlist"
require"neovimpv/youtube"

neovimpv.format.parse_user_settings()
