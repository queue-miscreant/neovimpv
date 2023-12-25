" Close buffer on q
nnoremap <buffer> <silent> q :q<cr>

" check that we have callbacks
if !exists("b:mpv_selection") ||
      \ !exists("b:mpv_calling_window") ||
      \ len(b:mpv_selection) ==# 0
  echohl ErrorMsg
  echo "No data found when opening YouTube results buffer! Closing window..."
  echohl None
  quit!
  finish
endif

setlocal nowrap
setlocal cursorline
setlocal bufhidden="wipe"

" Additional video data as extmarks
let s:prev_line = -1
function s:set_youtube_extmark()
  if s:prev_line ==# line(".")
    return
  endif
  let s:prev_line = line(".")

  let current = b:mpv_selection[s:prev_line - 1]
  if exists("current.video_id")
    call nvim_buf_set_extmark(
          \ 0,
          \ luaeval("neovimpv.DISPLAY_NAMESPACE"),
          \ line(".") - 1,
          \ 0,
          \ { "id": 1,
          \   "virt_text": [[current["length"], "MpvYoutubeLength"]],
          \   "virt_text_pos": "eol",
          \   "virt_lines": [
          \     [[current["channel_name"], "MpvYoutubeChannelName"]],
          \     [[current["views"], "MpvYoutubeViews"]]
          \   ]
          \ })
  elseif exists("current.playlist_id")
    let video_extmarks =
          \ [[[current["channel_name"], "MpvYoutubeChannelName"]]]
    for video in current["videos"]
      call add(video_extmarks, [
            \ ["  ", "MpvDefault"],
            \ [video["title"], "MpvYoutubePlaylistVideo"],
            \ [" ", "MpvDefault"],
            \ [video["length"], "MpvYoutubeLength"]
            \ ])
    endfor
    call nvim_buf_set_extmark(
          \ 0,
          \ luaeval("neovimpv.DISPLAY_NAMESPACE"),
          \ line(".") - 1,
          \ 0,
          \ { "id": 1,
          \   "virt_text": [[current["video_count"] . " videos", "MpvYoutubeVideoCount"]],
          \   "virt_text_pos": "eol",
          \   "virt_lines": video_extmarks
          \ })
  endif
endfunction

" Replace yank contents with URL
function s:yank_youtube_link(event)
  if !( len(a:event["regcontents"]) ==# 1 && a:event["operator"] ==# "y" )
    return
  endif

  let current = b:mpv_selection[line(".") - 1]
  call setreg(a:event["regname"], current["link"])
endfunction

nnoremap <buffer> <silent> <cr> :call
      \ neovimpv#youtube#callback("")<cr>

nnoremap <buffer> <silent> <s-enter> :call
      \ neovimpv#youtube#callback("--video=auto")<cr>

nnoremap <buffer> <silent> v :call
      \ neovimpv#youtube#callback("--video=auto")<cr>

nnoremap <buffer> <silent> p :call
      \ neovimpv#youtube#callback("paste --")<cr>

nnoremap <buffer> <silent> P :call
      \ neovimpv#youtube#callback("paste -- --video=auto")<cr>

nnoremap <buffer> <silent> n :call
      \ neovimpv#youtube#callback("new --")<cr>

nnoremap <buffer> <silent> N :call
      \ neovimpv#youtube#callback("new -- --video=auto")<cr>

nnoremap <buffer> <silent> i :call
      \ neovimpv#youtube#open_thumbnail()<cr>

autocmd CursorMoved <buffer> call s:set_youtube_extmark()
autocmd TextYankPost <buffer> call s:yank_youtube_link(v:event)
