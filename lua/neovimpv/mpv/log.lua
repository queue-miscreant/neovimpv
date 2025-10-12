local log_handle = assert(io.open(vim.fn.stdpath("log") .. "/neovimpv.log", "a+"))

---@param tab table
local function log(tab)
  tab = vim.deepcopy(tab)
  local lines = ""
  for i, line in ipairs(tab) do
    lines = lines .. line .. "\n"
    table.remove(tab, i)
  end
  log_handle:write(vim.inspect(tab) .. "\n")
  log_handle:flush()
end

return {
  log = log,
}
