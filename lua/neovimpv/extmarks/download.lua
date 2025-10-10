-- neovimpv/extmarks/download.lua
--
-- Functionality for keeping track of lines containing URLs marked for download.

local helpers = require "neovimpv.helpers"
local config = require "neovimpv.config"
local bind_forward_deletions = require "neovimpv.extmarks.forward_deletions"

local download = {}
local download_next_extmark

---@class NvimSystemCompleted
---@field code integer
---@field signal integer
---@field stdout string?
---@field stderr string?

---@class YtdlFile
---@field title string
---@field filename string
---@field original_url string

---@class MarkdownLink
---@field url string
---@field title string

-- Renames and mutates a list of paths and titles from youtube-dl.
-- Filenames containing the characters "()" are replaced with "[]"
-- Titles containing the characters "[]" are replaced with "()"
-- This renders the files able to be presented in markdown format.
--
---@param file YtdlFile
local function rename_brackets(file)
  local new_filename = file.filename:gsub("%(", "["):gsub("%)", "]")

  vim.fn.rename(
    file.filename,
    new_filename
  )
  file.filename = new_filename
  file.title = file.title:gsub("%[", "("):gsub("%]", ")")
end

-- Parse results from yt-dlp process and invoke callback.
-- `callback` is called with nil if the video could not be downloaded.
--
---@param obj NvimSystemCompleted
---@param callback fun(filename: YtdlFile?)
local function youtube_dl_callback(obj, callback)
  -- Log errors from stderr
  if obj.stderr ~= "" then
    vim.defer_fn(function()
      vim.notify(obj.stderr, vim.log.levels.ERROR)
    end, 0)
  end

  -- local files = {}
  local current_file = {}
  local original_url
  local echo_flag = false

  -- Line with [Exec] precedes the line with the target filepath
  for _, line in ipairs(vim.split(obj.stdout, "\n")) do
    if echo_flag then
      -- Found title
      if line:find("^t ") then
        current_file.title = line:sub(3)
      -- Found original URL; set this only after we're done downloading
      elseif line:find("^u ") then
        original_url = line:sub(3)
      -- Found filename, append to files
      elseif line:find("^f ") then
        current_file.filename = line:sub(3)
        current_file.original_url = original_url
        -- table.insert(files, current_file)
        -- current_file = {}
        break
      end
      echo_flag = false
    end
    if line:find("^%[Exec%]") then
      echo_flag = true
    end
  end

  vim.defer_fn(function()
    if current_file.filename then
      rename_brackets(current_file)
      callback(current_file)
    else
      callback()
    end
  end, 0)
end


-- Use yt-dlp to download a single file, optionally with video.
-- Invokes `callback` with the downloaded filename or nil if the video could
-- not be downloaded.
--
---@param url string
---@param with_video boolean
---@param callback fun(filename: YtdlFile?)
local function download_url(url, with_video, callback)
  if config.youtube_dl.path == "" then
    vim.notify("Could not find yt-dlp executable.", vim.log.levels.WARN)
    return
  end

  local cwd = vim.fn.expand(config.youtube_dl.download_path)

  local youtube_dl_args = {
    config.youtube_dl.path,
    "--exec", "after_move:echo f",
    "--exec", "before_dl:echo t %(title)q",
    "--exec", "before_dl:echo u %(original_url)q",
    unpack(with_video and config.youtube_dl.video_args or config.youtube_dl.audio_args), ---@diagnostic disable-line
  }
  table.insert(youtube_dl_args, url)

  vim.system(
    youtube_dl_args,
    {
      cwd = vim.fn.fnamemodify(cwd, vim.fn.isdirectory(cwd) == 1 and ":p" or ":p:h"),
    },
    function(obj) youtube_dl_callback(obj, callback) end
  )
end

-- Try to extract a markdown tuple from a string.
-- Returns nil if the URL does not start with http
--
---@param url string
---@return MarkdownLink?
local function extract_url(url)
  vim.print(url)
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

-- Add download extmarks to the current buffer for the line range given.
--
---@param start integer Start of range, 1-based
---@param end_ integer End of range, 1-based
---@param with_video boolean Download with video
function download.tag_extmark(start, end_, with_video)
  if start > end_ then return end
  local lines = vim.fn.getline(start, end_) --[[@as string[] ]]

  for i, line in ipairs(lines) do
    if extract_url(line) then
      vim.api.nvim_buf_set_extmark(
        0,
        helpers.download_namespace,
        start + i - 1 - 1,
        0,
        {
          virt_text = with_video and {{"", ""}} or nil,
          sign_text = "D",
          sign_hl_group = "MpvDownloadSign",
        }
      )
    end
  end
end


-- Callback which is run after yt-dlp finishes downloading.
-- If successful, attempts to paste the filename over the line in the buffer.
-- Finally, deletes the extmark and continues downloading.
--
---@param buffer integer
---@param last_extmark integer
---@param ytdl_file YtdlFile?
local function extmark_callback(buffer, last_extmark, ytdl_file)
  local target_extmark = vim.api.nvim_buf_get_extmark_by_id(
    buffer,
    helpers.download_namespace,
    last_extmark,
    {}
  )

  if target_extmark[1] and ytdl_file then
    -- Markdownable content
    if vim.list_contains(config.markdown_writable, vim.bo.filetype) then
      vim.fn.setbufline(
        buffer,
        target_extmark[1] + 1,
        helpers.markdownify(ytdl_file.title, ytdl_file.filename)
      )
    else
      vim.fn.setbufline(
        buffer,
        target_extmark[1] + 1,
        ytdl_file.filename
      )
    end

    helpers.try_write_buffer(buffer)
  end

  vim.api.nvim_buf_del_extmark(
    0,
    helpers.download_namespace,
    last_extmark
  )

  vim.defer_fn(function() download_next_extmark(buffer) end, 0)
end


---Asynchronous handler which finds the next line with a download extmark and
---attempts to feed it to yt-dlp.
---On completion, it should re-schedule itself until there are no remaining lines.
---
---@param buffer integer
function download_next_extmark(buffer)
  local downloadables = vim.api.nvim_buf_get_extmarks(
    buffer,
    helpers.download_namespace,
    0,
    -1,
    { details = true }
  )

  if #downloadables == 0 then
    vim.b[buffer].mpv_downloader_running = false
    return
  end

  -- Get the line from the buffer and de-markdown it
  local line = vim.fn.getbufoneline(buffer, downloadables[1][2] + 1)
  local with_video = downloadables[1][4].virt_text ~= nil
  local markdown = extract_url(line)
  if not markdown then
    vim.notify(("'%s' is not a valid url. Skipping..."):format(line), vim.log.levels.INFO)
    vim.api.nvim_buf_del_extmark(
      buffer,
      helpers.download_namespace,
      downloadables[1][1]
    )
    vim.defer_fn(download.download_next_extmark, 0)
    return
  end

  download_url(
    markdown.url,
    with_video,
    function(ytdl_file) extmark_callback(buffer, downloadables[1][1], ytdl_file) end
  )
end

---Start the downloader on the specified buffer.
---If no buffer is given, starts it on the current one.
---Lines must be tagged with download extmarks using download.tag_extmark beforehand.
---
---@param buffer integer?
function download.start_downloader(buffer)
  if vim.b[buffer or 0].mpv_downloader_running then return end

  local current_buffer = vim.api.nvim_get_current_buf()
  buffer = buffer == 0 and current_buffer or buffer

  vim.api.nvim_buf_call(buffer or current_buffer, function()
    bind_forward_deletions()
  end)

  download_next_extmark(buffer or current_buffer)
end

return download
