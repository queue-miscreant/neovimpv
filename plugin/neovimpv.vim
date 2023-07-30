let g:mpv_loading = "[ ... ]"
let g:mpv_format = "[ {pause} {playback-time} / {duration} {loop} ]"

let g:mpv_default_highlight = "LineNr"
let g:mpv_highlights = {
      \ "pause@true": "Conceal",
      \ "pause@false": "Title",
      \ "playback-time": "Conceal",
      \ "duration": "Conceal",
      \ }
