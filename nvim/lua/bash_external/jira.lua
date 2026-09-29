-- JIRA_URL — used by :Jira (see lua/user/jira.lua). The ticket prefix is
-- not here: it is prompted for once and cached by lua/user/workspace.lua.
local bx = require('bash_external')

local handle = bx.value('jira_url', 'printf "%s" "$JIRA_URL"')

handle.preload()

return {
    get = handle.get,
    on_load = handle.on_load,
}
