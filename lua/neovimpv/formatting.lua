-- neovimpv/formatting.lua
--
-- Features for converting mpv data into highlight string pairs, drawable in extmarks.

local config = require "neovimpv.config"

local formatting = {}

---@alias display_style "ligature" | "unicode" | "emoji"

---@alias highlight string

---@alias virt_text [string, highlight][]

---@class FormatterField
---@field name string
---@field handler fun(field_name: any): string

---@class Formatter
---@field pattern string
---@field fields (FormatterField | [string, string])[]
---@field render fun(self: Formatter, input_dict: {[string]: any}): string

---@type display_style
local DEFAULT_STYLE = "unicode"

--- Dict of static display styles.
--- Exact values (as table entries) are converted to a string-highlight pair
---@type {[display_style]: {[string]: {[any]: [string, highlight]}}}
local DISPLAY_STYLES = {
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
}

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

local DEFAULT_HANDLERS = {
  ["playback-time"] = format_time,
  ["duration"] = format_time,
  ["loop"] = format_loop,
}


local format_settings = {
  display_style = DISPLAY_STYLES[DEFAULT_STYLE],
  handlers = vim.deepcopy(DEFAULT_HANDLERS),
  fields = {},
}
formatting.settings = format_settings

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

--- Bind new highlights, if necessary
---@param highlights highlight[]
local function bind_new_highlights(highlights)
  for _, highlight in pairs(highlights) do
    if vim.fn.hlexists(highlight) == 0 then
      vim.cmd("highlight default link " .. highlight .. " MpvDefault")
    end
  end
end

---@param thresholds_table {[string]: [any]|[any, any]}
function formatting.compile_thresholds(thresholds_table)
  local new_handlers = {}
  local new_highlights = {}

  -- special properties first (like pause)
  for _, field in pairs(format_settings.display_style) do
    for _, formatter in pairs(field) do
      new_highlights[formatter[2]] = true
    end
  end

  -- user thresholds
  for property_name, thresh_list in pairs(thresholds_table) do
    local camel = kebab_to_camel(property_name)
    if #thresh_list == 1 then
      local low_thresh = thresh_list[1]

      -- TODO check whether binding thresh_list gives the proper value!
      new_handlers[property_name] = function(x)
          return (x > low_thresh) and "High" or "Low"
      end

      new_highlights["Mpv" .. property_name .. "Low"] = true
      new_highlights["Mpv" .. property_name .. "High"] = true

    elseif #thresh_list == 2 then
      local low_thresh, mid_thresh = unpack(thresh_list) ---@diagnostic disable-line

      -- TODO check whether binding thresh_list gives the proper value!
      new_handlers[property_name] = function(x)
        return (x > mid_thresh)
          and "High"
          or ((x > low_thresh) and "Middle" or "Low")
      end

      new_highlights["Mpv" .. camel .. "Low"] = true
      new_highlights["Mpv" .. camel .. "Middle"] = true
      new_highlights["Mpv" .. camel .. "High"] = true
    else
      error("Cannot interpret user threshold for property " .. property_name)
    end
  end

  bind_new_highlights(vim.tbl_keys(new_highlights))

  format_settings.handlers = vim.tbl_extend(
    "keep",
    vim.deepcopy(DEFAULT_HANDLERS),
    new_handlers
  )

  local handler_highlights = {}
  for field, _ in pairs(DEFAULT_HANDLERS) do
    table.insert(handler_highlights, "Mpv" .. kebab_to_camel(field))
  end
  bind_new_highlights(handler_highlights)
end

---@param format_string string
function formatting.compile(format_string)
  ---@type (FormatterField | [string, highlight])[]
  local fields = {}

  for match, post in format_string:gmatch("([^}]+)}([^{]*)") do
    -- vim.print{match, foo}
    for pre, field_name in match:gmatch("([^{]*){(.+)") do

      if pre ~= "" then
        table.insert(
          fields,
          { pre, "MpvDefault" }
        )
      end

      local default_handler = tostring
      local try_styled = format_settings.display_style[field_name]
      if format_settings.display_style[field_name] then
        default_handler = function(val) return try_styled[val] or "" end
      end

      local try_handler = format_settings.handlers[field_name]
      local camel_field = "Mpv" .. kebab_to_camel(field_name)
      table.insert(
        fields,
        {
          name = field_name,
          handler = try_handler and function(val)
            return { try_handler(val), camel_field }
          end or default_handler,
        } --[[@as FormatterField]]
      )

      if post ~= "" then
        table.insert(
          fields,
          { post, "MpvDefault" }
        )
      end
    end
  end

  format_settings.fields = fields

  -- mpv groups for Python to be aware of
  formatting.mpv_properties = vim.tbl_values(
    vim.tbl_map(
      function(field) return field.name end,
      fields
    )
  )
end

function formatting.parse_user_settings()
  formatting.settings.display_style = DISPLAY_STYLES[
    config.style or DEFAULT_STYLE
  ]
  formatting.compile_thresholds(config.property_thresholds)
  formatting.compile(config.format)
end

---@param input_dict {[string]: any}
---@return virt_text
function formatting.render(input_dict)
  return vim.tbl_map(
    function(field)
      if field.handler == nil then return field end
      return field.handler(input_dict[field.name]) or { "", "MpvDefault" }
    end,
    format_settings.fields
  )
end

return formatting
