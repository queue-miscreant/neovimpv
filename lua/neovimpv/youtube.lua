#!/usr/bin/lua
-- neovimpv/youtube.lua
--
-- Utility functionality for pushing YouTube contents to nvim.
-- Callbacks are handled by autoload/neovimpv/youtube.vim and binds are handled
-- by ftplugin/youtube_results.vim.

-- Open some content in a split to run a callback
--
-- `input`
--      A list of 2-tuples (tables).
--      The first item is the line of text that should be displayed.
--      The second is a value that will be used for the callback.
--
-- `filetype`
--      The filetype of the buffer to open in a split. There should be an
--      autocommand for this filetype that establishes callbacks for each of the lines.
--
-- `height` (optional)
--      The height of the split
--
function neovimpv.open_select_split(input, filetype, height)
  local old_window = vim.api.nvim_get_current_win()
  -- parse input
  local buf_lines = {}
  local content = {}
  for i = 1, #input do
    local text = input[i][1]
    local value = input[i][2]
    if type(text) ~= "string" or value == nil then
      error("Table value is not of form {string, value}")
    end
    table.insert(buf_lines, text)
    table.insert(content, value)
  end

  -- open split to an empty scratch
  vim.cmd("bel split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
  vim.api.nvim_buf_set_var(buf, "selection", content)
  vim.api.nvim_buf_set_var(buf, "calling_window", old_window)
  if type(height) == "number" then
    vim.cmd("resize " .. tostring(height))
  end

  -- set options for new buffer/window
  vim.api.nvim_win_set_option(win, "number", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", filetype)
end

-- TODO: user chooses to paste in whole playlist, open in split, open in vert split, open in new tab
function neovimpv.open_playlist_results(playlist, extra)
  local old_window = vim.api.nvim_get_current_win()
  -- parse input
  local buf_lines = {}
  local content = {}
  for i = 1, #playlist do
    local text = playlist[i]["markdown"]
    -- local value = playlist[i][2]
    -- if type(text) ~= "string" or value == nil then
    --   error("Table value is not of form {string, value}")
    -- end
    table.insert(buf_lines, text)
    -- table.insert(content, value)
  end

  -- open new tab to an empty scratch
  vim.cmd("tabe")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
  -- vim.api.nvim_buf_set_var(buf, "selection", content)
  vim.api.nvim_buf_set_var(buf, "calling_window", old_window)

  -- set options for new buffer/window
  vim.api.nvim_win_set_option(win, "number", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "youtube_playlist")

  vim.cmd("%MpvOpen " .. extra)
end
