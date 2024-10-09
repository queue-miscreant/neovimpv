-- neovimpv.youtube.push_results
--
-- Utility functionality for pushing YouTube contents to nvim.
-- Interaction is handled by neovimpv.youtube.interact

local push_results = {}

---Open some content in a split to run a callback
---
---@param input [string, YTSearchResult][] Inputs in the new split.
---The first item is the line of text in the split.
---The second item of the tuple is used for the callback.
---@param old_window? integer The window to return the cursor to after making a selection.
---@param height? integer The height of the split.
function push_results.open_select_split(input, old_window, height)
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
  if type(height) == "number" then
    vim.cmd("resize " .. tostring(height))
  end
  local win = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- Set buffer content
  vim.api.nvim_buf_call(buf, function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, buf_lines)
    vim.b.mpv_selection = content
    if type(old_window) ~= "number" then
      old_window = win
    end
    vim.b.mpv_calling_window = old_window

    vim.bo.modifiable = false
    vim.bo.filetype = "youtube_results"
  end)
end

-- TODO: user chooses to paste in whole playlist, open in split, open in vert split, open in new tab

---@param playlist {markdown: string}[]
---@param extra string Extra arguments to pass to `MpvOpen`
---@param old_window? integer The window to return the cursor to after making a selection.
function push_results.open_playlist_results(playlist, extra, old_window)
  -- parse input
  local buf_lines = {}
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
  -- vim.api.nvim_buf_set_var(buf, "mpv_selection", content)
  if type(old_window) ~= "number" then
    old_window = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_buf_set_var(buf, "mpv_calling_window", old_window)

  -- set options for new buffer/window
  vim.api.nvim_win_set_option(win, "number", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "youtube_playlist")

  vim.cmd("%MpvOpen " .. extra)
end

---@param text string The line to paste as.
---@param window_number integer The window to paste the result into.
---@param move_cursor? boolean Whether to attempt moving the cursor after pasting.
function push_results.paste_result(text, window_number, move_cursor)
  -- Insert `value` at the line of the current cursor, if it's empty.
  -- Otherwise, insert it a line below the current line.
  local buffer_number = vim.fn.winbufnr(window_number)
  local cursor_row = vim.fn.line(".", window_number)
  -- append the text only if the current line isn't blank
  local append_line = vim.fn.getbufoneline(buffer_number, cursor_row) ~= ""

  local modifiable = vim.api.nvim_buf_get_option(buffer_number, "modifiable")
  if not modifiable then
    vim.notify("Buffer is not modifiable. Cannot paste result.")
    return
  end

  if append_line then
    vim.fn.appendbufline(buffer_number, cursor_row, text)
    if move_cursor == nil then
      vim.cmd("normal j")
    end
  else
    vim.fn.setbufline(buffer_number, cursor_row, text)
  end
end

return push_results
