-- Shared base for external bash commands consumed by nvim.
--
-- Every command that nvim reaches into bash for lives in its own module under
-- lua/bash_external/ and is prefetched asynchronously at startup (see
-- after/plugin/bash_external.lua), then cached so running it later never pays
-- the `bash -lc` login-shell cost again.
--
-- Bash side: the function/env definitions themselves live together in
-- ~/.dotfiles/bash/external.sh (sourced by both .bash_profile and .bashrc).
local M = {}

-- single-quote escape for embedding a value in a bash command string
function M.sh(s)
    return string.format("'%s'", tostring(s):gsub("'", "'\\''"))
end

-- Build a `bash -lc` command table for a shell expression
function M.bash(expr)
    return { 'bash', '-lc', expr }
end

-- Cached value loader with async prefetch + sync fallback.
--
--   name : registry key (used for debugging/errors)
--   expr : shell expression that prints the value(s) to stdout
--   parse: optional fn(stdout) -> value (default: trimmed stdout string)
--
-- Returns a handle with:
--   get()      -> value (loads synchronously if the async prefetch hasn't landed)
--   on_load(cb)-> cb(value) once loaded (immediately if already cached)
--   preload()  -> kick off the async fetch; safe to call once at startup
function M.value(name, expr, parse)
    local cache = nil
    local pending = {}

    local function run_async()
        vim.system(M.bash(expr), { text = true }, function(ret)
            cache = ret.code == 0 and (parse and parse(ret.stdout) or vim.trim(ret.stdout or '')) or nil
            local queued = pending
            pending = {}
            for _, cb in ipairs(queued) do
                vim.schedule(function() cb(cache) end)
            end
        end)
    end

    local h = {}

    function h.get()
        if cache ~= nil then
            return cache
        end
        local ret = vim.system(M.bash(expr), { text = true }):wait()
        cache = ret.code == 0 and (parse and parse(ret.stdout) or vim.trim(ret.stdout or '')) or nil
        return cache
    end

    function h.on_load(cb)
        if cache ~= nil then
            vim.schedule(function() cb(cache) end)
            return
        end
        table.insert(pending, cb)
    end

    function h.preload()
        run_async()
    end

    function h.is_loaded()
        return cache ~= nil
    end

    return h
end

-- Value handle whose stdout is one variable per line -> { <line1>, <line2>, ... }
function M.env(name, expr)
    return M.value(name, expr, function(stdout)
        return vim.split(stdout or '', '\n', { plain = true })
    end)
end

return M