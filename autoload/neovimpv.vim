" Omni-function for sending keys to mpv
function neovimpv#omnikey()
  " Try to find mpv on the line
  let plugin = get(nvim_get_namespaces(), "Neovimpv", v:false)
  let mpv_instances = []
  if plugin
    let cline = line(".")
    let mpv_instances = nvim_buf_get_extmarks(0, plugin, [cline - 1, 0], [cline - 1, -1], {})
  endif
  if len(mpv_instances) == 0
    " no mpv found, trying to open
    if g:mpv_omni_open_new_if_empty
      execute ":MpvOpen"
    else
      call nvim_notify("No mpv found running on that line", 4, {})
    endif
  else
    " mpv found, get key to send
    let new_extmark = nvim_buf_set_extmark(0, plugin, cline - 1, 0, {
          \ "virt_text": [["[ getting input... ]", g:mpv_default_highlight]],
          \ "virt_text_pos": "eol"
          \ } )
    redraw
    let temp = getcharstr()
    call MpvSendNvimKeys(mpv_instances[0][0], temp)
    call nvim_buf_del_extmark(0, plugin, new_extmark)
  endif
endfunction

" Callback for youtube results buffers
function neovimpv#youtube_search_prompt()
  let query = input("YouTube Search: ")
  if len(query) != 0
    execute ":MpvYoutubeSearch " . query
  endif
endfunction

" paste the result of a youtube buffer selection into window_id
function s:mpv_youtube_paste(window_id, value)
  let row = nvim_win_get_cursor(a:window_id)[0]
  let buffer_id = nvim_win_get_buf(a:window_id)
  let lines = nvim_buf_get_lines(buffer_id, row-1, row, v:false)
  if len(lines) == 0
    return v:false
  endif

  quit

  let restore_noro = v:false
  if nvim_buf_get_option(buffer_id, "readonly")
    let restore_noro = v:true
    call nvim_buf_set_option(buffer_id, "readonly", v:false)
  endif

  if len(trim(lines[0])) == 0
    call nvim_buf_set_text(
          \ buffer_id,
          \ row-1,
          \ 0,
          \ row-1,
          \ 0,
          \ ["ytdl://" . a:value["video_id"]]
          \ )
  else
    call nvim_buf_set_lines(
          \ buffer_id,
          \ row-1,
          \ row-1,
          \ v:false,
          \ ["ytdl://" . a:value["video_id"]]
          \ )
    call nvim_win_set_cursor(a:window_id, [row, 0])
  endif

  if restore_noro
    call nvim_buf_set_option(buffer_id, "readonly", v:true)
  endif

  return v:true
endfunction

" Callback for youtube results buffers
function neovimpv#youtube_callback(extra)
  let current = b:selection[line(".") - 1]
  if s:mpv_youtube_paste(b:calling_window, current)
    execute ":MpvOpen " . a:extra
  endif
endfunction
