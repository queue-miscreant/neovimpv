-- neovimpv.youtube.interact
--
-- Buffer interaction for YouTube results.
-- Provides functionality for selecting results, showing extra data, and yanking links.

local consts = require "neovimpv.consts"
local config = require "neovimpv.config"
local keys = require "neovimpv.keys"

local download = require "neovimpv.youtube.download"

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

---@param file {link: string, markdown: string}
---@param extra string
---@param keep_results_open? boolean
local function paste_and_play(file, extra, keep_results_open)
  local window = vim.b.mpv_calling_window
  local result_window = vim.api.nvim_get_current_win()
  -- Close the youtube buffer and return the calling window
  if keep_results_open then
    vim.cmd[[quit!]]
    vim.fn.win_gotoid(window)
  else
    vim.fn.win_gotoid(result_window)
  end

  if not vim.bo.modifiable then
    vim.notify("Buffer is not modifiable. Cannot paste result.", vim.log.levels.ERROR)
    return
  end

  local insert_link = file.link

  -- Markdownable content
  if vim.list_contains(config.markdown_writable, vim.bo.filetype) then
    insert_link = file.markdown
  end

  if try_insert(insert_link) then
    vim.cmd[[normal j]]
  end
  vim.cmd(":MpvOpen " .. extra)
end

-- Callback for youtube results buffers. Return to the calling window,
-- paste the link where the cursor is, then call MpvOpen.
-- Writes markdown if the buffer's filetype supports markdown.
local function open_result(extra)
  local current = vim.b.mpv_selection[vim.fn.line(".")]

  paste_and_play(current, extra)
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
  -- vim.print(current)
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

local function add_keybinds()
  -- Keybinds
  local specs = {
    {
      "<cr>",
      function() open_result("") end,
      desc = "Open result",
    },
    {
      "p",
      function() open_result("paste --") end,
      desc = "Paste result (do not play)",
    },
    {
      "p",
      function() open_result("paste --") end,
      desc = "Open result (paste playlist in-place)",
    },
    {
      "P",
      function() open_result("paste -- --video=auto") end,
      desc = "Open result (video, paste playlist in-place)",
    },
    {
      "n",
      function() open_result("new --") end,
      desc = "Open result (in new split)",
    },
    {
      "N",
      function() open_result("new -- --video=auto") end,
      desc = "Open result (video, in new split)",
    },
    {
      "i",
      open_result_thumbnail,
      desc = "View thumbnail",
    },
    {
      "d",
      function()
        local current = vim.b.mpv_selection[vim.fn.line(".")]
        download(current.link, false, function(filenames)
          if #filenames > 1 then
            vim.notify("Detected multiple output filenames. Only the first will be pasted.", vim.log.levels.WARN)
          end

          paste_and_play({
            link = filenames[1].filename,
            markdown = filenames[1].filename:find("%(") and filenames[1].filename or ("[%s](%s)"):format(filenames[1].title:gsub("[%[%]]", ""), filenames[1].filename)
          }, "", true)
        end)
      end,
      desc = "Download video",
    },
  }
  for _, video_binding in pairs{"<s-enter>", "v"} do
    table.insert(specs, {
      video_binding,
      function() open_result("--video=auto") end,
      desc = "Open result (video)",
    })
  end

  -- More informative names through which-key
  local success, which_key = pcall(require, "which-key")
  if success then
    which_key.add({
      specs,
      silent = true,
      buffer = 0,
    })
    return
  end

  -- Backup bindings
  local vks = vim.keymap.set
  for _, spec in ipairs(specs) do
    vks(
      spec.mode or "n",
      spec[1],
      spec[2],
      {
        silent=true,
        buffer=0,
      }
    )
  end
end

-- Replace yank contents with URL
local function yank_youtube_link()
  local event = vim.v.event
  if not ( (event.regcontents[1] or ""):len() ~= 0 and event.operator == "y" ) then
    return
  end

  local current = vim.b.mpv_selection[vim.fn.line(".")]
  vim.notify("Yanked '" .. current.link .. "'")
  vim.fn.setreg(event.regname, current.link)
  -- Don't forget the system clipboard!
  if vim.o.clipboard == "unnamed" then
    vim.fn.setreg("*", current.link)
  elseif vim.o.clipboard == "unnamedplus" then
    vim.fn.setreg("+", current.link)
  end
end

function interact.bind_buffer_results()
  -- Close buffer on q
  vim.keymap.set("n", "q", ":q<cr>", {silent = true, buffer = 0})

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

  add_keybinds()

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

  prev_line = -1
  set_youtube_extmark()
end

function interact.bind_buffer_playlist()
  vim.wo.wrap = false
  vim.bo.bufhidden = true

  keys.bind_smart_local()
end

return interact
