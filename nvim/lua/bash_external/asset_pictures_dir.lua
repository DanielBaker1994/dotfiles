-- ASSET_PICTURES_DIRECTORY_GLOBAL — used by <leader>pi (see init.lua).
-- Returns the directory path as a string.
local bx = require('bash_external')

local handle = bx.value('asset_pictures_dir', 'printf "%s" "$ASSET_PICTURES_DIRECTORY_GLOBAL"')

handle.preload()

return {
    get = handle.get,
    on_load = handle.on_load,
}