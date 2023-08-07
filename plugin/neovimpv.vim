" Formatting variables
" These ones are settable from vimrc and have no special interpretation
let g:mpv_loading = get(g:, "mpv_loading", "[ ... ]")
let g:mpv_format = get(g:, "mpv_format", "[ {pause} {playback-time} / {duration} {loop} ]")
let g:mpv_style = get(g:, "mpv_style", "unicode")
let g:mpv_default_highlight = get(g:, "mpv_default_highlight", "LineNr")
let g:mpv_highlights = get(g:, "mpv_highlights", {})
let g:mpv_omni_open_new_if_empty = v:true

" Example configuration matching the current defaults defined in `format.py`
" Note the special syntax for `pause`
"
" let s:mpv_highlight_defaults = {
"       \ "pause@true": "Conceal",
"       \ "pause@false": "Title",
"       \ "playback-time": "Conceal",
"       \ "duration": "Conceal",
"       \ }

" Markdown-writable files
let g:mpv_markdown_writable = get(g:, "mpv_markdown_writable", [])

" Default arguments for mpv instances
let g:mpv_default_args = get(g:, "mpv_default_args", [])

let s:mpv_youtube_highlights = get(g:, "mpv_youtube_highlights", {})
for i in ["views", "channel_name", "length"]
  let s:mpv_youtube_highlights[i] = get(s:mpv_youtube_highlights, i, g:mpv_default_highlight)
endfor
let g:mpv_youtube_highlights = s:mpv_youtube_highlights

nnoremap <silent> <Plug>(mpv_omnikey) :call neovimpv#omnikey()<cr>
nnoremap <silent> <Plug>(mpv_youtube_prompt) :call neovimpv#youtube_search_prompt()<cr>
