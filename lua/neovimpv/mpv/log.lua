local log_handle = assert(io.open(vim.fn.stdpath("log") .. "/neovimpv.log", "a+"))

local function write_log(s, ...)
  local args = {...}
  for i, j in ipairs(args) do
    if type(j) == "table" then
      args[i] = vim.inspect(j)
    end
  end
  if type(s) == "table" then
    log_handle:write(vim.inspect(s) .. "\n")
  else
    log_handle:write(tostring(s):format(unpack(args)) .. "\n")
  end
  log_handle:flush()
end

return {
  info = write_log,
  error = write_log,
  debug = write_log,
}
