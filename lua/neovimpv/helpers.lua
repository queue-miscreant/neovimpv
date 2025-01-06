local config = require "neovimpv.config"

local helpers = {}

helpers.display_namespace = vim.api.nvim_create_namespace("Neovimpv-displays")
helpers.playlist_namespace = vim.api.nvim_create_namespace("Neovimpv-playlists")
helpers.download_namespace = vim.api.nvim_create_namespace("Neovimpv-downloads")


-- Try writing the buffer, if the `save_on_modify` configuration is enabled
--
---@param buffer integer
function helpers.try_write_buffer(buffer)
  if config.save_on_modify and not (vim.bo[buffer].readonly or not vim.bo[buffer].modifiable) then
    vim.cmd("w")
  end
end

-- Insert `value` at the line of the current cursor, if it's empty.
-- Otherwise, insert it a line below the current line.
--
---@param values string|string[]
---@param line_number? integer
local function try_insert(values, line_number)
  local row = line_number or vim.fn.line(".")
  local append_line = vim.fn.getline(line_number or ".") ~= ""

  if append_line then
    vim.fn.append(row, values)
  else
    vim.fn.setline(row, values)
  end

  helpers.try_write_buffer(0)
  return append_line
end

-- Paste a list of links where the cursor is, then call MpvOpen on them.
-- Writes markdown if the buffer's filetype supports markdown.
--
---@param files PasteContent|PasteContent[]
---@param window? integer
---@param line_number? integer
---@return integer?, integer?
function helpers.paste_links(files, window, line_number)
  local ret = vim.api.nvim_win_call(window or 0, function()
    -- Normalize to singleton
    if #files == 0 then files = {files} end

    if not vim.bo.modifiable then
      vim.notify("Buffer is not modifiable. Cannot paste result.", vim.log.levels.ERROR)
      return {}
    end

    local insert_links
    -- Markdownable content
    if vim.list_contains(config.markdown_writable, vim.bo.filetype) then
      insert_links = vim.tbl_map(function(x) return x.markdown end, files)
    else
      insert_links = vim.tbl_map(function(x) return x.link end, files)
    end

    if try_insert(insert_links, line_number) then
      -- Appended lines start on the next one
      vim.cmd[[normal j]]
      line_number = line_number and line_number + 1
    end

    local paste_start = line_number or vim.fn.line(".")
    return { paste_start, paste_start + #files - 1 }
  end)
  -- nvim calls do not respect multiple return values
  ---@diagnostic disable-next-line
  return unpack(ret)
end

-- Convert a title and URL pair to a markdown string
--
---@param title string
---@param url string
---@return string
function helpers.markdownify(title, url)
  return url:find("%(") and url or ("[%s](%s)"):format(title:gsub("[%[%]]", ""), url)
end

-- Extract the title and URL pair from a markdown string
--
---@param markdown string
---@return string?, string?
function helpers.unmarkdownify(markdown)
  local title, url = markdown:match("^(%b[])(%b())$")
  if not title then return nil end
  -- trim the first and last characters (non-Dijkstra)
  return title:sub(2, -2), url:sub(2, -2)
end

return helpers
