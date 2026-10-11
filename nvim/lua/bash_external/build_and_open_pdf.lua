-- EXTERNAL_BUILD_AND_OPEN_PDF — build a PDF from markdown and open it (see
-- lua/user/db_functions.lua markdown_open). An action command, run via the
-- defs harness so it does NOT re-source the login shell per call.
local bx = require('bash_external')
local defs = require('bash_external.defs')

local M = {}

-- src: absolute path to the .md file; out: output path WITHOUT extension.
-- Returns { code, stdout, stderr } from the bash command.
function M.run(src, out)
    local expr = 'EXTERNAL_BUILD_AND_OPEN_PDF ' .. bx.sh(src) .. ' ' .. bx.sh(out)
    local ret = defs.run(expr)
    return { code = ret.code, stdout = ret.stdout, stderr = ret.stderr }
end

-- Same as M.run but asynchronous; on_done gets { code, stdout, stderr }.
function M.run_async(src, out, on_done)
    local expr = 'EXTERNAL_BUILD_AND_OPEN_PDF ' .. bx.sh(src) .. ' ' .. bx.sh(out)
    defs.run_async(expr, on_done)
end

return M