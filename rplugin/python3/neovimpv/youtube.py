import json
import sys
import urllib.error
import urllib.parse
import urllib.request

WARN_LXML = False
try:
    import lxml.html
except ImportError:
    WARN_LXML = True

VIDEO_RENDERER_PATHS = {
    "thumbnail": ["thumbnail", "thumbnails", 0, "url"],
    "title": ["title", "runs", 0, "text"],
    "video_id": ["videoId"],
    "length": ["lengthText", "simpleText"],
    "views": ["viewCountText", "simpleText"],
    "channel_name": ["longBylineText", "runs", 0, "text"],
}

PLAYLIST_RENDERER_PATHS = {
    "title": ["title", "simpleText"],
    "playlist_id": ["playlistId"],
    "video_count": ["videoCount"],
    "channel_name": ["longBylineText", "runs", 0, "text"],
    "raw_videos": ["videos"],
}

CHILD_VIDEO_RENDERER_PATHS = {
    "title": ["title", "simpleText"],
    "length": ["lengthText", "simpleText"],
    "video_id": ["videoId"],
}

PLAYLIST_VIDEO_RENDERER_PATHS = {
    "title": ["title", "runs", 0, "text"],
    "length": ["lengthText", "simpleText"],
    "video_id": ["videoId"],
    "thumbnail": ["thumbnail", "thumbnails", 0, "url"],
    "channel_name": ["shortBylineText", "runs", 0, "text"],
}

def try_follow_path(obj, path):
    '''
    Iteratively get an item from a dict/list until the path is consumed.
    Return None on failure
    '''
    temp = obj
    for i in path:
        try:
            temp = temp[i]
        except (KeyError, ValueError):
            return None
    return temp

def parse_dict(dict, paths):
    if dict is None:
        return {}
    ret = {}
    for name, path in paths.items():
        ret[name] = try_follow_path(dict, path)
    return ret

def parse_video_renderer(renderer, paths=VIDEO_RENDERER_PATHS):
    '''
    Transform a video JSON from the YouTube search page (pared down by
    YoutubeResults.CONTENTS_PATH) into a dict with the same keys as
    `paths` with values from the page.
    '''
    ret = parse_dict(renderer, paths)
    try:
        ret["link"] = f"https://youtu.be/{ret['video_id']}"
        ret["markdown"] = f"[{ret['title'].replace('[', '(').replace(']', ')')}]({ret['link']})"
    except KeyError:
        return None
    return ret

parse_child_video_renderer = lambda renderer: parse_video_renderer(renderer, CHILD_VIDEO_RENDERER_PATHS)
parse_playlist_video_renderer = lambda renderer: parse_video_renderer(renderer, PLAYLIST_VIDEO_RENDERER_PATHS)

def parse_playlist_renderer(renderer):
    '''
    Transform a playlist JSON from the YouTube search page (pared down by
    YoutubeResults.CONTENTS_PATH) into a dict with the same keys as
    PLAYLIST_RENDERER_PATHS with values from the page.
    '''
    ret = parse_dict(renderer, PLAYLIST_RENDERER_PATHS)
    # parse the child videos that display for a playlist
    try:
        ret["videos"] = [i for i in (
            parse_child_video_renderer(video.get("childVideoRenderer"))
            for video in ret["raw_videos"]
        ) if i]
        ret["link"] = f"https://youtube.com/playlist?list={ret['playlist_id']}"
        del ret["raw_videos"]
    except KeyError:
        return None
    return ret

def format_result(result):
    ret = result["title"]
    if result.get("playlist_id") is not None:
        ret = "☰ " + ret # clearly, playlists are heavenly
    return ret

