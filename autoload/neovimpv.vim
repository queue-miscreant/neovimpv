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
          \ "virt_text": [["[ getting input... ]", "MpvDefault"]],
          \ "virt_text_pos": "eol"
          \ } )
    redraw
    let temp = getcharstr()
    call MpvSendNvimKeys(mpv_instances[0][0], temp, v:count)
    call nvim_buf_del_extmark(0, plugin, new_extmark)
  endif
endfunction

function neovimpv#goto_relative_mpv(direction)
  let current = line(".") - 1
  let mpv_instances = nvim_buf_get_extmarks(
        \ 0,
        \ nvim_create_namespace("Neovimpv"),
        \ [0, 0],
        \ [-1, -1],
        \ {}
        \ )

  call sort(mpv_instances, { x,y -> a:direction * (y[1] - x[1]) })

  let last = -1
  for i in mpv_instances
    let diff = current - i[1]
    if (diff * -a:direction) <= 0
      break
    endif
    let last = i[1]
  endfor

  if last == -1
    echohl ErrorMsg
    if a:direction < 0
      echom "No previous mpv found"
    else
      echom "No later mpv found"
    endif
    echohl None
    return
  endif

  execute "normal " . string(last + 1) . "G"
endfunction

" Open search prompt
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
          \ row,
          \ row,
          \ v:false,
          \ ["ytdl://" . a:value["video_id"]]
          \ )
    call nvim_win_set_cursor(a:window_id, [row + 1, 0])
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

" Callback for youtube results buffers
function neovimpv#youtube_thumbnail()
  let current = b:selection[line(".") - 1]
  call system(
        \ 'read -r url; ' .
        \ 'temp=`mktemp`; ' .
        \ 'curl -L "$url" > "$temp" 2>/dev/null; ' .
        \ 'xdg-open "$temp"',
        \ current["thumbnail"])
endfunction

let s:prevchange = []
function s:undo_for_change_count()
  " grab the change to the buffer that just happened
  let linesbefore = 0
  let cursorbefore = 0
  let rangebefore = []
  setlocal lz
  let try_undo = b:changedtick
  normal u
  if try_undo == b:changedtick
    exe "normal \<c-r>"
    let linesbefore = line("$")
    let cursorbefore = line(".")
    let rangebefore = [ line("'["), line("']") ]
    normal u
  else
    let linesbefore = line("$")
    let cursorbefore = line(".")
    let rangebefore = [ line("'["), line("']") ]
    exe "normal \<c-r>"
  endif
  setlocal nolz
  let s:prevchange = [ linesbefore, cursorbefore, rangebefore ]
  call timer_start(0, "neovimpv#buffer_change_callback")
endfunction

function! neovimpv#buffer_change_callback(...)
  let cur_lines = line("$")
  let cur_cursor = line(".")
  let cur_range = [ line("'["), line("']") ]

  let lines_diff = cur_lines - s:prevchange[0]
  " lines removed
  if lines_diff < 0
    " prev_range gives the lines that were moved
    let range_removed = s:prevchange[2]
    " NOTE: deleting from the last line of the buffer gives a range of [n-1, n]
    if range_removed[1] == cur_lines
      let range_removed[0] -= 1
    endif
    for value in values(b:mpv_running_instances)
      " TODO: lines in range removed
      let value["lines"] = map(value["lines"], { _, x -> x + lines_diff*(x > range_removed[0]) })
    endfor
  " lines added
  elseif lines_diff > 0
    " cur_range gives the lines that were added
    let range_added = cur_range
    for value in values(b:mpv_running_instances)
      let value["lines"] = map(value["lines"], { _, x -> x + lines_diff*(x > range_added[0]) })
    endfor
  endif
endfunction

function neovimpv#bind_autocmd()
  autocmd TextChanged <buffer> call s:undo_for_change_count()
endfunction
