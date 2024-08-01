"""
neovimpv.format

Formatters for converting data from mpv into display data for extmarks.
"""

import logging

log = logging.getLogger(__name__)

NVIM_VAR_LOADING = "mpv_loading"
NVIM_VAR_FORMAT = "mpv_format"
NVIM_CHARACTER_STYLE = "mpv_style"
NVIM_VAR_DEFAULTED_HIGHLIGHTS = "mpv_defaulted_highlights"
NVIM_VAR_THRESHOLDS = "mpv_property_thresholds"

DISPLAY_STYLES = {
    "ligature": {
        "MpvPauseFalse": "|>",
        "MpvPauseTrue": "||",
    },
    "unicode": {
        "MpvPauseFalse": "►",
        "MpvPauseTrue": "⏸",
    },
    "emoji": {
        "MpvPauseFalse": "▶️ ",
        "MpvPauseTrue": "⏸️ ",
    },
}

# For these props, just append the string value to the end of them to the "base"
# i.e., for "pause", "MpvPauseFalse"
SPECIAL_PROPS = {
    "pause": {
        "converter": lambda x: str(bool(x)),
        "suffixes": ["True", "False"],
    }
}

DEFAULT_SCHEME = DISPLAY_STYLES.get("unicode", {})


def parse_thresholds(thresholds):
    """Parse compiled groups into highlight suffixes, adding thresholds for special properties"""
    new_thresholds = {}
    new_groups = {}
    # special properties first (like pause)
    for prop, info in SPECIAL_PROPS.items():
        new_thresholds[prop] = info["converter"]
        new_groups[prop] = info["suffixes"]
    # user thresholds
    for threshold, thresh_list in thresholds.items():
        if len(thresh_list) == 1:
            (low_thresh,) = thresh_list
            new_thresholds[threshold] = lambda x: (
                "Low" if x < low_thresh else "High"
            )
            new_groups[threshold] = ["Low", "High"]
        elif len(thresh_list) == 2:
            low_thresh, mid_thresh = thresh_list
            new_thresholds[threshold] = lambda x: (
                ("Low" if x < low_thresh else "Middle")
                if x < mid_thresh
                else "High"
            )
            new_groups[threshold] = ["Low", "Middle", "High"]
        else:
            raise ValueError(f"Cannot interpret user threshold {threshold}")
    return new_thresholds, new_groups


def sexagesimalize(number):
    """Convert a number to decimal-coded sexagesimal (i.e., clock format)"""
    seconds = int(number)
    minutes = seconds // 60
    hours = minutes // 60
    if hours:
        return f"{(hours % 60):0{2}}:{(minutes % 60):0{2}}:{(seconds % 60):0{2}}"
    else:
        return f"{(minutes % 60)}:{(seconds % 60):0{2}}"


def format_time(position):
    return sexagesimalize(position or 0)


def format_loop(loop):
    return "" if not loop else f"({('∞' if loop == 'inf' else loop)})"


def kebab_to_camel(string):
    """Turn kebab-case string into CamelCase string"""
    return "".join([name.capitalize() for name in string.split("-")])


class Formatter:
    """
    Class for storing how to format the end-of-line extmark for mpv instances.
    The format string can be specified using g:mpv_format, which is a string
    with mpv property names enclosed in {}.

    The highlight used to draw an mpv format `format-name` will be
    `MpvFormatName`. By default, these link to the highlight `MpvDefault`.
    Threshold values may be established with the g:mpv_property_thresholds
    variable.
    """

    HIGHLIGHT_DEFAULTS = {
        "pause": {
            True: "Conceal",
            False: "Title",
        },
        "playback-time": "Conceal",
        "duration": "Conceal",
    }

    def __init__(self, nvim):
        format = nvim.api.get_var(NVIM_VAR_FORMAT)  # user format
        scheme = nvim.api.get_var(NVIM_CHARACTER_STYLE)  # user display scheme

        self._scheme = DISPLAY_STYLES.get(scheme, DEFAULT_SCHEME)

        self._defaulted_highlights = nvim.api.get_var(
            NVIM_VAR_DEFAULTED_HIGHLIGHTS
        )  # highlights which don't need a default set
        thresholds = nvim.api.get_var(NVIM_VAR_THRESHOLDS)  # user thresholds

        # groups parsed by the format
        self.groups = []
        # threshold callbacks
        self._thresholds = {}

        self._handlers = {
            "pause": self.format_pause,
            "playback-time": format_time,
            "duration": format_time,
            "loop": format_loop,
        }

        self._thresholds, new_groups = parse_thresholds(thresholds)
        self.compile_format(format)
        self.bind_default_highlights(nvim, new_groups)

    def bind_default_highlights(self, nvim, new_groups):
        """Bind default highlights for all mpv properties as thresholds and in the format string"""
        for group in self.groups:
            if group in new_groups:
                continue
            new_groups[group] = [""]

        new_highlights = []
        for group, suffixes in new_groups.items():
            base_highlight = "Mpv" + kebab_to_camel(group)
            for suffix in suffixes:
                highlight_name = base_highlight + suffix
                if highlight_name not in self._defaulted_highlights:
                    new_highlights.append(highlight_name)
        # in case no highlight exists, bind defaults for these
        nvim.lua.neovimpv.bind_default_highlights(new_highlights, "MpvDefault")
        self._defaulted_highlights.extend(new_highlights)

    def compile_format(self, format: str):
        """Compile format string into a list of lambdas ready to receive a data dict"""
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
                    pre_formatted.append([pre, lambda x, _: [x, "MpvDefault"]])
                if group:
                    pre_formatted.append(self._format(group))
                    groups.add(group)
        except ValueError:
            pass

        self._pre_formatted = pre_formatted
        self.groups = list(groups)

    def _format(self, item):
        """Bind the property `item` to a handler lambda"""
        # Try to find a way to draw this
        formatter = self._handlers.get(item, str)
        # thresholds include special fields like pause, as well as user-defined ones
        threshold = self._thresholds.get(item, lambda x: "")
        highlight_name = "Mpv" + kebab_to_camel(item)
        return [
            item,
            lambda x, data: [
                formatter(data.get(x, "")),
                highlight_name + threshold(data.get(x, 0)),
            ],
        ]

    def format(self, format_dict):
        """
        Return a list of string/highlight 2-arrays for use by set_extmark.
        If a handler returns a falsy value, the item is omitted.
        """
        return [k for k in (j(i, format_dict) for i, j in self._pre_formatted) if k[0]]


    def format_pause(self, is_paused):
        return self._scheme.get("MpvPause" + str(is_paused), "?")
