-- Update an extmark's content without changing its row or column
local function update_extmark(buffer, namespace, extmark_id, content)
  loc = vim.api.nvim_buf_get_extmark_by_id(buffer, namespace, extmark_id, {})
  if loc ~= nil then
    pcall(function()
      vim.api.nvim_buf_set_extmark(buffer, namespace, loc[1], loc[2], content)
    end)
  end
end

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
local function open_select_split(input, filetype, height)
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

local function bind_default_highlights(froms, to)
  for _, from in pairs(froms) do
    vim.cmd("highlight default link " .. from .. " " .. to)
  end
end

-- TODO: this function is doing a lot; add some auxiliary functions?
local function add_sign_extmarks(buffer, namespace, lines, contents, display_id)
  new_ids = {}
  vim.api.nvim_buf_call(buffer, function()
    dict = vim.b["mpv_playlists_to_displays"]
    if dict == nil then
      vim.b["mpv_playlists_to_displays"] = vim.empty_dict()
      vim.call("neovimpv#bind_autocmd")
    end
    for i, j in pairs(lines) do
      local extmark_id = vim.api.nvim_buf_set_extmark(
        buffer,
        namespace,
        j,
        0,
        {
          sign_text=contents,
          sign_hl_group="MpvPlaylistSign"
        }
      )
      new_ids[i] = { extmark_id, j }
      vim.cmd.let(
        "b:mpv_playlists_to_displays" .. 
        "[" .. tostring(extmark_id) .. "] = " .. 
        tostring(display_id)
      )
    end
  end)
  return new_ids
end

local function remove_mpv_instance(buffer, display_id, playlist_ids)
  vim.api.nvim_buf_del_extmark(
    buffer,
    vim.api.nvim_create_namespace("Neovimpv-displays"),
    display_id
  )
  for _, playlist_id in pairs(playlist_ids) do
    vim.api.nvim_buf_del_extmark(
      buffer,
      vim.api.nvim_create_namespace("Neovimpv-playlists"),
      playlist_id
    )
    vim.api.nvim_buf_call(buffer, function()
      vim.cmd.unlet(
        "b:mpv_playlists_to_displays" .. 
        "[" .. tostring(playlist_id) .. "]"
      )
    end)
  end
end

neovimpv = {
  update_extmark=update_extmark,
  open_select_split=open_select_split,
  bind_default_highlights=bind_default_highlights,
  add_sign_extmarks=add_sign_extmarks,
  remove_mpv_instance=remove_mpv_instance
}
