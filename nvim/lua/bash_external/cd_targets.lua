-- NVIM_CD_TARGETS — workspace roots + per-root targets (resolved by lua/user/workspace.lua).
--
-- One root per block, blocks separated by a blank line:
--   root=<dir>
--   prefix=<prefix>   (optional; omitted -> the cached Jira prefix)
--   <name>=<subpath>
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

    -- `key=value` lines, roots separated by a blank line.
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