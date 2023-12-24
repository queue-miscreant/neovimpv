import json
import logging
import sys
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger(__name__)

WARN_LXML = False
try:
    import lxml.html
except ImportError:
    log.warning(f"No LXML detected. MpvYoutubeSearch will not work.")
    WARN_LXML = True

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

class YoutubeRenderer:
    VIDEO_RENDERER_PATHS = {
        "thumbnail": ["thumbnail", "thumbnails", 0, "url"],
        "title": ["title", "runs", 0, "text"],
        "video_id": ["videoId"],
        "length": ["lengthText", "simpleText"],
        "views": ["viewCountText", "simpleText"],
        "stream_badge": ["badges", 0, "metadataBadgeRenderer", "label"],
        "stream_views": ["viewCountText", "runs", 0, "text"],
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

    def __init__(self):
        raise ValueError(f"Attempted to instantiate {self.__class__}!")

    @classmethod
    def video(cls, renderer, paths=VIDEO_RENDERER_PATHS):
        '''
        Transform a video JSON from the YouTube search page (pared down by
        Youtube.CONTENTS_PATH) into a dict with the same keys as `paths`
        with values from the page.
        '''
        ret = parse_dict(renderer, paths)
        try:
            ret["link"] = f"https://youtu.be/{ret['video_id']}"
            ret["markdown"] = f"[{ret['title'].replace('[', '(').replace(']', ')')}]({ret['link']})"
        except KeyError:
            return None
        if ret.get("views") is None:
            views = "(Error getting views)"
            if (stream_views := ret.get("stream_views")) is not None:
                views = f"{stream_views} viewers"
            ret["views"] = views
        if ret.get("length") is None:
            length = "(Error getting length)"
            if (stream_badge := ret.get("stream_badge")) is not None:
                length = stream_badge
            ret["length"] = length
        log.debug("Successfully parsed video: %s", ret)
        return ret

    @classmethod
    def child_video(cls, renderer):
        return cls.video(renderer, cls.CHILD_VIDEO_RENDERER_PATHS)

    @classmethod
    def playlist_video(cls, renderer):
        return cls.video(renderer, cls.PLAYLIST_VIDEO_RENDERER_PATHS)

    @classmethod
    def playlist(cls, renderer):
        '''
        Transform a playlist JSON from the YouTube search page (pared down by
        Youtube.CONTENTS_PATH) into a dict with the same keys as
        PLAYLIST_RENDERER_PATHS with values from the page.
        '''
        ret = parse_dict(renderer, cls.PLAYLIST_RENDERER_PATHS)
        # parse the child videos that display for a playlist
        try:
            ret["videos"] = [i for i in (
                cls.child_video(video.get("childVideoRenderer"))
                for video in ret["raw_videos"]
            ) if i]
            ret["link"] = f"https://youtube.com/playlist?list={ret['playlist_id']}"
            ret["markdown"] = f"[{ret['title'].replace('[', '(').replace(']', ')')}]({ret['link']})"
            del ret["raw_videos"]
        except KeyError:
            return None
        log.debug("Successfully parsed playlist: %s", ret)
        return ret

class Youtube:
    '''
    Class containing methods related to curling YouTube pages.
    Pray that they don't change the page layout at some point in the future.
    '''
    # script tag with response should contain this object to start with
    SCRIPT_SENTINEL = "var ytInitialData = "
    RESULTS_CONTENTS_PATH = [
        "contents",
        "twoColumnSearchResultsRenderer",
        "primaryContents",
        "sectionListRenderer",
        "contents",
        0,
        "itemSectionRenderer",
        "contents"
    ]
    RESULTS_URL = "https://www.youtube.com/results?search_query={query}"
    PLAYLIST_CONTENTS_PATH = [
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
    PLAYLIST_URL = "https://www.youtube.com/playlist?list={playlist_id}"

    def __init__(self):
        raise ValueError(f"Attempted to instantiate {self.__class__}!")

    @classmethod
    def _extract_youtube_response(cls, response):
        '''Extract JSON from curl of YouTube results page'''
        log.debug("Parsing YouTube response...")
        parser = lxml.html.HTMLParser(encoding="utf-8")
        parsed = lxml.html.fromstring(response, parser=parser)
        for tag in parsed.iter("script"):
            content = tag.text_content()
            if not isinstance(content, str) \
            or not content.startswith(cls.SCRIPT_SENTINEL):
                continue
            # this script defines a single variable and has a trailing semicolon
            log.debug(f"Found script with {repr(cls.SCRIPT_SENTINEL)}!")
            return json.loads(content[len(cls.SCRIPT_SENTINEL):-1])
        return None

    @classmethod
    def _get_init_data(cls, url):
        '''Run youtube curl and parse result'''
        log.debug(f"Curling {url}...")
        with urllib.request.urlopen(url) as a:
            return cls._extract_youtube_response(a.read())

    @classmethod
    def _search(cls, query):
        results = cls._get_init_data(
            cls.RESULTS_URL.format(query=urllib.parse.quote(query))
        )
        return try_follow_path(results, cls.RESULTS_CONTENTS_PATH) or []

    @classmethod
    def _playlist(cls, playlist_id):
        results = cls._get_init_data(
            cls.PLAYLIST_URL.format(playlist_id=urllib.parse.quote(playlist_id))
        )
        return try_follow_path(results, cls.PLAYLIST_CONTENTS_PATH) or []

    @classmethod
    def search(cls, query, raw=False):
        results = cls._search(query)
        if raw:
            return results
        videos = [i for i in (
            YoutubeRenderer.video(result.get("videoRenderer"))
            for result in results
        ) if i]
        playlists = [i for i in (
            YoutubeRenderer.playlist(result.get("playlistRenderer"))
            for result in results
        ) if i]
        all = [i for i in (
               YoutubeRenderer.video(result.get("videoRenderer")) or
               YoutubeRenderer.playlist(result.get("playlistRenderer"))
               for result in results
           ) if i]

        return {
            "videos": videos,
            "playlists": playlists,
            "all": all
        }

    @classmethod
    def playlist(cls, query):
        results = cls._playlist(query)
        playlist_items = [i for i in (
            YoutubeRenderer.playlist_video(result.get("playlistVideoRenderer"))
            for result in results
        ) if i]

        return playlist_items

def format_result(result):
    ret = result["title"]
    if result.get("playlist_id") is not None:
        ret = "☰ " + ret # clearly, playlists are heavenly
    return ret

async def open_results_buffer(nvim, youtube_query, old_window):
    '''Run search query in YouTube, then pass scraped results to Lua'''
    # don't block the event loop while waiting for results
    def executor():
        try:
            return Youtube.search(youtube_query)
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            nvim.show_error(f"An error occurred when fetching results: {e}")
            log.error(f"An error occurred when fetching results: {e}", stack_info=True)
            return None

    results = await nvim.loop.run_in_executor(None, executor)
    if results is None:
        return

    # TODO: potentially allow user to fetch only videos or only playlists
    results = [[format_result(i), i] for i in results["all"]]

    nvim.async_call(
        lambda x,y,z,w: nvim.lua.neovimpv.open_select_split(x,y,z,w),
        results,
        "youtube_results",
        old_window,
        5
    )

async def open_first_result(nvim, youtube_query, old_window):
    '''Run search query in YouTube, then pass scraped results to Lua'''
    def executor():
        try:
            return Youtube.search(youtube_query)
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            nvim.show_error(f"An error occurred when fetching results: {e}")
            log.error(f"An error occurred when fetching results: {e}", stack_info=True)
            return None

    results = await nvim.loop.run_in_executor(None, executor)
    if results is None:
        return

    if len(results["all"]) == 0:
        return

    def open_result():
        nvim.lua.neovimpv.paste_result(results["all"][0]["link"], old_window, True)
        nvim.api.command("MpvOpen")
    nvim.async_call(open_result)

async def open_playlist_results(nvim, playlist, extra):
    '''Scrape playlist page and pass results to Lua'''
    # don't block the event loop while waiting for results
    def executor():
        try:
            return Youtube.playlist(playlist["playlist_id"])
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            nvim.show_error(f"An error occurred when fetching results: {e}")
            log.error(f"An error occurred when fetching results: {e}", stack_info=True)
            return None

    results = await nvim.loop.run_in_executor(None, executor)
    if results is None:
        return

    nvim.async_call(
        lambda x,y: nvim.lua.neovimpv.open_playlist_results(x,y),
        results,
        extra
    )

if __name__ == "__main__":
    import sys
    print(json.dumps(Youtube.search(sys.argv[1], sys.argv[2] == "--raw" if len(sys.argv) > 2 else False)))
