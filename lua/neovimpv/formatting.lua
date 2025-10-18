-- neovimpv/formatter.lua
--
-- Features for converting mpv data into highlight string pairs, drawable in extmarks.

local tbl_map = vim.tbl_map

-- To format text, we need to know a few things:
-- - The properties from mpv
-- - How to draw the property as a string (e.g., converting `100` to "1:40" for times)
-- - What highlight to use when drawing the property
--
-- To be configurable, the user should be able to provide:
-- - A `tostring`-like function to convert the value to a string
-- - A threshold value (or two), to control the highlight used
-- - Whether or not to use the default value

---@alias MpvProperty string

---Least "high" value (1-tuple form) or least "mid" and "high" values (2-tuple form).
---@alias PropertyThresholds [integer]|[integer, integer]
---`tostring`-like function
---@alias PropertyStringifier (fun(value: any): string)
---Formatter function, with automatic highlight binding
---@alias PropertyFormatter {formatter: PropertyStringifier, threshold?: PropertyThresholds}
---Formatter lookup, with "manual" highlight names, but automatic binding
---@alias PropertyFormatterLookup table<any, VirtText>
---Formatter function, with manual highlight and highlight binding
---@alias PropertyFormatterFunction fun(value: any): VirtText

---Any user-provided configuration, minus default lookups
---@alias NondefaultedFormatter (PropertyFormatterLookup | PropertyFormatter | PropertyFormatterFunction)?
---Formatter configuration, as supplied as by a user in their config
---@alias FormatterConfig table<MpvProperty, string | NondefaultedFormatter>

---"Cooked" table consisting only of maps to functions suitable for rendering
---@alias RendererPropertyLookup table<MpvProperty, PropertyFormatterFunction>

---Wrapper object for the name of the mpv property to extract and the handler function to draw it
---@alias RendererItem {name: MpvProperty, handler: PropertyFormatterFunction}
---Map from mpv fields to either static values or stringifying function on the value.
---@alias RendererList (VirtText|RendererItem)[]

--- Convert a number to decimal-coded sexagesimal (i.e., clock format)
---@param number integer
---@return string
local function sexagesimalize(number)
  local seconds = tonumber(number) or 0
  local minutes = math.floor(seconds / 60)
  local hours = math.floor(minutes / 60)
  if hours > 0 then
    return ("%d:%02d:%02d"):format(
      hours % 60,
      minutes % 60,
      seconds % 60
    )
  else
    return ("%d:%02d"):format(
      minutes % 60,
      seconds % 60
    )
  end
end

--- Convert numeric field to time string
---@param position number|nil
---@return string
local function format_time(position)
  return sexagesimalize(position or 0)
end

--- Convert loop parameter to string
---@param loop number|"inf"|nil
---@return string
local function format_loop(loop)
  return loop == "inf" and "∞"
    or (loop and tostring(loop) or "")
end

---@class Formatter
---@field mpv_properties string[] List of strings to watch on mpv processes.
---@field renderers RendererList List of renderers (VirtText or functions which produce them) for Formatter:render()
local Formatter = {
  ---@type table<DisplayStyle, table<MpvProperty, NondefaultedFormatter>>
  DEFAULT_HANDLERS = {
    --- Dicts of static display styles.
    --- Exact values (as table entries) are converted to a string-highlight pair
    ligature = {
      pause = {
        [true] = {"||", "MpvPauseTrue"},
        [false] = {"|>", "MpvPauseFalse"},
      }
    },
    unicode = {
      pause = {
        [true] = {"⏸", "MpvPauseTrue"},
        [false] = {"►", "MpvPauseFalse"},
      }
    },
    emoji = {
      pause = {
        [true] = {"⏸️", "MpvPauseTrue"},
        [false] = {"▶️", "MpvPauseFalse"},
      }
    },
    any = {
      ["playback-time"] = { formatter = format_time },
      ["duration"] = { formatter = format_time },
      ["loop"] = { formatter = format_loop },
--[[
      ["mpv-property1"] = "default-name",     -- access DEFAULT_HANDLERS["default-name"] or DEFAULT_HANDLERS.any
      ["mpv-property2"] = {
        formatter = tostring,                 -- converter function with automatic highlight selection
        threshold = { 0, 5 },                 -- optional automatic thresholds
      },
      ["mpv-property3"] = function(value)
        return { tostring(value), "HighlightToUse" }  -- converter function with manual highlight
      end,
]]
    },
  }
}
Formatter.__index = Formatter

--- kebab-case to CamelCase converter, for converting Mpv fields to highlight names
---@param str string
---@return string
local function kebab_to_camel(str)
  local camel = ""
  for _, name in pairs(vim.split(str, "-")) do
    camel = camel .. name:sub(1, 1):upper() .. name:sub(2)
  end
  return camel
end

local function bind_highlight(highlight)
  if vim.fn.hlexists(highlight) == 0 then
    vim.cmd("highlight default link " .. highlight .. " MpvDefault")
  end
end

