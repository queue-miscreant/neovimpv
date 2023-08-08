import html
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

YOUTUBE_RENDERER_PATHS = {
    "thumbnail": ["thumbnail", "thumbnails", 0, "url"],
    "title": ["title", "runs", 0, "text"],
    "video_id": ["videoId"],
    "length": ["lengthText", "simpleText"],
    "views": ["viewCountText", "simpleText"],
    "channel_name": ["longBylineText", "runs", 0, "text"],
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

def parse_video_renderer(renderer):
    '''
    Transform a video JSON from the YouTube search page (pared down by
    YoutubeResults.CONTENTS_PATH) into a dict with the same keys as
    YOUTUBE_RENDERER_PATHS with values from the page.
    '''
    ret = {}
    for name, path in YOUTUBE_RENDERER_PATHS.items():
        ret[name] = try_follow_path(renderer, path)
    ret["link"] = f"https://youtu.be/{ret['video_id']}"
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
        videos = [parse_video_renderer(i) for i in (
            result.get("videoRenderer") for result in video_results
        ) if i]

        # TODO: playlists... eventually?
        self.videos = videos

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

async def open_mpv_buffer(nvim, youtube_query):
    '''Don't block the event loop while waiting for results'''
    def executor():
        try:
            return YoutubeResults.get_all(youtube_query)
        except urllib.error.HTTPError as e:
            nvim.show_error(f"An error occurred when fetching results: {e}")
            return None

    results = await nvim.loop.run_in_executor(None, executor)
    if results is None:
        return

    videos = [[i["title"], i] for i in results.videos]

    # nvim.async_call(
        # nvim.lua.neovimpv.open_select_split,
    nvim.lua.neovimpv.open_select_split(
        videos,
        "youtube_results",
        5
    )
