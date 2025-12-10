-- Build/deploy pipeline menu (see lua/user/builddeploy.lua and
-- bash/build_deploy.sh). Kept in its own file so core.lua stays untouched.
local ok, bd = pcall(require, 'user.builddeploy')
if not ok then
    return
end

vim.keymap.set('n', '<leader>bp', bd.open, { desc = '[B]uild/deploy [P]ipeline menu' })
