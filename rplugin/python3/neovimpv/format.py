import json
import copy
import itertools
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

NVIM_VAR_LOADING = "mpv_loading"
NVIM_VAR_FORMAT = "mpv_format"
NVIM_CHARACTER_STYLE = "mpv_style"
NVIM_VAR_DEFAULT_HIGHLIGHT = "mpv_default_highlight"
NVIM_VAR_HIGHLIGHTS = "mpv_highlights"

DISPLAY_STYLES = {
    "ligature": {
        "pause": {
            False: "|>",
            True: "||",
        },
    },
    "unicode": {
        "pause": {
            False: "►",
            True: "⏸",
        },
    },
    "emoji": {
        "pause": {
            False: "▶️ ",
            True: "⏸️ ",
        },
    }
}

CURRENT_SCHEME = DISPLAY_STYLES.get("unicode")

def try_json(arg):
    '''Attempt to read arg as a JSON object. Return the string on failure'''
    try:
        return json.loads(arg)
    except:
        return arg

def sexagesimalize(number):
    '''Convert a number to decimal-coded sexagesimal (i.e., clock format)'''
    seconds = int(number)
    minutes = seconds // 60
    hours = minutes // 60
    if hours:
        return f"{(hours % 60):0{2}}:{(minutes % 60):0{2}}:{(seconds % 60):0{2}}"
    else:
        return f"{(minutes % 60)}:{(seconds % 60):0{2}}"

def format_pause(is_paused):
    return CURRENT_SCHEME["pause"].get(is_paused, "?")

def format_time(position):
    return sexagesimalize(position or 0)

def format_loop(loop):
    if loop == "inf":
        loop = "∞"
    if loop:
        return f"({loop})"

class Formatter:
    '''
    Class for storing how to format the end-of-line extmark for mpv instances.
    The format string can be specified using g:mpv_format, which is a string
    with mpv property names enclosed in {}.

    By default, properties retrieved from mpv are drawn as their string
    representation. Special properties, such as `duration` and `playback-time`
    are drawn using entries in HANDLERS.

    The default highlight used can be configured with g:mpv_default_highlight.

    Further detail for mpv properties can be specified using g:mpv_highlights,
    which is a dict which has mpv properties as keys and highlights as values.
    The keys may also be an mpv property and a value, separated by an "@", if
    you would like (discrete) values to be displayed in different colors
    (i.e., ```{ "pause@false": ... }```).
    '''
    HANDLERS = {
        "pause": format_pause,
        "playback-time": format_time,
        "duration": format_time,
        "loop": format_loop,
    }

    HIGHLIGHT_DEFAULTS = {
        "pause": {
            True: "Conceal",
            False: "Title",
        },
        "playback-time": "Conceal",
        "duration": "Conceal",
    }

    def __init__(self, nvim):
        global CURRENT_SCHEME
        scheme = nvim.api.get_var(NVIM_CHARACTER_STYLE)
        format = nvim.api.get_var(NVIM_VAR_FORMAT)
        highlights = nvim.api.get_var(NVIM_VAR_HIGHLIGHTS)

        self._default_highlight = nvim.api.get_var(NVIM_VAR_DEFAULT_HIGHLIGHT)
        self.loading = [nvim.api.get_var(NVIM_VAR_LOADING), self._default_highlight]
        CURRENT_SCHEME = DISPLAY_STYLES.get(scheme, CURRENT_SCHEME)

        self.groups = []
        self._format_string = ""
        self._highlight_fields = {}

        self.parse_highlights(highlights)
        self.compile_format(format)

    def parse_highlights(self, highlights):
        '''Parse @-separated dict entries into further dicts'''
        fields = copy.deepcopy(self.HIGHLIGHT_DEFAULTS)
        # parse field@value 
        for field, highlight in itertools.chain(highlights.items()):
            try_split = field.split("@")
            if len(try_split) == 2:
                if fields.get(try_split[0]) is None:
                    fields[try_split[0]] = {}
                fields[try_split[0]][try_json(try_split[1])] = highlight
                continue
            fields[field] = highlight
        self._highlight_fields = fields

    def compile_format(self, format: str):
        '''Compile format string into a list of lambdas ready to receive a data dict'''
        groups = set()
        pre_formatted = []

        splits = format.split("}")
        try:
            for i, split in enumerate(splits):
                pre, group = "", ""
                if i == len(splits) - 1:
                    pre = split
                else:
                    pre, group = split.split("{")
                if pre:
                    pre_formatted.append([pre, lambda x, _: [x, self._default_highlight]])
                if group:
                    pre_formatted.append(self._format(
                        group,
                        self._highlight_fields.get(group, self._default_highlight)
                    ))
                    groups.add(group)
        except ValueError as e:
            pass

        self._pre_formatted = pre_formatted
        self.groups = list(groups)

    def _format(self, item, highlight_field):
        '''Bind the property `item` to a handler lambda'''
        # Try to find a way to draw this
        formatter = self.HANDLERS.get(item, str)
        highlighter = lambda x: highlight_field
        # If highlight_field is a dict, use the value of the field to determine highlight color
        if isinstance(highlight_field, dict):
            highlighter = lambda x: highlight_field.get(x, self._default_highlight)
        return [item, lambda x, data: [
            formatter(data.get(x, "")),     # the text itself
            highlighter(data.get(x, ""))    # its highlight
        ]]

    def format(self, format_dict):
        '''
        Return a list of string/highlight 2-arrays for use by set_extmark.
        If a handler returns a falsy value, the item is omitted.
        '''
        return [k for k in (j(i, format_dict) for i, j in self._pre_formatted) if k[0]]
