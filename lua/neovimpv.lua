-- Update an extmark's content without changing its row or column
local function update_extmark(buffer, namespace, extmark_id, content)
  loc = vim.api.nvim_buf_get_extmark_by_id(buffer, namespace, extmark_id, {})
  if loc ~= nil then
    pcall(function() vim.api.nvim_buf_set_extmark(buffer, namespace, loc[1], loc[2], content) end)
  end
end

-- Open some content in a split to run a callback
--
-- `input`
--      A list of 2-tuples (tables).
--      The first item is the line of text that should be displayed.
--      The second is a value that will be used for the callback.
--
-- `callback_name`
--      The name of a vim function which will be called by the "enter" keypress
--      The function should accept two arguments: the first is the window from
--      which the split was opened, and the second is the expected value.
--
-- `args`
--      A table of extra arguments for the new window/buffer. Can include:
--
--      "height"        the height of the split
--      "buffer_opts"   a table of buffer options in key/value format
--      "window_opts"   a table of window options in key/value format
--
local function open_select_split(input, callbacks, args)
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

  local window_opts = { number=false }
  local buffer_opts = { modifiable=false }
  local height = nil
  -- parse args
  if type(args) == "table" then
    if type(args.buffer_opts) == "table" then
      buffer_opts = vim.tbl_extend("keep", buffer_opts, args.buffer_opts)
    end

    if type(args.window_opts) == "table" then
      window_opts = vim.tbl_extend("keep", window_opts, args.window_opts)
    end

    if type(args.height) == "number" then
      height = args.height
    end
  end

  -- open split
  if type(height) == "number" then
    vim.cmd("bel ".. tostring(height) .. "split")
  else
    vim.cmd("bel split")
  end
  -- make split an empty scratch
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
  vim.api.nvim_buf_set_var(buf, "selection", content)

  -- set options for new buffer/window
  for k, v in pairs(buffer_opts) do
    vim.api.nvim_buf_set_option(buf, k, v)
  end
  for k, v in pairs(window_opts) do
    vim.api.nvim_win_set_option(win, k, v)
  end

  function callback(callnum)
    return ":call" .. callback_name .. "(" .. tostring(old_window) .. ", b:selection[line('.') - 1)"
  end

  -- enter keymap: run function "exec_after" and close buffer
  for i, j in pairs(callbacks) do
    local lhs = j[1]
    local callback_name = j[2]
    local mode = j[3] or "n"
    vim.api.nvim_buf_set_keymap(
      buf,
      mode,
      lhs,
      ":call " .. callback_name .. "(" ..
        tostring(old_window) .. ", b:selection[line('.') - 1])<cr>",
      {silent=true}
    )
  end
end

neovimpv = {
  update_extmark=update_extmark,
  open_select_split=open_select_split
}
