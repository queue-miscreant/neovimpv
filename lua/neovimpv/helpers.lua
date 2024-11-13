local config = require "neovimpv.config"

local helpers = {}

-- Insert `value` at the line of the current cursor, if it's empty.
-- Otherwise, insert it a line below the current line.
---@param values string|string[]
---@param line_number? integer
local function try_insert(values, line_number)
  local row = vim.fn.line(line_number or ".")
  local append_line = vim.fn.getline(line_number or ".") ~= ""

  if append_line then
    vim.fn.append(row, values)
  else
    vim.fn.setline(row, values)
  end

  return append_line
end

-- Paste a list of links where the cursor is, then call MpvOpen on them.
-- Writes markdown if the buffer's filetype supports markdown.
--
---@param files PasteContent|PasteContent[]
---@param extra string
---@param window? integer
---@param line_number? integer
function helpers.paste_and_play(files, extra, window, line_number)
  vim.api.nvim_win_call(window or 0, function()
    -- Normalize to singleton
    if #files == 0 then files = {files} end

    if not vim.bo.modifiable then
      vim.notify("Buffer is not modifiable. Cannot paste result.", vim.log.levels.ERROR)
      return
    end

    local insert_links

    -- Markdownable content
    if vim.list_contains(config.markdown_writable, vim.bo.filetype) then
      insert_links = vim.tbl_map(function(x) return x.markdown end, files)
    else
      insert_links = vim.tbl_map(function(x) return x.link end, files)
    end

    if try_insert(insert_links, line_number) then
      vim.cmd[[normal j]]
    end

    local paste_start = tostring(line_number) or "."
    -- MpvOpen on the inserted line(s)
    vim.cmd((":%s,%s+%dMpvOpen %s"):format(
      paste_start,
      paste_start,
      #insert_links - 1,
      extra
    ))
  end)
end

-- Convert a title and URL pair to a markdown string
--
---@param title string
---@param url string
function helpers.markdownify(title, url)
  return url:find("%(") and url or ("[%s](%s)"):format(title:gsub("[%[%]]", ""), url)
end

return helpers
