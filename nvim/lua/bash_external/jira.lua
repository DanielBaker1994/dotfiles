-- JIRA_NAME_PREFIX / JIRA_URL — used by :Jira (see lua/user/jira.lua).
-- Returns { prefix = ..., url = ... }.
local bx = require('bash_external')

local handle = bx.env('jira', 'printf "%s\\n%s" "$JIRA_NAME_PREFIX" "$JIRA_URL"')

handle.preload()

return {
    get = function()
        local lines = handle.get() or {}
        return { prefix = lines[1] or '', url = lines[2] or '' }
    end,
    on_load = function(cb)
        handle.on_load(function(lines)
            cb({ prefix = lines[1] or '', url = lines[2] or '' })
        end)
    end,
}