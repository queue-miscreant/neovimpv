-- neovimpv.keys
-- Keybinds and callbacks thereof. Keys include omnikey and navigation.

local config = require "neovimpv.config"
local helpers = require "neovimpv.helpers"
local download_tracker = require "neovimpv.youtube.extmarks"
local registry = require "neovimpv.mpv.registry"

local keys = {}

local function exit_mode()
  vim.defer_fn(function()
    vim.cmd[[exe "normal \<esc>"]]
  end, 0)
end

---@param extra_args string?
local function omnikey(extra_args)
  if extra_args == nil then extra_args = "" end

  local is_visual = vim.fn.mode():sub(1,1):lower() == "v"
  if is_visual then
    extra_args = "vline" .. (extra_args:find("%-%- ") and " " or " -- ") .. extra_args
  end

  local first_line, last_line = vim.fn.line("v"), vim.fn.line(".")
  local player, playlist_item = registry.get_player_by_line(0, first_line, last_line)

  if not player then
    -- no playlist on that line found, trying to open
    if config.omni_open_new_if_empty then
      vim.cmd((":%d,%dMpvOpen %s"):format(first_line, last_line, extra_args))
    end
  elseif not is_visual then
    ---@cast playlist_item integer
    if extra_args:find("--video=auto") then
      player:toggle_video()
      exit_mode()
      return
    end

    -- mpv found, get key to send
    local temp_ns = vim.api.nvim_create_namespace("")
    local new_extmark = vim.api.nvim_buf_set_extmark(
      0,
      temp_ns,
      vim.fn.line(".") - 1,
      0,
      {
        virt_text = {{"[ getting input... ]", "MpvDefault"}},
        virt_text_pos = "eol"
      }
    )
    vim.cmd[[redraw]]

    pcall(function()
      local temp = vim.fn.getcharstr()
      if temp == config.playlist_key then
        player:set_current_by_playlist_extmark(playlist_item)
      else
        player:send_keypress(temp, vim.v.count)
      end
    end)

    vim.api.nvim_buf_del_extmark(0, temp_ns, new_extmark)
  else
    vim.notify("Given range includes playlist! Ignoring...", vim.log.levels.ERROR)
  end

  exit_mode()
end

---@param direction -1 | 1
local function goto_relative_mpv(direction)
  local current = vim.fn.line(".") - 1
  local start = {current + 1, 0}
  local end_ = {-1, -1}

  if direction < 0 then
    start = {current - 1, -1}
    end_ = {0, 0}
  end

  local mpv_instances = vim.api.nvim_buf_get_extmarks(
    0,
    helpers.display_namespace,
    start,
    end_,
    {}
  )

  if #mpv_instances == 0 then
    if direction < 0 then
      vim.notify("No previous mpv found", vim.log.levels.ERROR)
    else
      vim.notify("No later mpv found", vim.log.levels.ERROR)
    end
    return
  end

  vim.cmd(("normal %dG"):format(mpv_instances[1][2] + 1))
end

---@param with_video? boolean
local function download_callback(with_video)
  local start = vim.fn.line(".") --[[@as integer]]
  ---@type integer
  local end_
  if vim.fn.mode():sub(1,1):lower() == "v" then
    local temp = math.min(vim.fn.line("v"), start)
    end_ = math.max(vim.fn.line("v"), start)
    start = temp
    exit_mode()
  else
    end_ = vim.fn.line(".")
  end

  download_tracker.tag_extmark(start, end_, with_video or false)
  download_tracker.start_downloader()
end

-- Open search prompt
---@param first_result boolean?
local function youtube_search_prompt(first_result)
  if not vim.bo.modifiable then
    vim.notify("Cannot search YouTube from non-modifiable buffer!", vim.log.levels.ERROR)
    return
  end

  ---@type boolean, string|nil
  local ok, query = pcall(function() return vim.fn.input("YouTube Search: ") end)

  if ok and (query or ""):len() ~= 0 then
    if first_result then
      vim.cmd("MpvYoutubeSearch! " .. query)
    else
      vim.cmd("MpvYoutubeSearch " .. query)
    end
  end
end

function keys.bind_base()
  local vks = vim.keymap.set

  vks({"n", "v"}, "<Plug>(mpv_omnikey)", function() omnikey() end)
  vks({"n", "v"}, "<Plug>(mpv_omnikey_video)", function() omnikey("-- --video=auto") end)

  vks("n", "<Plug>(mpv_goto_earlier)", function() goto_relative_mpv(-1) end)
  vks("n", "<Plug>(mpv_goto_later)", function() goto_relative_mpv(1) end)
  vks("n", "<Plug>(mpv_youtube_prompt)", youtube_search_prompt)
  vks("n", "<Plug>(mpv_youtube_prompt_lucky)", function() youtube_search_prompt(true) end)

  vks({"n", "v"}, "<Plug>(mpv_download_range)", function() download_callback() end)
  vks({"n", "v"}, "<Plug>(mpv_download_range_video)", function() download_callback(true) end)
end

function keys.bind_smart_local()
  local specs = {
    {
      "<leader>" .. config.playlist_key,
      "<Plug>(mpv_omnikey)",
      mode = {"n", "v"},
      desc = "Mpv Omnikey",
    },
    {
      "<leader>yt",
      "<Plug>(mpv_youtube_prompt)",
      desc = "Open YouTube prompt",
    },
    {
      "<leader>Yt",
      "<Plug>(mpv_youtube_prompt_lucky)",
      desc = "Open YouTube prompt (I'm feeling lucky)",
    },
    {
      "<leader>[",
      "<Plug>(mpv_goto_earlier)",
      desc = "Go to previous mpv instance",
    },
    {
      "<leader>]",
      "<Plug>(mpv_goto_later)",
      desc = "Go to next mpv instance",
    },
    {
      "<leader>D",
      "<Plug>(mpv_download_range)",
      desc = "Download video",
      mode = {"n", "v"},
    },
  }

  if
    config.playlist_key_video ~= ""
    and config.playlist_key_video ~= config.playlist_key
  then
    table.insert(specs, {
      "<leader>" .. config.playlist_key_video,
      "<Plug>(mpv_omnikey_video)",
      mode = {"n", "v"},
      desc = "Mpv Omnikey (Video)",
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
        silent = true,
        buffer = 0,
      }
    )
  end
end

return keys
