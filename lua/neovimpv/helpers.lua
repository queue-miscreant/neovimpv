-- helpers.lua
-- Miscellaneous (mostly pure) helper functions

local config = require "neovimpv.config"
local log = require "neovimpv.log"

local expand = vim.fn.expand
local filereadable = vim.fn.filereadable
local list_contains = vim.list_contains

local LINK_RE = "()(https?://.-%.[^`%s]+)()"

---@alias VisualMode "visual" | "vline" | "vblock" | "ignore" | nil
---@alias LineNumber integer

---@class MpvLocalArgs
---@field mpv_args string[]
---@field visual VisualMode
---@field update_action? UpdateAction

-- Convert a title and URL pair to a markdown string
---@param title string
---@param url string
---@return string
local function markdownify(title, url)
  return url:find("%(") and url or ("[%s](%s)"):format(title:gsub("[%[%]]", ""), url)
end

-- Extract the title and URL pair from a markdown string
---@param markdown string
---@return string?, string?
local function unmarkdownify(markdown)
  local title, url = markdown:match("^(%b[])(%b())$")
  if not title then return nil end
  -- trim the first and last characters (non-Dijkstra)
  return title:sub(2, -2), url:sub(2, -2)
end

---Attempt to interpret the line as an (absolute) file path or as markdown.
---Paths are `expand()`ed before checking if the file exists.
---If the line is not a valid filename or the markdown match fails, return nil.
---@param line string
---@return string?
local function try_path_and_markdown(line)
  local file_link = expand(line)
  if file_link:find("/") == 1 and filereadable(file_link) == 1 then
    return file_link
  end

  local _, maybe_file = unmarkdownify(line)
  return maybe_file
end

---Attempt to generate a "smart Youtube" playlist update action.
---This pastes the first result of "ytsearch://" URLs over the original contents of the line.
---Otherwise, results are opened in a new buffer inside a split.
---@param filename string
---@return UpdateAction
local function try_smart_youtube(filename)
  local is_search = filename:match("^ytdl://%s*ytsearch(%d*):")
  if is_search == "" or is_search == "1" then
    return "paste"
  end
  return "new_one"
end

---Find the closest LINK_RE match in `line` to the position `column`.
---Returns a 2-tuple of the matching link and whether or not the link was found
---at the start of its line and was the only match.
---@param line string
---@param column integer
---@return string?, boolean
local function find_closest_link(line, column)
  ---@type [integer, string, integer]?
  local last
  ---@type [integer, string, integer]?
  local current
  local count = 0
  for start, path, end_ in line:gmatch(LINK_RE) do
    ---@diagnostic disable-next-line
    current = { start, path, end_ }
    count = count + 1
    if column < start then
      break
    end
    last = current
  end

  -- Equivalently, `count == 0`
  if current == nil then
    return nil, true
  end

  -- Only one result, whether or not we hit the `break`
  if last == nil or current == last then
    return current[2], current[1] == 1
  end

  local dist_from_last = column - last[3]
  local dist_to_next = column - current[1]
  if math.abs(dist_from_last) > math.abs(dist_to_next) then
    return current[2], false
  end

  return last[2], false
end

---Filter off URLs between start_col and end_col.
---If `end_col` is `nil`, then no upper bound for the column will be used.
---Returns a list of filenames and a boolean indicating whether to apply markdown to the line.
---@param line string
---@param start_col integer
---@param end_col? integer
---@return string[], boolean
local function links_by_line(line, start_col, end_col)
  local ret = {}
  local match_count = 0
  local first_start
  for start, path, end_ in line:gmatch(LINK_RE) do
    if first_start == nil then first_start = start end
    if end_ >= start_col and (not end_col or start <= end_col) then
      table.insert(ret, path)
    end
    match_count = match_count + 1
  end
  return ret, (match_count == 1 and first_start == 1)
end


---Construct a dictionary from line numbers to a tuple of a list of files
---and whether or not this is the only openable item on its line
---(in other words, whether overwriting it with markdown is acceptable).
---@param lines string[]
---@param start_line integer
---@param start_col integer
---@param end_line integer
---@param end_col integer?
---@param mode VisualMode?
---@return table<LineNumber, [string[], boolean]>
local function multi_line(lines, start_line, start_col, end_line, end_col, mode)
  ---@type table<LineNumber, [string[], boolean]>
  local ret = {}

  for offset, line in ipairs(lines) do
    local line_number = offset + start_line - 1
    if line_number == end_line then
      break
    end

    local path = try_path_and_markdown(line)
    if path then
      ret[line_number] = { {path}, true }
      goto continue
    end

    ---@type string[]
    local links = {}
    local markdownable = false

    if mode == "visual" then  -- visual range
      if start_line == end_line then
        links, markdownable = links_by_line(line, start_col, end_col)
      elseif line_number == start_line then
        links, markdownable = links_by_line(line, start_col, nil)
      elseif line_number == end_line then
        links, markdownable = links_by_line(line, 0, end_col)
      end
    elseif mode == "vblock" then
      links, markdownable = links_by_line(line, start_col, end_col)
    else
      links, markdownable = links_by_line(line, 0, nil)
    end

    if links[1]:len() ~= 0 then
      ret[line_number] = { links, markdownable }
    end
    ::continue::
  end

  return ret
