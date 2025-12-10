-- Opens bash/build_deploy.sh in a terminal split; the script shows its own
-- menu and owns the whole pipeline. Argument = directory to resolve the
-- project from (current buffer's dir).
local M = {}

function M.open()
    local dotdir = vim.env.DOTDIR or (vim.env.HOME .. '/.dotfiles')
    local script = dotdir .. '/bash/build_deploy.sh'
    if vim.fn.filereadable(script) == 0 then
        vim.notify('build_deploy: script not found: ' .. script, vim.log.levels.ERROR)
        return
    end
    local start_dir = vim.fn.expand('%:p:h')
    if start_dir == '' or vim.fn.isdirectory(start_dir) == 0 then
        start_dir = vim.fn.getcwd()
    end
    vim.cmd('botright split')
    vim.cmd('enew')
    vim.fn.termopen({ 'bash', script, start_dir })
    vim.cmd('startinsert')
end

return M
