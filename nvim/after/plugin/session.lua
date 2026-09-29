-- Automatic, worktree-root-scoped session management (see lua/user/session.lua).
-- The session is keyed on the workspace resolved from the launch dir
-- (user.workspace): a root/<prefix>-* worktree (e.g. ~/jira/JT-1234) or a
-- configured root; :cd inside nvim doesn't change it.
local session = require('user.session')
local workspace = require('user.workspace')

session.setup()

-- Prompt once at startup if the machine-local Jira prefix file is missing.
vim.schedule(function()
    workspace.ensure_jira_prefix()
end)

vim.api.nvim_create_user_command('SessionSave', function()
    local ok, res = session.save()
    if ok then
        vim.notify('session saved: ' .. vim.fn.fnamemodify(res, ':~'), vim.log.levels.INFO)
    else
        vim.notify('session: ' .. tostring(res), vim.log.levels.INFO)
    end
end, { desc = 'Save session for current worktree root' })

vim.api.nvim_create_user_command('SessionRestore', function()
    local ok, res = session.restore()
    if ok then
        vim.notify('session restored', vim.log.levels.INFO)
    else
        vim.notify('session: ' .. tostring(res or 'no session file for this worktree'), vim.log.levels.INFO)
    end
end, { desc = 'Restore session for current worktree root' })

vim.api.nvim_create_user_command('SessionDelete', function()
    local ok, res = session.delete()
    if ok then
        vim.notify('session deleted: ' .. vim.fn.fnamemodify(res, ':~'), vim.log.levels.INFO)
    else
        vim.notify('session: ' .. tostring(res or 'no session file for this worktree'), vim.log.levels.INFO)
    end
end, { desc = 'Delete session for current worktree root' })

vim.keymap.set('n', '<leader>qs', '<cmd>SessionSave<CR>', { desc = '[S]ession [S]ave' })
vim.keymap.set('n', '<leader>ql', '<cmd>SessionRestore<CR>', { desc = '[S]ession [L]oad' })
vim.keymap.set('n', '<leader>qd', '<cmd>SessionDelete<CR>', { desc = '[S]ession [D]elete' })