---@meta

---@alias UpdateAction "stay" | "paste" | "paste_one" | "new_one"

---@alias DisplayStyle "ligature" | "unicode" | "emoji"

---@alias Highlight string Vim highlight type

---@alias VirtText [string, Highlight][]

---@alias GetExtmark [integer, integer, integer]

---@class FormatterField
---@field name string
---@field handler fun(field_name: any): string

---@class Formatter
---@field pattern string
---@field fields (FormatterField | [string, string])[]
---@field render fun(self: Formatter, input_dict: table<string, any>): string

---@class ExtmarkArgs
---@field id integer
---@field virt_text? VirtText
---@field virt_text_pos string

---@class PasteContent
---@field link string
---@field markdown string
