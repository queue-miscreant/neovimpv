" Omni-function for sending keys to mpv
function neovimpv#omnikey(is_visual) range
  " Try to find mpv on the line
  let playlist_item = luaeval(
        \ "neovimpv.get_player_by_line(0," . a:firstline . "," . a:lastline . ")")

  if playlist_item == v:null
    " no playlist on that line found, trying to open
    if g:mpv_omni_open_new_if_empty
      execute ":" . a:firstline . "," . a:lastline . "MpvOpen"
    else
      echohl ErrorMsg
      echo "No mpv found running on that line"
      echohl None
    endif
  elseif !a:is_visual
    " mpv found, get key to send
    let temp_ns = nvim_create_namespace("")
    let new_extmark = nvim_buf_set_extmark(
          \ 0,
          \ temp_ns,
          \ line(".") - 1,
          \ 0,
          \ {
          \   "virt_text": [["[ getting input... ]", "MpvDefault"]],
          \   "virt_text_pos": "eol"
          \ } )
    redraw
    try
      let temp = getcharstr()
      call MpvSendNvimKeys(playlist_item, temp, v:count)
    finally
      call nvim_buf_del_extmark(0, temp_ns, new_extmark)
    endtry
  else
    echohl ErrorMsg
    echo "Given range includes playlist; ignoring"
    echohl None
  endif
endfunction

function neovimpv#goto_relative_mpv(direction)
  let current = line(".") - 1
  let mpv_instances = nvim_buf_get_extmarks(
        \ 0,
        \ luaeval("neovimpv.DISPLAY_NAMESPACE"),
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

let s:old_extmark = []
function s:calculate_change(new_lines, new_cursor, new_range)
  let lines_added = 1
  let old_lines = line("$")
  let old_cursor = line(".")
  let old_range = [ line("'["), line("']") ]

  if old_lines > a:new_lines
    " lines were deleted
    let lines_added = 0
    " hack for last line of the file
    if old_range[1] == old_lines
      let old_range[0] = old_lines
    endif
  endif

  let old_extmark = nvim_buf_get_extmarks(
        \ 0,
        \ luaeval("neovimpv.PLAYLIST_NAMESPACE"),
        \ [old_range[0] - 1, 0],
        \ [old_range[1] - 1, -1],
        \ {}
        \ )

  if !lines_added
    let s:old_extmark = old_extmark
  endif
endfunction

" TODO: cleanup, insert mode equivalent
function s:undo_for_change_count()
  " grab the attributes after the change that just happened
  let new_lines = line("$")
  let new_cursor = line(".")
  let new_range = [ line("'["), line("']") ]
  setlocal lz
  let try_undo = b:changedtick
  undo
  " undo (or redo) for the change
  if try_undo == b:changedtick
    redo
    call s:calculate_change(new_lines, new_cursor, new_range)
    undo
  else
    call s:calculate_change(new_lines, new_cursor, new_range)
    redo
  endif
  setlocal nolz
  call timer_start(0, "neovimpv#buffer_change_callback")
endfunction

function neovimpv#buffer_change_callback(...)
  if s:old_extmark != []
    let new_playlists = s:get_updated_mpv_playlist(s:old_extmark)
    call MpvUpdatePlaylists(new_playlists)
    let s:old_extmark = []
  endif
endfunction

function s:get_updated_mpv_playlist(removed_extmarks)
  let removed_ids = map(a:removed_extmarks, { _, x -> x[0] })

  let altered_players = []
  let old_playlists = {}
  for [playlist_item, player] in items(b:mpv_playlists_to_displays)
    let playlist_item = str2nr(playlist_item)
    if index(removed_ids, playlist_item) >= 0
      unlet b:mpv_playlists_to_displays[playlist_item]
      call nvim_buf_del_extmark(
            \ 0,
            \ luaeval("neovimpv.PLAYLIST_NAMESPACE"),
            \ playlist_item
            \ )
      call add(altered_players, player)
    else
      if get(old_playlists, player, []) == []
        let old_playlists[player] = []
      endif
      call add(old_playlists[player], playlist_item)
    endif
  endfor

  let new_playlists = {}
  for [player, playlist_items] in items(old_playlists)
    if index(altered_players, str2nr(player)) >= 0
      let new_playlists[player] = playlist_items
    endif
  endfor

  return new_playlists
endfunction

" TODO remove autocmd when last player exits?
function neovimpv#bind_autocmd()
  autocmd TextChanged <buffer> call s:undo_for_change_count()
endfunction