class YoutubeResults:
    '''
    Class containing methods related to curling the YouTube search page.
    Pray that they don't change the page layout at some point in the future.
    '''
    # script tag with response should contain this object to start with
    SCRIPT_SENTINEL = "var ytInitialData = "
    CONTENTS_PATH = [
        "contents",
        "twoColumnSearchResultsRenderer",
        "primaryContents",
        "sectionListRenderer",
        "contents",
        0,
        "itemSectionRenderer",
        "contents"
    ]
    def __init__(self, video_results):
        videos = [i for i in (
            parse_video_renderer(result.get("videoRenderer"))
            for result in video_results
        ) if i]
        playlists = [i for i in (
            parse_playlist_renderer(result.get("playlistRenderer"))
            for result in video_results
        ) if i]
        all = [i for i in (
               parse_video_renderer(result.get("videoRenderer")) or
               parse_playlist_renderer(result.get("playlistRenderer"))
               for result in video_results
           ) if i]

        self.videos = videos
        self.playlists = playlists
        self.all = all

    @classmethod
    def get_all(cls, query):
        results = cls._search_json_raw(query)
        contents = try_follow_path(results, cls.CONTENTS_PATH)
        return cls(contents or [])

    @classmethod
    def _extract_youtube_response(cls, response):
        '''Extract JSON from curl of YouTube results page'''
        parsed = lxml.html.parse(response)
        for tag in parsed.iter("script"):
            content = tag.text_content()
            if not isinstance(content, str) or not content.startswith(cls.SCRIPT_SENTINEL):
                continue
            # this script defines a single variable and has a trailing semicolon
            return json.loads(content[len(cls.SCRIPT_SENTINEL):-1])
        return None

    @classmethod
    def _search_json_raw(cls, query):
        '''Run youtube curl and parse result'''
        url = f"https://www.youtube.com/results?search_query={urllib.parse.quote(query)}"
        # print(f"Curling {url}", file=sys.stderr)
        with urllib.request.urlopen(url) as a:
            return cls._extract_youtube_response(a)

class YoutubePlaylist:
    SENTINEL = "var ytInitialData = "
    CONTENTS_PATH = [
        "contents",
        "twoColumnBrowseResultsRenderer",
        "tabs",
        0,
        "tabRenderer",
        "content",
        "sectionListRenderer",
        "contents",
        0,
        "itemSectionRenderer",
        "contents",
        0,
        "playlistVideoListRenderer",
        "contents",
    ]

    def __init__(self, playlist_contents):
        self.contents = [i for i in (
            parse_playlist_video_renderer(result.get("playlistVideoRenderer"))
            for result in playlist_contents
        ) if i]

    @classmethod
    def get_all(cls, playlist_id):
        results = cls._search_json_raw(playlist_id)
        contents = try_follow_path(results, cls.CONTENTS_PATH)
        return cls(contents or [])

    @classmethod
    def _extract_youtube_response(cls, response):
        '''Extract JSON from curl of YouTube results page'''
        parsed = lxml.html.parse(response)
        for tag in parsed.iter("script"):
            content = tag.text_content()
            if not isinstance(content, str) or not content.startswith(cls.SENTINEL):
                continue
            # this script defines a single variable and has a trailing semicolon
            return json.loads(content[len(cls.SENTINEL):-1])
        return None

    @classmethod
    def _search_json_raw(cls, playlist_id):
        '''Run youtube curl and parse result'''
        url = f"https://www.youtube.com/playlist?list={playlist_id}"
        print(f"Curling {url}", file=sys.stderr)
        with urllib.request.urlopen(url) as a:
            return cls._extract_youtube_response(a)

async def open_results_buffer(nvim, youtube_query):
    '''Run search query in YouTube, then pass scraped results to Lua'''
    # don't block the event loop while waiting for results
    def executor():
        try:
            return YoutubeResults.get_all(youtube_query)
        except urllib.error.HTTPError as e:
            nvim.show_error(f"An error occurred when fetching results: {e}")
            return None

    results = await nvim.loop.run_in_executor(None, executor)
    if results is None:
        return

    # TODO: potentially allow user to fetch only videos or only playlists
    results = [[format_result(i), i] for i in results.all]

    nvim.async_call(
        nvim.lua.neovimpv.open_select_split,
        results,
        "youtube_results",
        5
    )

async def open_playlist_results(nvim, playlist, extra):
    '''Scrape playlist page and pass results to Lua'''
    # don't block the event loop while waiting for results
    def executor():
        try:
            return YoutubePlaylist.get_all(playlist["playlist_id"])
        except urllib.error.HTTPError as e:
            nvim.show_error(f"An error occurred when fetching results: {e}")
            return None

    results = await nvim.loop.run_in_executor(None, executor)
    if results is None:
        return

    nvim.async_call(
        nvim.lua.neovimpv.open_playlist_results,
        results.contents,
        extra
    )
