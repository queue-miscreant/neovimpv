-- neovimpv.youtube.interact
--
-- Buffer interaction for YouTube results.
-- Provides functionality for selecting results, showing extra data, and yanking links.

local consts = require "neovimpv.consts"
local config = require "neovimpv.config"

local interact = {}

---@diagnostic disable-next-line
---@cast vim.b.mpv_selection YTSearchResult[]?

--   ____      _ _ _                _
--  / ___|__ _| | | |__   __ _  ___| | _____
-- | |   / _` | | | '_ \ / _` |/ __| |/ / __|
-- | |__| (_| | | | |_) | (_| | (__|   <\__ \
--  \____\__,_|_|_|_.__/ \__,_|\___|_|\_\___/
--

-- Insert `value` at the line of the current cursor, if it's empty.
-- Otherwise, insert it a line below the current line.
local function try_insert(value)
  local row = vim.fn.line(".")
  local append_line = vim.fn.getline(row):len() ~= 0

  local targetrow = row
  if append_line then
    vim.fn.append(targetrow, value)
  else
    vim.fn.setline(targetrow, value)
  end

  return append_line
end

-- Callback for youtube results buffers. Return to the calling window,
-- paste the link where the cursor is, then call MpvOpen.
-- Writes markdown if the buffer's filetype supports markdown.
local function open_result(extra)
  local current = vim.b.mpv_selection[vim.fn.line(".")]
  local window = vim.b.mpv_calling_window
  -- Close the youtube buffer and return the calling window
  vim.cmd[[quit!]]
  vim.fn.win_gotoid(window)

  if not vim.bo.modifiable then
    vim.notify("Buffer is not modifiable. Cannot paste result.", vim.log.levels.ERROR)
    return
  end

  local insert_link = current.link

  -- Markdownable content
  if vim.list_contains(config.markdown_writable, vim.bo.filetype) then
    insert_link = current.markdown
  end

  if try_insert(insert_link) then
    vim.cmd[[normal j]]
  end
  vim.cmd(":MpvOpen " .. extra)
end

-- Callback for youtube results buffers.
-- Opens the thumbnail of result under the cursor in the system viewer.
local function open_result_thumbnail()
  local current = vim.b.mpv_selection[vim.fn.line(".")]
  if not current.thumbnail then return end

  -- TODO
  vim.fn.system(
    'read -r url; ' ..
    'temp=`mktemp`; ' ..
    'curl -L "$url" > "$temp" 2>/dev/null; ' ..
    'xdg-open "$temp"',
    current.thumbnail
  )
end

-- Additional video data as extmarks
---@type integer
local prev_line = -1
local function set_youtube_extmark()
  if prev_line == vim.fn.line(".") then
    return
  end
  prev_line = vim.fn.line(".")

  local current = vim.b.mpv_selection[prev_line]
  if current.video_id then
    ---@cast current YTVideo
    vim.api.nvim_buf_set_extmark(
      0,
      consts.display_namespace,
      vim.fn.line(".") - 1,
      0,
      {
        id = 1,
        virt_text = {{current["length"], "MpvYoutubeLength"}},
        virt_text_pos = "eol",
        virt_lines = {
          {{current["channel_name"], "MpvYoutubeChannelName"}},
          {{current["views"], "MpvYoutubeViews"}},
        },
      }
    )
  elseif current.playlist_id then
    ---@cast current YTPlaylist
    ---@type VirtText[]
    local video_extmarks = {{{current.channel_name, "MpvYoutubeChannelName"}}}
    for _, video in ipairs(current.videos) do
      table.insert(
        video_extmarks,
        {
          {"  ", "MpvDefault"},
          {video.title, "MpvYoutubePlaylistVideo"},
          {" ", "MpvDefault"},
          {video.length, "MpvYoutubeLength"}
        }
      )
    end
    vim.api.nvim_buf_set_extmark(
      0,
      consts.display_namespace,
      vim.fn.line(".") - 1,
      0,
      {
        id = 1,
        virt_text = {{current.video_count .. " videos", "MpvYoutubeVideoCount"}},
        virt_text_pos = "eol",
        virt_lines = video_extmarks,
      }
    )
  end
end

-- Replace yank contents with URL
local function yank_youtube_link()
  local event = vim.v.event
  if not ( event.regcontents:len() == 1 and event.operator == "y" ) then
    return
  end

  local current = vim.b.mpv_selection[vim.fn.line(".")]
  vim.fn.setreg(event.regname, current.link)
end

function interact.bind_to_buffer()
  local vks = vim.keymap.set
  -- Close buffer on q
  vks("n", "q", ":q<cr>", {silent = true, buffer = true})

  -- Local options
  vim.wo.number = false
  vim.wo.wrap = false
  vim.wo.cursorline = true
  vim.bo.bufhidden = "wipe"

  -- check that we have callbacks
  if
    vim.b.mpv_selection == nil
    or #vim.b.mpv_selection == 0
    or vim.b.mpv_calling_window == nil
  then
    vim.notify(
      "No data found when opening YouTube results buffer! Closing window...",
      vim.log.levels.ERROR
    )
    vim.cmd[[quit!]]
    return
  end

  -- Keybinds
  vks(
    "n",
    "<cr>",
    function() open_result("") end,
    {silent = true, buffer = true}
  )
  for _, video_binding in pairs{"<s-enter>", "v"} do
    vks(
      "n",
      video_binding,
      function() open_result("--video=auto") end,
      {silent = true, buffer = true}
    )
  end
  vks(
    "n",
    "p",
    function() open_result("paste --") end,
    {silent = true, buffer = true}
  )
  vks(
    "n",
    "P",
    function() open_result("paste -- --video=auto") end,
    {silent = true, buffer = true}
  )
  vks(
    "n",
    "n",
    function() open_result("new --") end,
    {silent = true, buffer = true}
  )
  vks(
    "n",
    "N",
    function() open_result("new -- --video=auto") end,
    {silent = true, buffer = true}
  )
  vks("n", "i", open_result_thumbnail, {silent = true, buffer = true})

  vim.api.nvim_create_autocmd(
    "CursorMoved",
    {
      buffer = 0,
      callback = set_youtube_extmark,
    }
  )
  vim.api.nvim_create_autocmd(
    "TextYankPost",
    {
      buffer = 0,
      callback = yank_youtube_link,
    }
  )
end

return interact
