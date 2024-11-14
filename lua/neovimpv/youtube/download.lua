local config = require "neovimpv.config"

---@class NvimSystemCompleted
---@field code integer
---@field signal integer
---@field stdout string?
---@field stderr string?

---@class YtdlFile
---@field title string
---@field filename string
---@field original_url string

-- Renames and mutates a list of paths and titles from youtube-dl.
-- Filenames containing the characters "()" are replaced with "[]"
-- Titles containing the characters "[]" are replaced with "()"
-- This renders the files able to be presented in markdown format.
--
---@param files YtdlFile[]
local function rename_brackets(files)
  for _, file in ipairs(files) do
    local new_filename = file.filename:gsub("%(", "["):gsub("%)", "]")

    vim.fn.rename(
      file.filename,
      new_filename
    )
    file.filename = new_filename
    file.title = file.title:gsub("%[", "("):gsub("%]", ")")
  end
end

---@param obj NvimSystemCompleted
---@param callback? fun(filenames: YtdlFile[])
local function youtube_dl_callback(obj, callback)
  -- Log errors from stderr
  if obj.stderr ~= "" then
    vim.defer_fn(function()
      vim.notify(obj.stderr, vim.log.levels.ERROR)
    end, 0)
    return
  end

  local files = {}
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
        table.insert(files, current_file)
        current_file = {}
      end
      echo_flag = false
    end
    if line:find("^%[Exec%]") then
      echo_flag = true
    end
  end

  if callback then
    vim.defer_fn(function()
      rename_brackets(files)
      callback(files)
    end, 0)
  end
end


---@param urls string[]
---@param with_video boolean
---@param callback? fun(filenames: YtdlFile[])
local function download(urls, with_video, callback)
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
  vim.list_extend(youtube_dl_args, urls)

  vim.system(
    youtube_dl_args,
    {
      cwd = vim.fn.fnamemodify(cwd, vim.fn.isdirectory(cwd) == 1 and ":p" or ":p:h"),
      -- TODO: stdout handler which updates progress
    },
    function(obj) youtube_dl_callback(obj, callback) end
  )
end

return download
