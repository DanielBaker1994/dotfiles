-- Opens the build/deploy script in a terminal split; the script shows its own
-- menu and owns the whole pipeline. Argument = directory to resolve the
-- project from (current buffer's dir).
--
-- The script is $BUILD_DEPLOY_SHELL_SCRIPT_PATH. Set (and export) it in the
-- machine-local overrides file, ~/external/.bashrc (sourced first by
-- bash/.bashrc), since this workflow runs on both the personal and the work
-- computer and each points at its own script, e.g.
--   export BUILD_DEPLOY_SHELL_SCRIPT_PATH="$HOME/.dotfiles/bash/build_deploy.sh"
local M = {}

function M.open()
    local script = vim.env.BUILD_DEPLOY_SHELL_SCRIPT_PATH
    if not script or script == '' then
        vim.notify('build_deploy: BUILD_DEPLOY_SHELL_SCRIPT_PATH is not set (export it in ~/external/.bashrc)',
            vim.log.levels.ERROR)
        return
    end
    script = vim.fn.expand(script)
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
