---@meta

---@alias DisplayStyle "ligature" | "unicode" | "emoji"

---@alias Highlight string

---@alias VirtText [string, Highlight][]

---@alias GetExtmark [integer, integer, integer]

---@class FormatterField
---@field name string
---@field handler fun(field_name: any): string

---@class Formatter
---@field pattern string
---@field fields (FormatterField | [string, string])[]
---@field render fun(self: Formatter, input_dict: {[string]: any}): string

---@class ExtmarkArgs
---@field id integer
---@field virt_text? VirtText
---@field virt_text_pos string
