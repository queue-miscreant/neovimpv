" Insert `value` at the line of the current cursor, if it's empty.
" Otherwise, insert it a line below the current line.
function s:try_insert(value)
  let row = line(".")
  let append_line = len(getline(row)) != 0

  let targetrow = row
  if append_line
    call append(targetrow, a:value)
  else
    call setline(targetrow, a:value)
  endif

  return append_line
endfunction

" Callback for youtube results buffers. Return to the calling window,
" paste the link where the cursor is, then call MpvOpen.
" Writes markdown if the buffer's filetype supports markdown.
function neovimpv#youtube#callback(extra)
  let current = b:mpv_selection[line(".") - 1]
  let window = b:mpv_calling_window
  " Close the youtube buffer and return the calling window
  quit!
  call win_gotoid(window)

  if ! &modifiable
    echohl ErrorMsg
    echo "Buffer is modifiable. Cannot paste result."
    echohl None
    return
  endif

  " if exists("current.playlist_id")
  "   call MpvOpenYoutubePlaylist(current, a:extra)
  "   return
  " endif

  let insert_link = current["link"]
  if index(luaeval("vim.neovimpv.config.markdown_writable"), &l:filetype) >= 0
    let insert_link = current["markdown"]
  endif

  if s:try_insert(insert_link)
    normal j
  endif
  execute ":MpvOpen " . a:extra
endfunction

" Callback for youtube results buffers.
" Opens the thumbnail of result under the cursor in the system viewer.
function neovimpv#youtube#open_thumbnail()
  let current = b:mpv_selection[line(".") - 1]

  if !exists("current.thumbnail")
    return
  endif

  call system(
        \ 'read -r url; ' .
        \ 'temp=`mktemp`; ' .
        \ 'curl -L "$url" > "$temp" 2>/dev/null; ' .
        \ 'xdg-open "$temp"',
        \ current["thumbnail"])
endfunction
