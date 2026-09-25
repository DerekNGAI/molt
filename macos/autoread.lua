-- Drop into ~/.config/nvim/lua/config/autoread.lua
-- and require it from lazyvim extras / config/options.
-- Mutagen writes land on disk; nvim must notice them.

vim.opt.autoread = true
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
  callback = function()
    if vim.fn.mode() ~= "c" then
      vim.cmd("checktime")
    end
  end,
})
