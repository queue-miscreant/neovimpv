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
" Possible values: "stay", "paste", "paste_one", "new_one"
"       TODO: stay keeps the player default and uses extmarks to show current
"       video
" Default is "stay": keep the player in the position of the playlist item
" "paste": insert the new playlist in place of the playlist
" "paste_one": like "paste" if the playlist is the only item in the list,
"              otherwise like "stay"
" "new_one": like "paste_one", but the playlist is put into a new buffer
let g:mpv_on_playlist_update = get(g:, "mpv_on_playlist_update", "stay")

" do lua setup
lua require('neovimpv')

nnoremap <silent> <Plug>(mpv_omnikey) :<c-u>call neovimpv#omnikey(0)<cr>
vnoremap <silent> <Plug>(mpv_omnikey) :call neovimpv#omnikey(1)<cr>
nnoremap <silent> <Plug>(mpv_goto_earlier) :<c-u>call neovimpv#goto_relative_mpv(-1)<cr>
nnoremap <silent> <Plug>(mpv_goto_later) :<c-u>call neovimpv#goto_relative_mpv(1)<cr>
nnoremap <silent> <Plug>(mpv_youtube_prompt) :<c-u>call neovimpv#youtube_search_prompt()<cr>

let g:mpv_defaulted_highlights = ["MpvPauseTrue", "MpvPauseFalse", "MpvPlaybackTime", "MpvDuration"]
hi default link MpvDefault LineNr

hi default link MpvPauseTrue Conceal
hi default link MpvPauseFalse Title
hi default link MpvPlaybackTime Conceal
hi default link MpvDuration Conceal

hi default link MpvYoutubeLength MpvDefault
hi default link MpvYoutubeChannelName MpvDefault
hi default link MpvYoutubeViews MpvDefault
hi default link MpvYoutubeVideoCount MpvDefault
hi default link MpvYoutubePlaylistVideo MpvDefault

hi default link MpvPlaylistSign SignColumn
