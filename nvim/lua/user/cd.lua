local M = {}

-- NVIM_CD_TARGETS is defined in bash and prefetched/cached by the
-- bash_external module (see lua/bash_external/cd_targets.lua).
local cd_targets = require('bash_external.cd_targets')

local function get_config()
    return cd_targets.get()
end

-- Workspace root resolution, in priority order:
--   1. A worktree dir matching root/<prefix>-* that contains the cwd
--   2. The nearest git root (vim.fs.root)
--   3. The current working directory itself
local function get_workspace_root()
    local c = get_config()
    local cwd = vim.fn.resolve(vim.fn.getcwd())
    if c and c.root and c.prefix then
        local prefix_match = '^' .. vim.pesc(c.prefix) .. '-'
        for name in vim.fs.dir(c.root) do
            if name:match(prefix_match) then
                local dir = vim.fn.resolve(c.root .. '/' .. name)
                if cwd == dir or vim.startswith(cwd, dir .. '/') then
                    return dir
                end
            end
        end
    end
    local git_root = vim.fs.root(0, '.git')
    if git_root then
        return vim.fn.resolve(git_root)
    end
    return cwd
end

-- Strict worktree resolution for ClearOtherBuffers (only the configured
-- root/<prefix>-* worktrees count as a workspace boundary).
local function current_worktree()
    local c = get_config()
    if not c or not c.root or not c.prefix then
        return nil
    end
    local cwd = vim.fn.getcwd()
    local prefix_match = '^' .. vim.pesc(c.prefix) .. '-'
    for name in vim.fs.dir(c.root) do
        if name:match(prefix_match) then
            local dir = c.root .. '/' .. name
            if cwd == dir or vim.startswith(cwd, dir .. '/') then
                return dir
            end
        end
    end
    return nil
end

-- Query zoxide once and return only paths strictly inside the workspace root.
-- Relative display names are the path minus the workspace prefix.
local function get_scoped_zoxide_paths(ws)
    if vim.fn.executable('zoxide') == 0 then
        return {}
    end
    local res = vim.system({ 'zoxide', 'query', '-l' }, { text = true }):wait()
    if res.code ~= 0 or not res.stdout then
        return {}
    end
    local paths = {}
    local seen = {}
    for line in vim.gsplit(vim.trim(res.stdout), '\n') do
        line = vim.fn.resolve(vim.trim(line))
        if line ~= '' and (line == ws or vim.startswith(line, ws .. '/')) then
            local rel = line == ws and '.' or line:sub(#ws + 2)
            if not seen[rel] then
                seen[rel] = true
                table.insert(paths, { dir = line, rel = rel })
            end
        end
    end
    return paths
end

-- Absolute dir for the active buffer (Oil-aware, falls back to file dir).
local function buffer_dir()
    local ok_oil, oil = pcall(require, 'oil')
    if ok_oil then
        local d = oil.get_current_dir(0)
        if d and d ~= '' then
            return d
        end
    end
    local d = vim.fn.expand('%:p:h')
    if d ~= '' then
        return d
    end
    return nil
end

-- Build the ordered list of picker entries.
-- Each entry: { name = display, dir = absolute path }
local function build_entries()
    local ws = get_workspace_root()
    local entries = {}
    local seen = {}
    local function add(name, dir, exists_check)
        if not dir then
            return
        end
        if exists_check and vim.fn.isdirectory(dir) == 0 then
            return
        end
        if not seen[dir] then
            seen[dir] = true
            table.insert(entries, { name = name, dir = dir })
        end
    end

    local c = get_config()
    if c then
        for k, sub in pairs(c.targets) do
            local dir = (sub == '.' or sub == '') and ws or (ws .. '/' .. sub)
            add(k, dir, true)
        end
    end
    add('buffer', buffer_dir(), true)

    for _, p in ipairs(get_scoped_zoxide_paths(ws)) do
        add(p.rel, p.dir, true)
    end

    return entries
end

-- Complete list of selectable names (aliases + relative zoxide subpaths).
function M.names()
    local names = {}
    for _, e in ipairs(build_entries()) do
        table.insert(names, e.name)
    end
    return names
end

function M.cd(name)
    if name == 'buffer' then
        local dir = buffer_dir()
        if dir and vim.fn.isdirectory(dir) == 1 then
            vim.cmd('cd ' .. vim.fn.fnameescape(dir))
            vim.notify('cd ' .. dir, vim.log.levels.INFO)
        else
            vim.notify('cd: not a valid directory: ' .. tostring(dir), vim.log.levels.WARN)
        end
        return
    end

    local ws = get_workspace_root()
    for _, e in ipairs(build_entries()) do
        if e.name == name then
            if vim.fn.isdirectory(e.dir) == 0 then
                vim.notify('cd: not a directory: ' .. e.dir, vim.log.levels.WARN)
                return
            end
            vim.cmd('cd ' .. vim.fn.fnameescape(e.dir))
            vim.notify('cd ' .. e.dir, vim.log.levels.INFO)
            return
        end
    end
    vim.notify('Unknown cd target: ' .. name, vim.log.levels.WARN)
end

function M.pick()
    local entries = build_entries()
    if #entries == 0 then
        vim.notify('No cd targets defined', vim.log.levels.WARN)
        return
    end
    -- Buffer is the first/default option.
    table.sort(entries, function(a, b)
        if a.name == 'buffer' then
            return true
        end
        if b.name == 'buffer' then
            return false
        end
        return false
    end)
    local items = {}
    local home = vim.env.HOME
    for _, e in ipairs(entries) do
        local dir = e.dir
        if home and vim.startswith(dir, home .. '/') then
            dir = '~' .. dir:sub(#home + 1)
        end
        table.insert(items, dir)
    end
    vim.ui.select(items, { prompt = 'CD target:', kind = 'cd' }, function(item)
        if item then
            local dir = item
            if home and vim.startswith(dir, '~/') then
                dir = home .. dir:sub(2)
            elseif dir == '~' then
                dir = home
            end
            if vim.fn.isdirectory(dir) == 1 then
                vim.cmd('cd ' .. vim.fn.fnameescape(dir))
                vim.notify('cd ' .. dir, vim.log.levels.INFO)
            end
        end
    end)
end

function M.clear_other_buffers()
    local c = get_config()
    if not c or not c.root or not c.prefix then
        vim.notify('No workspace root configured', vim.log.levels.WARN)
        return
    end
    local ws = current_worktree()
    if not ws then
        vim.notify('Not inside a workspace worktree', vim.log.levels.WARN)
        return
    end
    local cur = vim.api.nvim_get_current_buf()
    local closed = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= cur and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted
            and vim.bo[b].buftype == '' then
            local name = vim.api.nvim_buf_get_name(b)
            if name ~= '' and not name:match('^%a+://') then
                local abs = vim.fn.fnamemodify(name, ':p')
                if not (abs == ws or vim.startswith(abs, ws .. '/')) then
                    if pcall(vim.api.nvim_buf_delete, b, { force = true }) then
                        closed = closed + 1
                    end
                end
            end
        end
    end
    vim.notify('Closed ' .. closed .. ' buffer(s) outside workspace', vim.log.levels.INFO)
end

return M