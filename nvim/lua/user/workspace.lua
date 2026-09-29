-- Workspace resolution shared by cd.lua, session.lua and jira.lua.
--
-- The workspace is resolved from the directory nvim was LAUNCHED from —
-- never from getcwd() (mutated by :cd) or the open buffer:
--   1. a configured root/<prefix>-<seg> worktree containing the launch dir
--      (e.g. ~/jira/JT-1234 from ~/jira/JT-1234/cpp)
--   2. a configured root dir containing the launch dir (e.g. ~/.dotfiles)
--   3. the launch dir itself (no entry -> not a configured workspace)
--
-- Roots come from bash/external.sh NVIM_CD_TARGETS. A root without `prefix=`
-- uses the Jira prefix, which is prompted for once and cached in
-- lua/user/jira_prefix.lua (gitignored, machine-local).
local M = {}

local cd_targets = require('bash_external.cd_targets')

-- Captured at load, so this module must be required at startup (it is, via
-- after/plugin/session.lua) — before a session restore can :cd elsewhere.
M.launch_cwd = vim.fn.resolve(vim.uv.cwd())

local prefix_file = vim.fn.stdpath('config') .. '/lua/user/jira_prefix.lua'
local jira_prefix = nil

-- Cached Jira prefix, or nil if never set. Never prompts.
function M.jira_prefix()
    if jira_prefix == nil then
        local ok, val = pcall(dofile, prefix_file)
        if ok and type(val) == 'string' and val ~= '' then
            jira_prefix = val
        end
    end
    return jira_prefix
end

-- Cached Jira prefix, prompting once (and caching to disk) if unset.
-- Returns nil if unset and no UI to prompt in (headless) or input is empty.
function M.ensure_jira_prefix()
    if M.jira_prefix() or #vim.api.nvim_list_uis() == 0 then
        return jira_prefix
    end
    local val = vim.trim(vim.fn.input('Jira ticket prefix (e.g. JT): '))
    if val == '' then
        return nil
    end
    vim.fn.writefile({ 'return ' .. string.format('%q', val) }, prefix_file)
    jira_prefix = val
    return val
end

-- Returns (workspace_dir, entry) for `dir` (default: launch dir). entry is
-- the matched NVIM_CD_TARGETS root, or nil outside every configured root.
function M.resolve(dir)
    dir = dir or M.launch_cwd
    local config = cd_targets.get()
    if config and config.roots then
        for _, r in ipairs(config.roots) do
            local root = vim.fn.resolve(vim.fn.expand(r.root))
            local inside = dir == root or vim.startswith(dir, root .. '/')
            if inside and vim.fn.isdirectory(root) == 1 then
                local prefix = r.prefix ~= '' and r.prefix or M.ensure_jira_prefix()
                if prefix then
                    local base = root .. '/' .. prefix .. '-'
                    local seg = vim.startswith(dir, base) and dir:sub(#base + 1):match('^[^/]+')
                    if seg then
                        local wt = vim.fn.resolve(base .. seg)
                        if vim.fn.isdirectory(wt) == 1 then
                            return wt, r
                        end
                    end
                end
                return root, r
            end
        end
    end
    return dir, nil
end

-- Validate the workspace: Jira prefix is set (prompts once) and the launch
-- dir is inside a configured root, i.e. zoxide-scoped <leader>cd applies.
-- Returns (workspace_dir, entry) on success, nil (with a notification) otherwise.
function M.check()
    if not M.ensure_jira_prefix() then
        vim.notify('Workspace: Jira prefix is not set', vim.log.levels.ERROR)
        return nil
    end
    local ws, entry = M.resolve()
    if not entry then
        vim.notify('Workspace: ' .. M.launch_cwd .. ' is not inside a configured root (NVIM_CD_TARGETS)',
            vim.log.levels.WARN)
        return nil
    end
    return ws, entry
end

return M
