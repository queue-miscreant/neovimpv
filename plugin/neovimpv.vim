" These ones are settable from vimrc and have no special interpretation
let g:mpv_loading = get(g:, "mpv_loading", "[ ... ]")
let g:mpv_format = get(g:, "mpv_format", "[ {pause} {playback-time} / {duration} {loop} ]")
let g:mpv_style = get(g:, "mpv_style", "unicode")
let g:mpv_default_highlight = get(g:, "mpv_default_highlight", "LineNr")
let g:mpv_highlights = get(g:, "mpv_highlights", {})

" Example configuration matching the current defaults defined in `format.py`
"
" let s:mpv_highlight_defaults = {
"       \ "pause@true": "Conceal",
"       \ "pause@false": "Title",
"       \ "playback-time": "Conceal",
"       \ "duration": "Conceal",
"       \ }
