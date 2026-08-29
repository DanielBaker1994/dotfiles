-- :Jira command (see lua/user/jira.lua). Kept in its own file so core.lua
-- stays untouched, matching the builddeploy pattern.
local ok, jira = pcall(require, 'user.jira')
if not ok then
    return
end

vim.api.nvim_create_user_command('Jira', jira.open, {
    desc = 'Open the current branch\'s Jira ticket in Chrome',
})