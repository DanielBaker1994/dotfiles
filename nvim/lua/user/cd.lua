local M = {}
local cfg = nil

local function parse(ret)
    local parsed = { root = nil, prefix = nil, targets = {} }
    for line in vim.gsplit(vim.trim(ret.stdout), '\n') do
        local key, val = line:match('^([^\t]+)\t(.*)$')
        if key == 'root' then
            parsed.root = val
        elseif key == 'prefix' then
            parsed.prefix = val
        else
            parsed.targets[key] = val or '.'
        end
    end
    return parsed
end

local function get_config()
    if cfg then
        return cfg
    end
    local ret = vim.system({ 'bash', '-lc', 'NVIM_CD_TARGETS' }, { text = true }):wait()
    if ret.code == 0 then
        cfg = parse(ret)
    end
    return cfg
end

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

function M.names()
    local c = get_config()
    local names = {}
    if c then
        for k in pairs(c.targets) do
            table.insert(names, k)
        end
    end
    table.insert(names, 'buffer')
    table.sort(names)
    return names
end

function M.cd(name)
    if name == 'buffer' then
        local dir
        local ok_oil, oil = pcall(require, 'oil')
        if ok_oil then
            dir = oil.get_current_dir(0)
        end
        if not dir then
            dir = vim.fn.expand('%:p:h')
        end
        if dir == '' or vim.fn.isdirectory(dir) == 0 then
            vim.notify('cd: not a valid directory: ' .. tostring(dir), vim.log.levels.WARN)
            return
        end
        vim.cmd('cd ' .. vim.fn.fnameescape(dir))
        vim.notify('cd ' .. dir, vim.log.levels.INFO)
        return
    end
    local c = get_config()
    if not c or not c.targets[name] then
        vim.notify('Unknown cd target: ' .. name, vim.log.levels.WARN)
        return
    end
    local base = current_worktree()
    if not base then
        vim.notify('Not inside a ' .. tostring(c.prefix) .. ' worktree under ' .. tostring(c.root),
            vim.log.levels.WARN)
        return
    end
    local sub = c.targets[name]
    local dir = (sub == '.' or sub == '') and base or (base .. '/' .. sub)
    if vim.fn.isdirectory(dir) == 0 then
        vim.notify('cd: not a directory: ' .. dir, vim.log.levels.WARN)
        return
    end
    vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    vim.notify('cd ' .. dir, vim.log.levels.INFO)
end

function M.pick()
    local names = M.names()
    if #names == 0 then
        vim.notify('No cd targets defined', vim.log.levels.WARN)
        return
    end
    vim.ui.select(names, { prompt = 'CD target:' }, function(name)
        if name then
            M.cd(name)
        end
    end)
end

-- Load the bash-defined targets once, asynchronously at startup, so using a
-- cd target later doesn't pay the bash -lc cost (mirrors EXTERNAL_PATHS_GLOBAL).
vim.system({ 'bash', '-lc', 'NVIM_CD_TARGETS' }, { text = true }, function(ret)
    if ret.code == 0 then
        cfg = parse(ret)
    end
end)

return M