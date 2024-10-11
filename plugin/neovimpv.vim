if !has("nvim")
  echo "Plugin not supported outside of nvim"
  finish
endif

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

autocmd VimEnter * lua if not package.loaded.lazy then require("neovimpv").setup() end
