-- NVIM_CD_TARGETS — worktree base + name<TAB>subpath targets (see cd.lua).
-- Returns a parsed table { root, prefix, targets = { name -> subpath } }.
local bx = require('bash_external')

local handle = bx.value('cd_targets', 'NVIM_CD_TARGETS', function(stdout)
    local parsed = { root = nil, prefix = nil, targets = {} }
    for line in vim.gsplit(vim.trim(stdout), '\n') do
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
end)

handle.preload()

return {
    get = handle.get,
    on_load = handle.on_load,
}