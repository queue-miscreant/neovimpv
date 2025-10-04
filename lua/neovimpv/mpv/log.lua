local log_handle = assert(io.open(vim.fn.stdpath("log") .. "/neovimpv.log", "a+"))

local function write_log(s, ...)
  local args = {...}
  for i, j in ipairs(args) do
    if type(j) == "table" then
      args[i] = vim.inspect(j)
    end
  end
  log_handle:write(s:format(unpack(args)) .. "\n")
  log_handle:flush()
end

return {
  info = write_log,
  error = write_log,
  debug = write_log,
}
