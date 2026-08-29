-- Fast-run harness for external bash ACTION commands (things that do work and
-- return an exit code, rather than producing a cached value).
--
-- Instead of paying ~150ms for a `bash -lc` (starship, brew shellenv, fzf,
-- completion, ...) on every action, the shell functions + env vars they need
-- are dumped ONCE into a small defs file (EXTERNAL_DEFS_DUMP in
-- ~/.dotfiles/bash/external.sh). Actions then run via a bare
-- `bash --noprofile --norc -c 'source <defs> && <command>'` (~5ms/call).
--
-- The dump is prefetched asynchronously at startup; if an action runs before
-- it lands, it's generated synchronously on first use.
local bx = require('bash_external')

local DEFS_PATH = vim.fn.stdpath('cache') .. '/bash_external_defs.sh'
local ready = false
local pending = {}

local function gen_async()
    vim.system({ 'bash', '-lc', 'EXTERNAL_DEFS_DUMP ' .. bx.sh(DEFS_PATH) }, function(ret)
        if ret.code == 0 then
            ready = true
        end
        local queued = pending
        pending = {}
        for _, cb in ipairs(queued) do
            vim.schedule(function() cb(ready) end)
        end
    end)
end

local function gen_sync()
    local ret = vim.system({ 'bash', '-lc', 'EXTERNAL_DEFS_DUMP ' .. bx.sh(DEFS_PATH) }):wait()
    if ret.code == 0 then
        ready = true
    end
    return ret
end

local M = {}

-- Path to the defs file, generating it synchronously if it doesn't exist yet.
function M.path()
    if not ready and vim.fn.filereadable(DEFS_PATH) == 0 then
        gen_sync()
    end
    return DEFS_PATH
end

-- Run an external bash action command in a bare bash with the defs sourced.
-- Returns the vim.system result { code, stdout, stderr }.
function M.run(expr)
    local call = 'source ' .. bx.sh(M.path()) .. ' && ' .. expr
    return vim.system({ 'bash', '--noprofile', '--norc', '-c', call }):wait()
end

function M.preload()
    gen_async()
end

function M.on_ready(cb)
    if ready then
        vim.schedule(function() cb() end)
        return
    end
    table.insert(pending, cb)
end

return M