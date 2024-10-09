local player = require "neovimpv.player"
local config = require "neovimpv.config"
local consts = require "neovimpv.consts"

local keys = {}

local function exit_mode()
  vim.defer_fn(function()
    vim.cmd[[exe "normal \<esc>"]]
  end, 0)
end

---@param extra_args string?
---@param is_visual boolean?
local function omnikey(extra_args, is_visual)
  if extra_args == nil then extra_args = "" end

  local first_line, last_line = vim.fn.line("v"), vim.fn.line(".")
  local try_get_mpv = player.get_player_by_line(0, first_line, last_line, true)

  if #try_get_mpv == 0 then
    -- no playlist on that line found, trying to open
    if config.omni_open_new_if_empty then
      vim.cmd((":%d,%dMpvOpen %s"):format(first_line, last_line, extra_args))
    end
  elseif not is_visual then
    local player, playlist_item = unpack(try_get_mpv) ---@diagnostic disable-line

    if extra_args:find("--video=auto") then
      vim.fn.MpvToggleVideo(player)
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
        vim.fn.MpvSetPlaylist(player, playlist_item)
      else
        vim.fn.MpvSendNvimKeys(player, temp, vim.v.count)
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
    start = {current - 1, 0}
    end_ = {0, -1}
  end

  local mpv_instances = vim.api.nvim_buf_get_extmarks(
    0,
    consts.display_namespace,
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

-- Open search prompt
---@param first_result boolean?
local function youtube_search_prompt(first_result)
  if not vim.bo.modifiable then
    vim.notify("Cannot search YouTube from non-modifiable buffer!", vim.log.levels.ERROR)
    return
  end

  ---@type string
  local query = vim.fn.input("YouTube Search: ")

  if query:len() ~= 0 then
    if first_result then
      vim.cmd("MpvYoutubeSearch! " .. query)
    else
      vim.cmd("MpvYoutubeSearch " .. query)
    end
  end
end

function keys.bind_base()
  local vks = vim.keymap.set
  vks("n", "<Plug>(mpv_omnikey)", function() omnikey() end)
  vks("n", "<Plug>(mpv_omnikey_video)", function() omnikey("--video=auto") end)
  vks("v", "<Plug>(mpv_omnikey)", function() omnikey("vline --", true) end)
  vks("v", "<Plug>(mpv_omnikey_video)", function() omnikey("vline -- --video=auto", true) end)

  vks("n", "<Plug>(mpv_goto_earlier)", function() goto_relative_mpv(-1) end)
  vks("n", "<Plug>(mpv_goto_later)", function() goto_relative_mpv(1) end)
  vks("n", "<Plug>(mpv_youtube_prompt)", function() youtube_search_prompt() end)
  vks("n", "<Plug>(mpv_youtube_prompt_lucky)", function() youtube_search_prompt(true) end)
end

function keys.bind_smart_local()
  local vks = vim.keymap.set
  vks(
    {"n", "v"},
    "<leader>" .. config.playlist_key,
    "<Plug>(mpv_omnikey)",
    {silent = true, buffer = 0}
  )

  if
    config.playlist_key_video ~= ""
    and config.playlist_key_video ~= config.playlist_key
  then
    vks(
      {"n", "v"},
      "<leader>" .. config.playlist_key_video,
      "<Plug>(mpv_omnikey)",
      {silent = true, buffer = 0}
    )
  end

  vks(
    "n",
    "<leader>yt",
    "<Plug>(mpv_youtube_prompt)",
    {silent = true, buffer = 0}
  )
  vks(
    "n",
    "<leader>Yt",
    "<Plug>(mpv_youtube_prompt_lucky)",
    {silent = true, buffer = 0}
  )
  vks(
    "n",
    "<leader>[",
    "<Plug>(mpv_goto_earlier)",
    {silent = true, buffer = 0}
  )
  vks(
    "n",
    "<leader>]",
    "<Plug>(mpv_goto_later)",
    {silent = true, buffer = 0}
  )
end

return keys
