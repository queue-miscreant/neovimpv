" paste the result of a youtube buffer selection into window_id
function s:mpv_youtube_paste(window_id, value)
  let row = getcurpos(a:window_id)[1]
  let buffer_id = winbufnr(a:window_id)
  let line = getbufoneline(buffer_id, row)

  quit
  if len(line) == 0
    call setbufline(buffer_id, row, "ytdl://" . a:value["video_id"])
  else
    call setbufline(buffer_id, row+1, "ytdl://" . a:value["video_id"])
    normal j
  endif

  return 1
endfunction

" Callback for youtube results buffers
function neovimpv#youtube#callback(extra)
  let current = b:selection[line(".") - 1]
  if s:mpv_youtube_paste(b:calling_window, current)
    execute ":MpvOpen " . a:extra
  endif
endfunction

" Callback for youtube results buffers
function neovimpv#youtube#open_thumbnail()
  let current = b:selection[line(".") - 1]
  call system(
        \ 'read -r url; ' .
        \ 'temp=`mktemp`; ' .
        \ 'curl -L "$url" > "$temp" 2>/dev/null; ' .
        \ 'xdg-open "$temp"',
        \ current["thumbnail"])
endfunction
