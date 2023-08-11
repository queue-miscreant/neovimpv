" check that we have callbacks
if !exists("b:selection") ||
      \ !exists("b:calling_window") ||
      \ len(b:selection) == 0
  finish
endif

setlocal nowrap
setlocal cursorline
setlocal nohidden

function s:set_youtube_extmark()
  let current = b:selection[line(".") - 1]
  call nvim_buf_set_extmark(
        \ 0,
        \ nvim_create_namespace("Neovimpv"),
        \ line(".") - 1,
        \ 0,
        \ { "id": 1,
        \   "virt_text": [[current["length"], g:mpv_youtube_highlights["length"]]],
        \   "virt_text_pos": "eol",
        \   "virt_lines": [
        \     [[current["channel_name"], g:mpv_youtube_highlights["channel_name"]]],
        \     [[current["views"], g:mpv_youtube_highlights["views"]]]
        \   ]
        \ })
endfunction

function s:yank_youtube_link(event)
  if !( len(a:event["regcontents"]) == 1 && a:event["operator"] == "y" )
    return
  endif

  let current = b:selection[line(".") - 1]
  call setreg(a:event["regname"], current["link"])
endfunction

nnoremap <buffer> <silent> <cr> :call
      \ neovimpv#youtube_callback("")<cr>

nnoremap <buffer> <silent> <s-enter> :call
      \ neovimpv#youtube_callback("--video=auto")<cr>

nnoremap <buffer> <silent> v :call
      \ neovimpv#youtube_callback("--video=auto")<cr>

nnoremap <buffer> <silent> i :call
      \ neovimpv#youtube_thumbnail()<cr>

autocmd CursorMoved <buffer> call s:set_youtube_extmark()
autocmd TextYankPost <buffer> call s:yank_youtube_link(v:event)
