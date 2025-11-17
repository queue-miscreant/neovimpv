local config = require "neovimpv.config"
local helpers = require "neovimpv.helpers"
local download_tracker = require "neovimpv.youtube.extmarks"
local mpv = require "neovimpv.mpv"

local actions = {}

-- Insert `value` at the line of the current cursor, if it's empty.
-- Otherwise, insert it a line below the current line.
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
---@param files PasteContent|PasteContent[]
---@param window? integer
---@param line_number? integer
---@return integer?, integer?
local function paste_links(files, window, line_number)
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

-- Paste a list of links where the cursor is and tag for download.
-- Writes markdown if the buffer's filetype supports markdown.
--
---@param files PasteContent|PasteContent[]
---@param with_video boolean
---@param window? integer
---@param line_number? integer
function actions.paste_and_download(files, with_video, window, line_number)
  vim.api.nvim_win_call(window or 0, function()
    local start, end_ = paste_links(files, window, line_number)

    if start and end_ then
      local buffer_id = vim.fn.bufnr()
      vim.defer_fn(function()
        download_tracker.tag_extmark(buffer_id, start, end_, with_video)
        download_tracker.start_downloader(buffer_id)
      end, 0)
    end
  end)
end

-- Paste a list of links where the cursor is, then call MpvOpen on them.
-- Writes markdown if the buffer's filetype supports markdown.
--
---@param files PasteContent|PasteContent[]
---@param extra? MpvLocalArgs
---@param window? integer
---@param line_number? integer
function actions.paste_and_play(files, extra, window, line_number)
  vim.api.nvim_win_call(window or 0, function()
    local start, end_ = paste_links(files, window, line_number)

    -- MpvOpen on the inserted line(s)
    if start and end_ then
      local lines_to_links = helpers.multi_line(
        vim.fn.getline(start, end_) --[[@as string[] ]],
        start,
        nil,
        end_,
        nil,
        "vline"
      )

      local buffer_id = vim.fn.bufnr()
      vim.defer_fn(function()
        mpv.new(buffer_id, lines_to_links, extra or {})
      end, 0)
    end
  end)
end

return actions
