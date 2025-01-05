local helpers = require "neovimpv.helpers"
local tracker = require "neovimpv.extmarks.tracker"

local actions = {}

-- Paste a list of links where the cursor is and tag for download.
-- Writes markdown if the buffer's filetype supports markdown.
--
---@param files PasteContent|PasteContent[]
---@param with_video boolean
---@param window? integer
---@param line_number? integer
function actions.paste_and_download(files, with_video, window, line_number)
  vim.api.nvim_win_call(window or 0, function()
    local start, end_ = helpers.paste_links(files, window, line_number)

    if start and end_ then
      tracker.tag_extmark(start, end_, with_video)
      tracker.download_next_extmark()
    end
  end)
end

-- Paste a list of links where the cursor is, then call MpvOpen on them.
-- Writes markdown if the buffer's filetype supports markdown.
--
---@param files PasteContent|PasteContent[]
---@param extra string
---@param window? integer
---@param line_number? integer
function actions.paste_and_play(files, extra, window, line_number)
  vim.api.nvim_win_call(window or 0, function()
    local start, end_ = helpers.paste_links(files, window, line_number)

    -- MpvOpen on the inserted line(s)
    if start and end_ then
      vim.cmd(
        (":%s,%sMpvOpen %s"):format(start, end_, extra)
      )
    end
  end)
end

return actions
