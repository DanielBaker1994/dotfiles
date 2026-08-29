-- :Jira — read the git branch name from the open buffer's directory, extract
-- the Jira ticket (JIRA_NAME_PREFIX-<number>), and open it in Chrome.
-- JIRA_NAME_PREFIX / JIRA_URL are fetched/cached by the bash_external module
-- (see lua/bash_external/jira.lua); the definitions live in
-- ~/.dotfiles/bash/external.sh.
local M = {}

local jira_env = require('bash_external.jira')

local function env()
    local e = jira_env.get()
    return e.prefix, e.url
end

local function buffer_dir()
    local dir = vim.fn.expand('%:p:h')
    if dir == '' or vim.fn.isdirectory(dir) == 0 then
        dir = vim.fn.getcwd()
    end
    return dir
end

local function branch_for(dir)
    local ret = vim.system({ 'git', '-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD' }, { text = true }):wait()
    if ret.code ~= 0 then
        return nil
    end
    return vim.trim(ret.stdout or '')
end

function M.open()
    local prefix, base_url = env()
    if not prefix or prefix == '' then
        vim.notify('Jira: JIRA_NAME_PREFIX is not set in ~/.dotfiles/bash/external.sh', vim.log.levels.ERROR)
        return
    end
    if not base_url or base_url == '' then
        vim.notify('Jira: JIRA_URL is not set in ~/.dotfiles/bash/external.sh', vim.log.levels.ERROR)
        return
    end

    local dir = buffer_dir()
    local branch = branch_for(dir)
    if not branch then
        vim.notify('Jira: not a git repo (or no HEAD) at ' .. dir, vim.log.levels.ERROR)
        return
    end

    local num = branch:match('^' .. vim.pesc(prefix) .. '%-(%d+)')
    if num then
        local rest = branch:sub(#prefix + #num + 2)
        if rest ~= '' and not rest:match('^-') then
            num = nil
        end
    end
    if not num or tonumber(num) == nil then
        vim.notify('Jira: branch "' .. branch .. '" does not match ' .. prefix .. '-<number>',
            vim.log.levels.ERROR)
        return
    end

    local ticket = prefix .. '-' .. num
    local url = base_url:gsub('/+$', '') .. '/browse/' .. ticket
    vim.fn.system({ 'open', '-a', 'Google Chrome', url })
    vim.notify('Opening ' .. url, vim.log.levels.INFO)
end

return M