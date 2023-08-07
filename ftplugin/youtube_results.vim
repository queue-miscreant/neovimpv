" check that we have callbacks
if !exists("b:selection") || !exists("b:calling_window")
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

nnoremap <buffer> <silent> <cr> :call
      \ neovimpv#youtube_callback("")<cr>
nnoremap <buffer> <silent> <s-enter> :call
      \ neovimpv#youtube_callback("--video=auto")<cr>


autocmd CursorMoved <buffer> call s:set_youtube_extmark()
