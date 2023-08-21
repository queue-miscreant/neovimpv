setlocal nowrap
setlocal nohidden

nnoremap <silent><buffer> <leader>\ <Plug>(mpv_omnikey)
vnoremap <silent><buffer> <leader>\ <Plug>(mpv_omnikey)
nnoremap <silent><buffer> <leader>[ <Plug>(mpv_goto_earlier)
nnoremap <silent><buffer> <leader>] <Plug>(mpv_goto_later)