---@param highlight_name Highlight
---@param config PropertyFormatter
---@return PropertyFormatterFunction
local function compile_threshold_property(highlight_name, config)
  local new_highlights = {}
  local low_thresh, mid_thresh = unpack(config.threshold or {})

  ---@type fun(value?: any): Highlight
  local highlighter = function() return highlight_name end

  -- Create threshold functions
  if low_thresh and mid_thresh then
    highlighter = function(x)
      return highlight_name .. (
        (x > mid_thresh) and "High"
        or ((x > low_thresh) and "Middle" or "Low")
      )
    end

    new_highlights[highlight_name .. "Low"] = true
    new_highlights[highlight_name .. "Middle"] = true
    new_highlights[highlight_name .. "High"] = true
  elseif low_thresh then
    highlighter = function(x)
      return highlight_name .. ((x > low_thresh) and "High" or "Low")
    end

    new_highlights[highlight_name .. "Low"] = true
    new_highlights[highlight_name .. "High"] = true
  end

  --- Bind new highlights, if necessary
  for highlight, _ in pairs(new_highlights) do
    bind_highlight(highlight)
  end

  local formatter = config.formatter
  return function(value)
    return { formatter(value), highlighter(value) }
  end
end

---Compile a table of formatters into handlers for the mpv rendering
---@param formatter_config FormatterConfig Formatting configuration
---@return table<MpvProperty, PropertyFormatterFunction>
local function compile_formatter_config(formatter_config)
  ---@type table<MpvProperty, PropertyFormatterFunction>
  local ret = {}

  for mpv_property, config in pairs(formatter_config) do
    local highlight_name = "Mpv" .. kebab_to_camel(mpv_property)

    if type(config) == "string" then
      config = (
        (Formatter.DEFAULT_HANDLERS[config] or {})[mpv_property]
        or (Formatter.DEFAULT_HANDLERS.any or {})[mpv_property]
      ) --[[@as NondefaultedFormatter? ]]
    end

    if type(config) == "function" then
      -- Raw formatter
      ---@cast config PropertyFormatterFunction
      ret[mpv_property] = config
    elseif config and config.formatter then
      -- Formatter with (maybe) threshold
      ---@cast config PropertyFormatter
      ret[mpv_property] = compile_threshold_property(highlight_name, config)
    elseif type(config) == "table" then
      -- Lookup table
      ---@cast config PropertyFormatterLookup
      ret[mpv_property] = function(value)
        return config[value]
      end
    end
  end

  return ret
end



---@alias FormatterTable table<string, fun(value: any): string>
---
---@alias HighlightSuffixTable table<string, fun(value: number): string>


---Compile a format string to a table that can be used for rendering.
---@private
---@param format_string string
---@return RendererList, MpvProperty[]
function Formatter.compile(format_string)
  ---@type RendererList
  local renderers = {}
  ---@type table<Highlight, boolean>
  local new_highlights = {}
  ---@type MpvProperty[]
  local mpv_properties = {}

  for match, post in format_string:gmatch("([^}]+)}([^{]*)") do
    -- vim.print{match, foo}
    for pre, field_name in match:gmatch("([^{]*){(.+)") do

      if pre ~= "" then
        table.insert(
          renderers,
          { pre, "MpvDefault" }
        )
      end

      local highlight_name = "Mpv" .. kebab_to_camel(field_name)
      new_highlights[highlight_name] = true

      table.insert(renderers, {
        name = field_name,
        handler = function(value)
          return { tostring(value), highlight_name }
        end,
      })
      table.insert(mpv_properties, field_name)

      if post ~= "" then
        table.insert(
          renderers,
          { post, "MpvDefault" }
        )
      end
    end
  end

  --- Bind new highlights, if necessary
  for highlight, _ in pairs(new_highlights) do
    bind_highlight(highlight)
  end

  -- mpv groups to be aware of
  return renderers, mpv_properties
end

---@param format_string string
---@param extra_format? FormatterConfig | DisplayStyle
---@return Formatter
function Formatter.new(format_string, extra_format)

  -- Extract mpv properties and build default renderers
  local renderers, mpv_properties = Formatter.compile(format_string)

  ---@type FormatterConfig
  local formatter_config = {}
  if type(extra_format) == "string" then
    for _, mpv_property in ipairs(mpv_properties) do
      formatter_config[mpv_property] = extra_format --[[@as DisplayStyle]]
    end
  else
    formatter_config = extra_format --[[@as FormatterConfig]]
  end
  local handlers = compile_formatter_config(formatter_config)

  -- Update renderers, if we can
  for _, renderer in ipairs(renderers) do
    local maybe_handler = handlers[renderer.name]
    if maybe_handler then
      ---@cast renderer RendererItem
      renderer.handler = maybe_handler
    end
  end

  local ret = {
    mpv_properties = mpv_properties,
    renderers = renderers,
  }
  setmetatable(ret, Formatter)

  return ret
end

---@param input_dict table<MpvProperty, any>
---@return VirtText[]
function Formatter:render(input_dict)

  if input_dict["video-format"] ~= nil then
    return {{"[ Window ]", "MpvDefault"}}
  end

  return tbl_map(
    ---@param field VirtText | RendererItem
    ---@return VirtText
    function(field)
      if field.handler == nil then return field end
      return field.handler(input_dict[field.name]) or { "", "MpvDefault" }
    end,
    self.renderers
  )
end

return Formatter
