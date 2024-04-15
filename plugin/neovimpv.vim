if !has("nvim")
  echo "Plugin not supported outside of nvim"
  finish
endif
" Formatting variables
" These ones are settable from vimrc and have no special interpretation
let g:mpv_loading = get(g:, "mpv_loading", "[ ... ]")
let g:mpv_format = get(g:, "mpv_format", "[ {pause} {playback-time} / {duration} {loop} ]")
let g:mpv_style = get(g:, "mpv_style", "unicode")
let g:mpv_property_thresholds = get(g:, "mpv_property_thresholds", {})
let g:mpv_omni_open_new_if_empty = v:true

" Markdown-writable files
let g:mpv_markdown_writable = get(g:, "mpv_markdown_writable", [])
call add(g:mpv_markdown_writable, "youtube_playlist")

" Default arguments for mpv instances
let g:mpv_default_args = get(g:, "mpv_default_args", [])

" When to show playlist extmarks in the sign column
" Possible values: "always", "multiple", "never"
let g:mpv_draw_playlist_extmarks = get(g:, "mpv_draw_playlist_extmarks", "multiple")

" Controls how playlist updates from mpv can affect changes in the buffer
let g:mpv_on_playlist_update = get(g:, "mpv_on_playlist_update", "stay")

" Whether or not YouTube playlists are opened 'smartly'.
let g:mpv_smart_youtube_playlist = get(g:, "mpv_youtube_playlist_always_new", 1)

" Key for scrolling a player to a playlist index
let g:mpv_playlist_key = get(g:, "mpv_playlist_key", "\\")
let g:mpv_playlist_key_video = get(g:, "mpv_playlist_key_video", "")
if g:mpv_playlist_key_video ==# ""
  if g:mpv_playlist_key ==# "\\"
    let g:mpv_playlist_key_video = "<bar>"
  elseif g:mpv_playlist_key ==# ","
    let g:mpv_playlist_key_video = "."
  elseif g:mpv_playlist_key ==# "~"
    let g:mpv_playlist_key_video = "`"
  endif
endif

" Bind things in `g:mpv_markdown_writable` filetypes
let g:mpv_markdown_smart_bindings = get(g:, "mpv_markdown_smart_bindings", 0)

" Filetypes which should have smart bindings added by default
let g:mpv_smart_filetypes = get(g:, "mpv_smart_filetypes", [])
call add(g:mpv_smart_filetypes, "youtube_playlist")

if g:mpv_markdown_smart_bindings
  for i in g:mpv_markdown_writable
    call add(g:mpv_smart_filetypes, i)
  endfor
  call uniq(sort(g:mpv_smart_filetypes))
endif

" do lua setup
lua require('neovimpv')

nnoremap <silent> <Plug>(mpv_omnikey) :<c-u>call neovimpv#omnikey(0)<cr>
nnoremap <silent> <Plug>(mpv_omnikey_video) :<c-u>call neovimpv#omnikey(0, "--video=auto")<cr>
vnoremap <silent> <expr> <Plug>(mpv_omnikey) neovimpv#visual_omnikey()
vnoremap <silent> <expr> <Plug>(mpv_omnikey_video) neovimpv#visual_omnikey("--video=auto")
nnoremap <silent> <Plug>(mpv_goto_earlier) :<c-u>call neovimpv#goto_relative_mpv(-1)<cr>
nnoremap <silent> <Plug>(mpv_goto_later) :<c-u>call neovimpv#goto_relative_mpv(1)<cr>
nnoremap <silent> <Plug>(mpv_youtube_prompt) :<c-u>call neovimpv#youtube_search_prompt(0)<cr>
nnoremap <silent> <Plug>(mpv_youtube_prompt_lucky) :<c-u>call neovimpv#youtube_search_prompt(1)<cr>

let g:mpv_defaulted_highlights = ["MpvPauseTrue", "MpvPauseFalse", "MpvPlaybackTime", "MpvDuration", "MpvTitle"]
hi default link MpvDefault LineNr

hi default link MpvPauseTrue Conceal
hi default link MpvPauseFalse Title
hi default link MpvPlaybackTime Conceal
hi default link MpvDuration Conceal
hi default link MpvTitle MpvDefault

hi default link MpvYoutubeLength MpvDefault
hi default link MpvYoutubeChannelName MpvDefault
hi default link MpvYoutubeViews MpvDefault
hi default link MpvYoutubeVideoCount MpvDefault
hi default link MpvYoutubePlaylistVideo MpvDefault

hi default link MpvPlaylistSign SignColumn

function! s:mpv_bind_smart_keys()
  exe "nnoremap <silent><buffer> <leader>" . g:mpv_playlist_key . " <Plug>(mpv_omnikey)"
  exe "vnoremap <silent><buffer> <leader>" . g:mpv_playlist_key . " <Plug>(mpv_omnikey)"
  if g:mpv_playlist_key_video !=# "" && g:mpv_playlist_key_video !=# g:mpv_playlist_key
    exe "nnoremap <silent><buffer> <leader>" . g:mpv_playlist_key_video . " <Plug>(mpv_omnikey_video)"
    exe "vnoremap <silent><buffer> <leader>" . g:mpv_playlist_key_video . " <Plug>(mpv_omnikey_video)"
  endif

  nnoremap <silent><buffer> <leader>yt <Plug>(mpv_youtube_prompt)
  nnoremap <silent><buffer> <leader>Yt <Plug>(mpv_youtube_prompt_lucky)
  nnoremap <silent><buffer> <leader>[ <Plug>(mpv_goto_earlier)
  nnoremap <silent><buffer> <leader>] <Plug>(mpv_goto_later)
endfunction

augroup MpvSmartBindings
  for i in g:mpv_smart_filetypes
    exe "autocmd Filetype " . i . " call s:mpv_bind_smart_keys()"
  endfor
augroup end
