local M = {}

-- Sessions exist only for a configured workspace (user.workspace): a
-- root/<prefix>-* worktree or a single-repo root, resolved from the LAUNCH
-- dir — so :cd into a subdir never stops the session from saving, and
-- launching from a subdir restores the worktree's session.
local workspace = require('user.workspace')

local function session_dir()
    return vim.fn.stdpath('state') .. '/sessions'
end

-- Workspace dir, or nil outside every configured root.
function M.get_worktree_root()
    local ws, entry = workspace.resolve()
    return entry and ws or nil
end

-- One session file per worktree root: ~/.local/state/nvim/sessions/<safe>.vim
function M.session_path(ws)
    if not ws then
        return nil
    end
    local safe = ws:gsub('[/\\:]', '%%')
    return session_dir() .. '/' .. safe .. '.vim'
end

-- Silently write every real modified file buffer (never prompts).
local function save_all_buffers()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf)
            and vim.bo[buf].buftype == ''
            and vim.api.nvim_buf_get_name(buf) ~= ''
            and vim.bo[buf].modified then
            pcall(vim.api.nvim_buf_call, buf, function()
                vim.cmd('silent! update')
            end)
        end
    end
end

-- Wipe unnamed scratch buffers so quitting / saving a session never prompts.
local function wipe_scratch_buffers()
    local cur = vim.api.nvim_get_current_buf()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if buf ~= cur and vim.api.nvim_buf_is_valid(buf)
            and vim.bo[buf].buftype == ''
            and vim.api.nvim_buf_get_name(buf) == '' then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
end

function M.save()
    local ws = M.get_worktree_root()
    if not ws then
        return false, 'not at a worktree root'
    end
    local ft = vim.bo[vim.api.nvim_get_current_buf()].filetype
    if ft == 'gitcommit' or ft == 'gitrebase' then
        return false, 'skipped (git commit/rebase in progress)'
    end
    save_all_buffers()
    wipe_scratch_buffers()
    local path = M.session_path(ws)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    vim.cmd('silent! mksession! ' .. vim.fn.fnameescape(path))
    return true, path
end

-- Buffers loaded via `:source` of a session during VimEnter miss filetype
-- detection (nvim skips it for edits inside VimEnter), so they get no syntax
-- highlighting, and the lazy-loaded LSP config (event = BufReadPre) may load
-- after their FileType already fired, so no server attaches. Force a one-time
-- reload / FileType re-fire so detection and LSP attach run.
local function reload_unhighlighted_buffers()
    local ok_lazy, lazy = pcall(require, 'lazy')
    if ok_lazy then
        pcall(lazy.load, { plugins = { 'nvim-lspconfig' } })
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf)
            and vim.api.nvim_buf_is_loaded(buf)
            and vim.bo[buf].buftype == ''
            and vim.api.nvim_buf_get_name(buf) ~= '' then
            local ft = vim.bo[buf].filetype
            -- A real file can inherit a stale 'oil' filetype from the `nvim .`
            -- directory buffer during restore; treat it as undetected.
            if ft == '' or ft == 'oil' then
                pcall(vim.api.nvim_buf_call, buf, function()
                    vim.cmd('silent! edit')
                end)
            elseif #vim.lsp.get_clients({ bufnr = buf }) == 0 then
                pcall(vim.api.nvim_exec_autocmds, 'FileType', {
                    buffer = buf,
                    modeline = false,
                })
            end
        end
    end
end

-- Source a session file with swap files temporarily disabled, so stale .swp
-- files can never trigger the E325 "ATTENTION" prompt while restoring.
local function source_session(path)
    local prev_swapfile = vim.o.swapfile
    vim.o.swapfile = false
    local ok, err = pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(path))
    vim.o.swapfile = prev_swapfile
    if ok then
        vim.schedule(reload_unhighlighted_buffers)
    end
    if not ok then
        return false, err
    end
    return true, nil
end

function M.restore()
    local ws = M.get_worktree_root()
    if not ws then
        return false, 'not at a worktree root'
    end
    local path = M.session_path(ws)
    if vim.fn.filereadable(path) == 1 then
        local ok, err = source_session(path)
        if ok then
            return true, path
        end
        return false, err
    end
    return false, nil
end

function M.delete()
    local ws = M.get_worktree_root()
    if not ws then
        return false, 'not at a worktree root'
    end
    local path = M.session_path(ws)
    if vim.fn.filereadable(path) == 1 then
        os.remove(path)
        return true, path
    end
    return false, nil
end

function M.setup()
    local grp = vim.api.nvim_create_augroup('user-session', { clear = true })

    -- Auto-restore when starting inside a worktree root (regardless of file
    -- arguments); any file passed on the command line is focused afterwards.
    -- Swap files are disabled for the whole block so stale .swp can never
    -- trigger E325 during restore or when re-opening the argv file.
    vim.api.nvim_create_autocmd('VimEnter', {
        group = grp,
        callback = function()
            local ws = M.get_worktree_root()
            if not ws then
                return
            end
            local path = M.session_path(ws)
            if vim.fn.filereadable(path) == 1 then
                -- Resolve argv files to absolute paths BEFORE sourcing the
                -- session: the session may cd (sessionoptions includes
                -- 'curdir'), which would otherwise resolve relative argv files
                -- (e.g. `nvim notes.txt`) against the wrong directory and the
                -- target file would never open — leaving the session focused.
                local argv_files = {}
                for _, f in ipairs(vim.fn.argv()) do
                    if f ~= '' and f:sub(1, 1) ~= '-' then
                        local abs = vim.fn.fnamemodify(f, ':p')
                        if vim.fn.filereadable(abs) == 1 then
                            table.insert(argv_files, abs)
                        end
                    end
                end
                local prev_swapfile = vim.o.swapfile
                vim.o.swapfile = false
                local ok = pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(path))
                if ok then
                    for _, abs in ipairs(argv_files) do
                        vim.cmd('edit ' .. vim.fn.fnameescape(abs))
                        break
                    end
                end
                vim.o.swapfile = prev_swapfile
                vim.schedule(reload_unhighlighted_buffers)
            end
        end,
    })

    -- Auto-save on exit, only when still at a worktree root.
    vim.api.nvim_create_autocmd('VimLeavePre', {
        group = grp,
        callback = function()
            M.save()
        end,
    })
end

return M