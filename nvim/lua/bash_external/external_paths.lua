-- EXTERNAL_PATHS_GLOBAL — dotfile paths to include in Telescope greps (see
-- after/plugin/core.lua). Returns a list of whitespace-separated paths.
local bx = require('bash_external')

local handle = bx.value('external_paths', 'EXTERNAL_PATHS_GLOBAL', function(stdout)
    local out = vim.trim(stdout or '')
    return out == '' and {} or vim.split(out, '%s+')
end)

handle.preload()

return {
    get = handle.get,
    on_load = handle.on_load,
}