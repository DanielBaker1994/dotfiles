-- Build/deploy pipeline menu (see lua/user/builddeploy.lua; the script is
-- $BUILD_DEPLOY_SHELL_SCRIPT_PATH). Kept in its own file so core.lua stays untouched.
local ok, bd = pcall(require, 'user.builddeploy')
if not ok then
    return
end

vim.keymap.set('n', '<leader>bp', bd.open, { desc = '[B]uild/deploy [P]ipeline menu' })
