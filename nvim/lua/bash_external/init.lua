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
    -- Raw stdout is persisted so a new nvim never blocks on a login shell
    -- (seconds on a heavy .bash_profile); it is refreshed in the background.
    local disk_path = vim.fn.stdpath('cache') .. '/bash_external_' .. name .. '.txt'
    local MAX_AGE = 24 * 3600

    local function decode(stdout)
        return parse and parse(stdout) or vim.trim(stdout or '')
    end

    local function read_disk()
        local f = io.open(disk_path, 'r')
        if not f then
            return nil
        end
        local raw = f:read('*a')
        f:close()
        return raw
    end

    -- mkdir is a vimscript fn: not allowed in the vim.system callback (fast
    -- event), so create the dir here on the main thread at load time.
    vim.fn.mkdir(vim.fn.fnamemodify(disk_path, ':h'), 'p')

    local function write_disk(stdout)
        local f = io.open(disk_path, 'w')
        if f then
            f:write(stdout or '')
            f:close()
        end
    end

    local function disk_fresh()
        local st = vim.uv.fs_stat(disk_path)
        return st and (os.time() - st.mtime.sec) < MAX_AGE
    end

    local function run_async()
        vim.system(M.bash(expr), { text = true }, function(ret)
            local value = nil
            if ret.code == 0 then
                value = decode(ret.stdout)
                write_disk(ret.stdout)
            end
            vim.schedule(function()
                cache = value ~= nil and value or cache
                local queued = pending
                pending = {}
                for _, cb in ipairs(queued) do
                    cb(cache)
                end
            end)
        end)
    end

    local h = {}

    function h.get()
        if cache ~= nil then
            return cache
        end
        local raw = read_disk()
        if raw then
            cache = decode(raw)
            if cache ~= nil then
                return cache
            end
        end
        local ret = vim.system(M.bash(expr), { text = true }):wait()
        if ret.code == 0 then
            write_disk(ret.stdout)
            cache = decode(ret.stdout)
        end
        return cache
    end

    function h.on_load(cb)
        if cache ~= nil then
            vim.schedule(function() cb(cache) end)
            return
        end
        table.insert(pending, cb)
    end

    -- Serve from disk immediately; only spawn the login shell when the disk
    -- copy is missing/stale, and then after startup has settled.
    function h.preload()
        if disk_fresh() then
            local raw = read_disk()
            if raw then
                cache = decode(raw)
            end
        end
        if cache == nil then
            vim.defer_fn(run_async, 500)
        end
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