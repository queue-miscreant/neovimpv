" Formatting variables
" These ones are settable from vimrc and have no special interpretation
let g:mpv_loading = get(g:, "mpv_loading", "[ ... ]")
let g:mpv_format = get(g:, "mpv_format", "[ {pause} {playback-time} / {duration} {loop} ]")
let g:mpv_style = get(g:, "mpv_style", "unicode")
let g:mpv_default_highlight = get(g:, "mpv_default_highlight", "LineNr")
let g:mpv_highlights = get(g:, "mpv_highlights", {})

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

" Omni-function for sending keys to mpv
function! NeovimpvOmni(...)
  " Try to find mpv on the line
  let plugin = get(nvim_get_namespaces(), "Neovimpv", v:false)
  let mpv_instances = []
  if plugin
    let cline = line(".")
    let mpv_instances = nvim_buf_get_extmarks(0, plugin, [cline - 1, 0], [cline - 1, -1], {})
  endif
  if len(mpv_instances) == 0
    " no mpv found, trying to open
    if a:0
      execute ":MpvOpen"
    else
      nvim_notify("No mpv found running on that line", 4, {})
    endif
  else
    " mpv found, get key to send
    let new_extmark = nvim_buf_set_extmark(0, plugin, cline - 1, 0, {
          \ "virt_text": [["[ getting input... ]", g:mpv_default_highlight]],
          \ "virt_text_pos": "eol"
          \ } )
    redraw
    let temp = getcharstr()
    call MpvSendNvimKeys(mpv_instances[0][0], temp)
    call nvim_buf_del_extmark(0, plugin, new_extmark)
  endif
endfunction
