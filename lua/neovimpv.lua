-- Update an extmark's content without changing its row or column
local function update_extmark(buffer, namespace, extmark_id, content)
  loc = vim.api.nvim_buf_get_extmark_by_id(buffer, namespace, extmark_id, {})
  if loc ~= nil then
    vim.api.nvim_buf_set_extmark(buffer, namespace, loc[1], loc[2], content)
  end
end

neovimpv = {update_extmark=update_extmark}
