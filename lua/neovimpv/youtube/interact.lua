-- neovimpv.youtube.interact
--
-- Buffer interaction for YouTube results.
-- Provides functionality for selecting results, showing extra data, and yanking links.

local helpers = require "neovimpv.helpers"
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


-- Callback wrapper for youtube results buffers.
-- Return to the calling window and perform the action.
--
---@keep_results_open boolean
---@param callback fun(content: PasteContent|PasteContent[], ...)
local function do_result(keep_results_open, callback, ...)
  local current = vim.b.mpv_selection[vim.fn.line(".")]
  -- Get multiple entries if in visual mode
  if vim.fn.mode():sub(1,1):lower() == "v" then
    current = vim.list_slice(
      vim.b.mpv_selection,
      math.min(vim.fn.line("v"), vim.fn.line(".")),
      math.max(vim.fn.line("v"), vim.fn.line("."))
    )
  end

  local window = vim.b.mpv_calling_window
  local result_window = vim.api.nvim_get_current_win()
  -- Close the youtube buffer and return the calling window
  if not keep_results_open then
    vim.cmd[[quit!]]
  end
  vim.fn.win_gotoid(window)

  callback(current, ...)

  if keep_results_open then
    vim.fn.win_gotoid(result_window)
  end
end

-- Callback for youtube results buffers.
-- Opens the thumbnail of result under the cursor in the system viewer.
local function open_result_thumbnail()
  local current = vim.b.mpv_selection[vim.fn.line(".")]
  if not current.thumbnail then return end

  -- TODO
  vim.fn.system(
    'read -r url; '
    .. 'temp=`mktemp`; '
    .. 'curl -L "$url" > "$temp" 2>/dev/null; '
    .. 'xdg-open "$temp"',
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
      helpers.display_namespace,
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
      helpers.display_namespace,
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
      function()
        do_result(false, helpers.paste_and_play, "")
      end,
      desc = "Open result",
      mode = {"n", "v"},
    },
    {
      "p",
      function()
        do_result(false, helpers.paste_and_play, "paste --")
      end,
      desc = "Open result (paste playlist in-place)",
    },
    {
      "P",
      function()
        do_result(false, helpers.paste_and_play, "paste -- --video=auto")
      end,
      desc = "Open result (video, paste playlist in-place)",
    },
    {
      "n",
      function()
        do_result(false, helpers.paste_and_play, "new --")
      end,
      desc = "Open result (in new split)",
    },
    {
      "N",
      function()
        do_result(false, helpers.paste_and_play, "new -- --video=auto")
      end,
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
        local window = vim.b.mpv_calling_window
        do_result(false, function(current)
          -- Normalize to singleton
          if #current == 0 then current = {current} end
          local links = vim.tbl_map(function(x) return x.link end, current)
          -- Grab these before we download
          local cursor_line = vim.fn.line(".", window)

          -- TODO: paste lines in buffer and call tracker.tag_extmark
          --
          -- download(links, false, function(filenames)
          --   ---@type PasteContent[]
          --   local as_pastable = vim.tbl_map(function(x)
          --     return {
          --       link = x.filename,
          --       markdown = helpers.markdownify(x.title, x.filename),
          --     } --[[@as PasteContent]]
          --   end, filenames)
          --   helpers.paste_and_play(as_pastable, "", window, cursor_line)
          -- end)
        end)
      end,
      desc = "Download (audio only)",
    },
  }
  for _, video_binding in pairs{"<s-enter>", "v"} do
    table.insert(specs, {
      video_binding,
      function()
        do_result(false, helpers.paste_and_play, "--video=auto")
      end,
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
    -- Note that ERROR causes garbage related to the autocmd to be printed
    -- And since this is running "close" to Python, even more garbage from its async handler gets added
    vim.notify(
      "No data found when opening YouTube results buffer! Closing window...",
      vim.log.levels.WARN
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
