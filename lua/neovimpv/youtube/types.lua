---@alias VirtText [string, string][]

---@alias YTSearchResult (YTVideo | YTPlaylist)

---@class YTVideo A search result which is a video
---@field thumbnail string
---@field title string
---@field video_id string
---@field length string
---@field views string
---@field channel_name string

---@class YTPlaylist A search result which is a playlist
---@field title string
---@field playlist_id string
---@field video_count string
---@field channel_name string
---@field videos YTChildVideo[]
---@field link string
---@field markdown string

---@class YTChildVideo One of the videos in a playlist result
---@field title string
---@field length string
---@field video_id string

---@class YTPlaylistVideo Videos from a playlist page (/playlist)
---@field title string
---@field length string
---@field video_id string
---@field thumbnail string
---@field channel_name string
