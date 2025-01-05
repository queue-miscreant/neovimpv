local helpers = require "neovimpv.helpers"
local download = require "neovimpv.youtube.download"

local tracker = {}

tracker.VIDEO_TAG = "NonText"

---@class MarkdownLink
---@field url string
---@field title string


---@param url string
---@return MarkdownLink?
local function extract_url(url)
  local title, maybe_url = helpers.unmarkdownify(url)
  if maybe_url then
    url = maybe_url
  else
    title = ""
  end

  if not url:find("^https?://") then
    return
  end

  return {
    title = title,
    url = maybe_url,
  }
end

-- Add extmarks in the download namespace for the line range given
--
---@param start integer Start of range, 1-based
---@param end_ integer End of range, 1-based
---@param with_video boolean Download with video
function tracker.tag_extmark(start, end_, with_video)
  if start > end_ then return end
  local lines = vim.fn.getline(start, end_)

  for i, line in ipairs(lines) do
    if extract_url(line) then
      vim.api.nvim_buf_set_extmark(
        0,
        helpers.download_namespace,
        start + i - 1 - 1,
        0,
        {
          virt_text = {{"", with_video and tracker.VIDEO_HIGHLIGHT or ""}},
          sign_text = "D",
          sign_hl_group = "MpvDownloadSign",
          conceal = " ",
        }
      )
    end
  end
end


---@param last_extmark integer
---@param ytdl_file YtdlFile?
local function extmark_callback(last_extmark, ytdl_file)
  local target_extmark = vim.api.nvim_buf_get_extmark_by_id(
    0,
    helpers.download_namespace,
    last_extmark,
    {}
  )

  if target_extmark[1] and ytdl_file then
    vim.fn.setline(
      target_extmark[1] + 1,
      helpers.markdownify(ytdl_file.title, ytdl_file.filename)
    )
  end

  vim.api.nvim_buf_del_extmark(
    0,
    helpers.download_namespace,
    last_extmark
  )

  vim.defer_fn(tracker.download_next_extmark, 0)
end


function tracker.download_next_extmark()
  local downloadables = vim.api.nvim_buf_get_extmarks(
    0,
    helpers.download_namespace,
    0,
    -1,
    { details = true }
  )

  if #downloadables == 0 then
    return
  end

  local line = vim.fn.getline(downloadables[1][2] + 1)
  local with_video = downloadables[1][4].virt_text[1][2] == tracker.VIDEO_TAG
  local markdown = extract_url(line)
  if not markdown then
    return
  end

  download(
    markdown.url,
    with_video,
    function(ytdl_file) extmark_callback(downloadables[1][1], ytdl_file) end
  )
end

return tracker
