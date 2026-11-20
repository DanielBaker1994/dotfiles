-- EXTERNAL_BUILD_AND_OPEN_PDF — build HTML + PDF + PNG from markdown and open
-- one (see lua/user/db_functions.lua markdown_open). An action command, run
-- via the defs harness so it does NOT re-source the login shell per call.
local bx = require('bash_external')
local defs = require('bash_external.defs')

local M = {}

-- src: absolute path to the .md file; out: output path WITHOUT extension.
-- opts.open: 'html' (default) | 'pdf' | 'none' (MDGEN_OPEN in external.sh)
local function expr(src, out, opts)
    local open = (opts and opts.open) or 'html'
    return 'MDGEN_OPEN=' .. bx.sh(open) .. ' EXTERNAL_BUILD_AND_OPEN_PDF ' .. bx.sh(src) .. ' ' .. bx.sh(out)
end

-- Returns { code, stdout, stderr } from the bash command.
function M.run(src, out, opts)
    local ret = defs.run(expr(src, out, opts))
    return { code = ret.code, stdout = ret.stdout, stderr = ret.stderr }
end

-- Same as M.run but asynchronous; on_done gets { code, stdout, stderr }.
function M.run_async(src, out, on_done, opts)
    defs.run_async(expr(src, out, opts), on_done)
end

return M