end

---Parse arguments `args` retrieved from MpvOpen.
---Arguments preceding "--", if they exist, are considered local, and
---control local functionality, like determining if dynamic playlists
---should use non-global options.
---@param args string[]
---@return MpvLocalArgs
local function parse_mpvopen_args(args)
  local mpv_args = {}
  local local_args = {}

  ---@type UpdateAction?
  local update_action = nil
  ---@type VisualMode
  local visual = nil

  local local_flag = true
  local video_flag = false
  for _, arg in ipairs(args) do
    if arg == "--" then
      local_flag = false
    elseif local_flag then
      -- Update actions
      if arg == "stay" then
        update_action = "stay"
      elseif arg == "paste" then
        update_action = "paste"
      elseif arg == "new" then
        update_action = "new_one"
      end
      -- Visual modes
      if list_contains({"visual", "vline", "vblock"}, arg) then
        visual = arg
      end

      if arg == "video" then
        video_flag = true
      end

      table.insert(local_args, arg)
    else
      table.insert(mpv_args, arg)
    end
  end

  if video_flag then
    local i = 1
    while i <= #mpv_args do
      local arg = mpv_args[i]
      if arg:find("^--vid") or arg == "--no-video" then
        table.remove(mpv_args, i)
      else
        i = i + 1
      end
    end
    table.insert(mpv_args, "--video=auto")
  end

  return {
    mpv_args = mpv_args,
    update_action = update_action,
    visual = visual,
  }
end

--  ___
-- |_ _|_ __  _ __ _  _ _ _ ___
--  | || '  \| '_ \ || | '_/ -_)
-- |___|_|_|_| .__/\_,_|_| \___|
--           |_|
-- Impure

-- Try writing the buffer, if the `save_on_modify` configuration is enabled
---@param buffer_id integer
local function try_write_buffer(buffer_id)
  if config.save_on_modify and not (vim.bo[buffer_id].readonly or not vim.bo[buffer_id].modifiable) then
    vim.api.nvim_buf_call(buffer_id, function() vim.cmd("w") end)
  end
end

---Read over the list of lines, skipping those which are not files or URLs.
---Make note of which need to be turned into markdown.
---@param lines string[]
---@param start_line integer
---@param end_line integer
---@param mode VisualMode
---@return table<LineNumber, [string[], boolean]>
local function construct_playlist_items(lines, start_line, end_line, mode)
  if mode == "visual" or mode == "vblock" then
    -- Block or visual block modes
    -- TODO: note that we disassemble `getpos` tables here instead of using them directly
    local _, new_start_line, start_col = unpack(vim.fn.getpos("<"))
    local _, new_end_line, end_col = unpack(vim.fn.getpos(">"))
    log.log{
      "Creating playlist from visual selection",
      lines = lines,
      start = {new_start_line, start_col},
      ["end"] = {new_end_line, end_col},
      mode = mode,
    }
    return multi_line(lines, new_start_line, start_col, new_end_line, end_col, mode)
  end

  log.log{
    "Not in visual or visual block mode.",
    mode = mode,
  }
  if mode ~= "ignore" and mode ~= "vline" then
    if start_line == end_line then
      local _, new_start_line, start_col = unpack(vim.fn.getpos("."))
      -- If somehow we were given a range without the cursor actually being there,
      -- assume the start of the line
      if start_line == new_start_line then
        log.log{"Trying path/markdown"}
        local single_file = try_path_and_markdown(lines[1])
        if single_file ~= nil then
          return {
            [start_line] = { {single_file}, true }
          }
        end
        log.log{
          "Finding closest link",
          line = lines[1],
          start_col = start_col,
        }
        local closest_link, only_link_on_line = find_closest_link(lines[1], start_col)
        if closest_link ~= nil then
          return {
            [start_line] = {{closest_link}, only_link_on_line}
          }
        end
        log.log{"No results found from default action"}
        return {}
      end
    end
  end

  log.log{
    "Creating playlist as default",
    lines = lines,
    start = start_line,
    ["end"] = end_line,
  }
  return multi_line(lines, start_line, 0, end_line, nil, nil)
end

return {
  display_namespace = vim.api.nvim_create_namespace("Neovimpv-displays"),
  playlist_namespace = vim.api.nvim_create_namespace("Neovimpv-playlists"),
  download_namespace = vim.api.nvim_create_namespace("Neovimpv-downloads"),

  -- Pure
  markdownify = markdownify,
  unmarkdownify = unmarkdownify,
  try_path_and_markdown = try_path_and_markdown,
  try_smart_youtube = try_smart_youtube,
  find_closest_link = find_closest_link,
  links_by_line = links_by_line,
  multi_line = multi_line,
  parse_mpvopen_args = parse_mpvopen_args,

  -- Impure
  try_write_buffer = try_write_buffer,
  construct_playlist_items = construct_playlist_items,
}
