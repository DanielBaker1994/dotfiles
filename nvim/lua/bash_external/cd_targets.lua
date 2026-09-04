-- NVIM_CD_TARGETS — workspace roots + per-root targets (see cd.lua, session.lua).
--
-- New format (readable, one root per block separated by a blank line):
--   root=<dir>
--   prefix=<prefix>
--   <name>=<subpath>
--
--   e.g.
--   root=$HOME/jira
--   prefix=JT
--   top=.
--   cpp=cpp
--
-- Legacy tab format (single root) is still accepted:
--   root<TAB>dir / prefix<TAB>P / name<TAB>subpath
--
-- Returns { roots = { { root, prefix, targets = { name -> subpath } }, ... } }.
local bx = require('bash_external')

-- Manual ~ expansion (vim.fn.expand is not allowed in the async parse callback).
local function expand_home(path)
    if path:sub(1, 1) == '~' then
        local home = vim.env.HOME or os.getenv('HOME')
        if home then
            if path == '~' then
                return home
            end
            if path:sub(1, 2) == '~/' then
                return home .. path:sub(2)
            end
        end
    end
    return path
end

local handle = bx.value('cd_targets', 'NVIM_CD_TARGETS', function(stdout)
    local parsed = { roots = {} }
    stdout = vim.trim(stdout or '')

    -- Legacy tab format: lines contain tabs, e.g. root<TAB>dir.
    if stdout:find('\t') then
        local legacy_root = nil
        local legacy_prefix = nil
        local legacy_targets = {}
        for line in vim.gsplit(stdout, '\n') do
            local fields = vim.split(line, '\t')
            local key = fields[1]
            if key == 'root' then
                legacy_root = expand_home(fields[2])
            elseif key == 'prefix' then
                legacy_prefix = fields[2]
            elseif legacy_root then
                legacy_targets[key] = fields[2] or '.'
            end
        end
        if legacy_root then
            table.insert(parsed.roots, {
                root = legacy_root,
                prefix = legacy_prefix or '',
                targets = legacy_targets,
            })
        end
        return parsed
    end

    -- New block format: `key=value` lines, roots separated by a blank line.
    for _, block in ipairs(vim.split(stdout, '\n\n')) do
        local root = nil
        local prefix = nil
        local targets = {}
        for line in vim.gsplit(block, '\n') do
            line = vim.trim(line)
            if line ~= '' then
                local key, val = line:match('^([^=]+)=(.*)$')
                if key then
                    key = vim.trim(key)
                    val = vim.trim(val)
                    if key == 'root' then
                        root = expand_home(val)
                    elseif key == 'prefix' then
                        prefix = val
                    elseif root ~= nil then
                        targets[key] = (val == '' or val == '.') and '.' or val
                    end
                end
            end
        end
        if root then
            table.insert(parsed.roots, { root = root, prefix = prefix or '', targets = targets })
        end
    end
    return parsed
end)

handle.preload()

return {
    get = handle.get,
    on_load = handle.on_load,
}