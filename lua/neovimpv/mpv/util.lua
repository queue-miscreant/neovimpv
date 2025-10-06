-- mpv/util.lua
-- Utility functions for spawning mpv.

local config = require("neovimpv.config")
local log = require("neovimpv.mpv.log")
local MpvPlaylist = require("neovimpv.mpv.playlist")
local MpvManager = require("neovimpv.mpv.manager")

local expand = vim.fn.expand
local filereadable = vim.fn.filereadable
local list_contains = vim.tbl_contains
local tbl_count = vim.tbl_count
local tbl_keys = vim.tbl_keys

local MARKDOWN_LINK_RE = "(%b[])(%b())"
local YTDL_YOUTUBE_SEARCH_RE = "^ytdl://%s*ytsearch(%d*):"
local LINK_RE = "()(https?://.-%.[^`%s]+)()"

local VISUAL_RANGE = "visual"
local VISUAL_LINE = "vline"
local VISUAL_BLOCK = "vblock"
local IGNORE = "ignore"

---@alias VisualMode "visual" | "vline" | "vblock" | "ignore" | nil
---@alias LineNumber string

---@class MpvLocalArgs
---@field mpv_args string[]
---@field visual VisualMode
---@field update_action? UpdateAction

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

  local _, try_markdown = line:match(MARKDOWN_LINK_RE)
  if try_markdown then
    return try_markdown:sub(2, -2)
  end

  return nil
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
  ---@type table<string, [string[], boolean]>
  local ret = {}
  for offset, line in ipairs(lines) do
    local line_number = offset + start_line - 1
    if line_number == end_line then
      break
    end

    local path = try_path_and_markdown(line)
    if path then
      ret[tostring(line_number)] = { {path}, true }
      goto continue
    end

    ---@type string[]
    local links = {}
    local markdownable = false

    if mode == VISUAL_RANGE then
      if start_line == end_line then
        links, markdownable = links_by_line(line, start_col, end_col)
      elseif line_number == start_line then
        links, markdownable = links_by_line(line, start_col, nil)
      elseif line_number == end_line then
        links, markdownable = links_by_line(line, 0, end_col)
      end
    elseif mode == VISUAL_BLOCK then
      links, markdownable = links_by_line(line, start_col, end_col)
    else
      links, markdownable = links_by_line(line, 0, nil)
    end

    if links[1]:len() ~= 0 then
      ret[tostring(line_number)] = { links, markdownable }
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

  local local_flag = false
  local video_flag = false
  for arg in ipairs(args) do
    if arg == "--" then
      local_flag = true
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
      if arg == "visual" then
        visual = VISUAL_RANGE
      elseif arg == "vblock" then
        visual = VISUAL_BLOCK
      elseif arg == "vline" then
        visual = VISUAL_LINE
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


---Read over the list of lines, skipping those which are not files or URLs.
---Make note of which need to be turned into markdown.
---TODO `getpos` unpacking is slightly ugly
---@param lines string[]
---@param start_line integer
---@param end_line integer
---@param mode VisualMode
---@return table<LineNumber, [string[], boolean]>
local function construct_playlist_items(lines, start_line, end_line, mode)
  if mode == VISUAL_BLOCK or mode == VISUAL_RANGE then
    log.info("Attempting action based on vim mode")
    -- Block or visual block modes
    local _, new_start_line, start_col = unpack(vim.fn.getpos("<"))
    local _, new_end_line, end_col = unpack(vim.fn.getpos(">"))
    log.info("Creating playlist from visual selection")
    log.debug(
      "lines: %s\nstart: %s\nend: %s\nmode: %s",
      lines,
      {new_start_line, start_col},
      {new_end_line, end_col},
      mode
    )
    -- TODO: note that we assemble tables here and destruct them immediately afterward
    return multi_line(lines, new_start_line, start_col, new_end_line, end_col, mode)
  end

  log.info("Not in visual or visual block mode. Mode: %s", mode)
  if mode ~= IGNORE and mode ~= VISUAL_LINE then
    if start_line == end_line then
      local _, new_start_line, start_col = unpack(vim.fn.getpos("."))
      -- If somehow we were given a range without the cursor actually being there,
      -- assume the start of the line
      if start_line == new_start_line then
        log.info("Trying path/markdown")
        local single_file = try_path_and_markdown(lines[1])
        if single_file ~= nil then
          return {
            [tostring(start_line)] = { {single_file}, true }
          }
        end
        log.info("Finding closest link")
        log.debug("line: %s\nstart_col: %s", lines[0], start_col)
        local closest_link, only_link_on_line = find_closest_link(lines[0], start_col)
        if closest_link ~= nil then
          return {
            [tostring(start_line)] = {{closest_link}, only_link_on_line}
          }
        end
        log.info("No results found from default action")
        return {}
      end
    end
  end

  log.info("Creating playlist as default")
  log.debug(
      "lines: %s\nstart: %s\nend: %s",
      lines,
      start_line,
      end_line
  )
  return multi_line(lines, start_line, 0, end_line, nil, nil)
