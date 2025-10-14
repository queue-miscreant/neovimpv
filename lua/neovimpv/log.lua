local log_handle = assert(io.open(vim.fn.stdpath("log") .. "/neovimpv.log", "a+"))

---@class Log
local Log = {}
Log.__index = Log

---@param disabled? boolean
function Log.new(disabled)
  return setmetatable({ disabled = not not disabled }, Log)
end

---@param self table
---@param tab? table
function Log.log(self, tab)
  if getmetatable(self) == Log then
    if self.disabled then return end
    tab = tab or {}
  else
    tab = self
  end

  tab = vim.deepcopy(tab)
  local lines = ""
  for i, line in ipairs(tab) do
    lines = lines .. tostring(line) .. "\n"
    table.remove(tab, i)
  end
  log_handle:write(lines .. vim.inspect(tab) .. "\n")
  log_handle:flush()
end

return Log
