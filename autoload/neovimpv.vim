function s:exit_mode(...)
  exe "normal \<esc>"
endfunction

" " Helper function for exiting visual mode and starting the omnikey callback
" " This allows the < and > marks (for visual mode) to be set
" function neovimpv#visual_omnikey(...) range
"   let visual_mode = "vline"
"   if mode()[0] ==# "\x16"
"     let visual_mode = "vblock"
"   elseif mode()[0] ==# "v"
"     let visual_mode = "visual"
"   endif
"
"   if a:0 >= 1
"     " NOTE: This assumes the first argument is an 'mpv' level argument,
"     " which is how this function is bound as a keymap.
"     call timer_start(0, { -> neovimpv#omnikey(1, visual_mode . " -- " . a:1) }, {})
"   else
"     call timer_start(0, { -> neovimpv#omnikey(1, visual_mode . " --") }, {})
"   endif
" endfunction

" Omni-function for sending keys to mpv
function neovimpv#omnikey(is_visual, ...) range
  let extra_args = ""
  if a:0 >= 1
    let extra_args = a:1
  endif
  " Try to find mpv on the line
  let try_get_mpv = luaeval(
        \ "neovimpv.get_player_by_line(0," . a:firstline . "," . a:lastline . ", true)")

  if try_get_mpv == []
    " no playlist on that line found, trying to open
    if g:mpv_omni_open_new_if_empty
      let [start_line, end_line] = [a:firstline, a:lastline]
      " if a:is_visual
      "   let [start_line, end_line] = [line("'<"), line("'>")]
      " endif
      execute ":" . start_line . "," . end_line . "MpvOpen " . extra_args
    endif
  elseif !a:is_visual
    let [player, playlist_item] = try_get_mpv

    if extra_args =~# "--video=auto"
      call MpvToggleVideo(player)
      call timer_start(0, function("\<SID>exit_mode"), {})
      return
    endif

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
      if temp ==# g:mpv_playlist_key
        call MpvSetPlaylist(player, playlist_item)
      else
        call MpvSendNvimKeys(player, temp, v:count)
      endif
    finally
      call nvim_buf_del_extmark(0, temp_ns, new_extmark)
    endtry
  else
    echohl ErrorMsg
    echo "Given range includes playlist! Ignoring..."
    echohl None
  endif
  call timer_start(0, function("\<SID>exit_mode"), {})
endfunction

" Jump forward or backward (depending on `direction`) to the line of the nearest mpv player
function neovimpv#goto_relative_mpv(direction)
  let current = line(".") - 1

  let start = [current + 1, 0]
  let end = [-1, -1]
  if a:direction < 0
    let start = [current - 1, 0]
    let end = [0, -1]
  endif
  let mpv_instances = nvim_buf_get_extmarks(
        \ 0,
        \ luaeval("neovimpv.DISPLAY_NAMESPACE"),
        \ start,
        \ end,
        \ {}
        \ )

  if len(mpv_instances) == 0
    echohl ErrorMsg
    if a:direction < 0
      echom "No previous mpv found"
    else
      echom "No later mpv found"
    endif
    echohl None
    return
  endif

  execute "normal " . string(mpv_instances[0][1] + 1) . "G"
endfunction

" Open search prompt
function neovimpv#youtube_search_prompt(first_result)
  if ! &modifiable
    echohl ErrorMsg
    echo "Cannot search YouTube from non-modifiable buffer!"
    echohl None
    return
  endif

  let query = input("YouTube Search: ")
  if len(query) != 0
    if a:first_result == 0
      execute "MpvYoutubeSearch " . query
    else
      execute "MpvYoutubeSearch! " . query
    endif
  endif
endfunction

let s:old_extmark = []
" Given the number of lines after a change, figure out whether it was a
" deletion and try to find extmarks on lines that were deleted
function s:calculate_change(new_lines)
  let lines_added = 1
  let old_lines = line("$")
  " let old_cursor = line(".")
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

" Calback for autocommand. When a change in the buffer occurs, tries to find
" out whether lines where removed and invokes buffer_change_callback
" TODO insert mode equivalent?
function s:undo_for_change_count()
  " grab the attributes after the change that just happened
  let new_lines = line("$")
  " let new_cursor = line(".")
  let new_range = [ line("'["), line("']") ]
  setlocal lz
  let try_undo = b:changedtick
  let pre_undo_cursor = getcurpos()
  undo
  " undo (or redo) for the change
  if try_undo == b:changedtick
    redo
    call s:calculate_change(new_lines)
    undo
  else
    call s:calculate_change(new_lines)
    redo
  endif
  call setpos(".", pre_undo_cursor)
  setlocal nolz
  call timer_start(0, "neovimpv#buffer_change_callback")
endfunction

" Using the old extmark data in s:old_extmark, attempt to find playlist items
" which were deleted, then forward the changes to Python
function neovimpv#buffer_change_callback(...)
  if s:old_extmark != []
    let new_playlists = s:get_players_with_deletions(s:old_extmark)
    call MpvForwardDeletions(new_playlists)
    let s:old_extmark = []
  endif
  let invisible_extmarks = nvim_buf_get_extmarks(
        \ 0,
        \ luaeval("neovimpv.DISPLAY_NAMESPACE"),
        \ [line("$"), 0],
        \ [-1, -1],
        \ {}
        \ )
  " Close all players which fell outside the bounds
  for i in invisible_extmarks
    call MpvSendNvimKeys(i[0], "q", 1)
  endfor
endfunction

" Remove playlist items in `removed_playlist` and clean up the map to the player.
" Along the way, create a reverse mapping consisting whose keys are player ids and
" whose values are playlist ids that survived the change.
function s:get_players_with_deletions(removed_playlist)
  let removed_ids = map(a:removed_playlist, { _, x -> x[0] })

  let altered_players = []
  let removed_items = {}
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
      if get(removed_items, player, []) == []
        let removed_items[player] = []
      endif
      call add(removed_items[player], playlist_item)
    else
    endif
  endfor

  return removed_items
endfunction

" TODO remove autocmd when last player exits?
" TODO use lua callback instead
function neovimpv#bind_autocmd(...)
  let no_text_changed = a:0
  if !no_text_changed && &modifiable
    autocmd TextChanged <buffer> call s:undo_for_change_count()
  endif
  execute "autocmd BufHidden <buffer> :MpvClose " . bufnr()
  execute "autocmd BufDelete <buffer> :MpvClose " . bufnr()
endfunction