end


---Convert the playlist from `construct_playlist_items` to a `playlist_id_to_extmark_id`
---value for MpvPlaylist. This is a dict of tuples from playlist indices (starting with 1)
---to extmark indices.
---@param preliminary_playlist table<LineNumber, [string[], boolean]>
---@param lines_ids_zip [LineNumber, ExtmarkId][]
---@param acknowledge_markdowns boolean
---@return table<string, MpvItem>
local function construct_mpv_item_map(preliminary_playlist, lines_ids_zip, acknowledge_markdowns)
  local file_index = 1
  local playlist_id_to_item = {}
  for _, item in ipairs(lines_ids_zip) do
    local line, extmark_id = unpack(item)
    local files, rewritable_line = unpack(preliminary_playlist[line])
    for _, file in ipairs(files or {}) do
      playlist_id_to_item[tostring(file_index)] = {
          filename = file,
          extmark_id = extmark_id,
          update_markdown = rewritable_line and acknowledge_markdowns,
          show_currently_playing = not rewritable_line,
      } --[[@as MpvItem]]
      file_index = file_index + 1
    end
  end

  return playlist_id_to_item
end


---Attempt to generate a "smart Youtube" playlist update action.
---This pastes the first result of "ytsearch://" URLs over the original contents of the line.
---Otherwise, results are opened in a new buffer inside a split.
---@param filename string
---@return UpdateAction
local function try_smart_youtube(filename)
  local is_search = filename:match(YTDL_YOUTUBE_SEARCH_RE)
  if is_search == "" or is_search == "1" then
    return "paste"
  end
  return "new_one"
end


-- Create a MpvManager instance from line data and ranges from the nvim plugin.
-- This also spawns a task for creating an mpv subprocess and opening a communication channel.
--
-- The plugin MUST be in a state where its `current` data is accessible, for example, when
-- using async_call or in a command callback.
---@param line_data string[]
---@param start_line integer
---@param end_line integer
---@param extra_args string[]
---@param ignore_mode boolean
local function create_managed_mpv(
    line_data,
    start_line,
    end_line,
    extra_args,
    ignore_mode
)
  local current_buffer = vim.fn.bufnr()
  local current_filetype = vim.bo.filetype

  local local_args = parse_mpvopen_args(extra_args)

  local preliminary_playlist = construct_playlist_items(
      line_data,
      start_line,
      end_line,
      ignore_mode and IGNORE or local_args.visual
  )
  log.debug(preliminary_playlist)
  if tbl_count(preliminary_playlist) == 0 then
    vim.notify(
      (start_line == end_line and "Line does" or "Lines do") .. " not contain a file path or valid URL",
      vim.log.levels.ERROR,
      {}
    )
    return nil
  end

  local playlist_lines = tbl_keys(preliminary_playlist)
  table.sort(playlist_lines)

  -- TODO
  local success, err = pcall(function()
    -- TODO
    return vim._neovimpv_callbacks.create_player(
      current_buffer,
      playlist_lines  -- only the line number, not the file name
    )
  end)

  if not success then
    vim.notify(
      "Could not create playlist in nvim!",
      vim.log.levels.ERROR,
      {}
    )
    log.debug("%s", err)
    return nil
  end

  ---@diagnostic disable-next-line
  local player_id, playlist_extmark_ids = unpack(err)

  ---@type [string, ExtmarkId][]
  local zipped = {}
  for i = 1, #playlist_lines do
    table.insert(zipped, { playlist_lines[i], playlist_extmark_ids[i] })
  end

  local playlist = MpvPlaylist.new(
    construct_mpv_item_map(
      preliminary_playlist,
      zipped,
      list_contains(config.markdown_writable, current_filetype)
    )
  )

  -- Update actions and "smart youtube"-ness
  local update_action = config.on_playlist_update
  local playlist_length = tbl_count(playlist.playlist_id_to_item)
  if playlist_length == 1 then
    if config.smart_youtube then
      update_action = try_smart_youtube(playlist.playlist_id_to_item[1].filename)
    end
  elseif local_args.update_action == "new_one" then
    vim.notify(
      "Cannot create new buffer for playlist of initial size 1!",
      vim.log.levels.ERROR,
      {}
    )
    return
  end

  update_action = local_args.update_action or update_action

  return MpvManager.new(
      current_buffer,
      player_id,
      playlist,
      update_action,
      local_args.mpv_args
  ):spawn()
end

return {
  find_closest_link = find_closest_link,
  links_by_line = links_by_line,
  try_path_and_markdown = try_path_and_markdown,
  multi_line = multi_line,
  parse_mpvopen_args = parse_mpvopen_args,
  construct_playlist_items = construct_playlist_items,
  try_smart_youtube = try_smart_youtube,
  create_managed_mpv = create_managed_mpv,
}
