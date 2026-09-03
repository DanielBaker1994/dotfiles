local M = {}

-- NVIM_CD_TARGETS provides root (worktree base dir) + prefix (dir prefix).
-- Sessions only exist for a worktree ROOT directory itself (cwd == root/<prefix>-*),
-- never for subdirectories or folders outside the prefix root.
local cd_targets = require('bash_external.cd_targets')

local function get_config()
    return cd_targets.get()
end

local function session_dir()
    return vim.fn.stdpath('state') .. '/sessions'
end

-- Return the session boundary dir ONLY when the current working directory IS
-- that root exactly: a root/<prefix>-* worktree (e.g. ~/jira/JT-1234), or a
-- configured single-repo root (e.g. ~/.dotfiles). Returns nil otherwise, so
-- sessions are never created in subdirectories or outside configured roots.
function M.get_worktree_root()
    local c = get_config()
    if not c or not c.roots then
        return nil
    end
    local cwd = vim.fn.resolve(vim.fn.getcwd())
    for _, r in ipairs(c.roots) do
        local root = vim.fn.resolve(vim.fn.expand(r.root))
        if vim.fn.isdirectory(root) == 1 then
            if r.prefix and r.prefix ~= '' then
                local prefix_match = '^' .. vim.pesc(r.prefix) .. '-'
                local ok, iter = pcall(vim.fs.dir, root)
                if ok then
                    for name in iter do
                        if name:match(prefix_match) then
                            local dir = vim.fn.resolve(root .. '/' .. name)
                            if cwd == dir then
                                return dir
                            end
                        end
                    end
                end
            end
            if cwd == root then
                return root
            end
        end
    end
    return nil
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

-- Source a session file with swap files temporarily disabled, so stale .swp
-- files can never trigger the E325 "ATTENTION" prompt while restoring.
local function source_session(path)
    local prev_swapfile = vim.o.swapfile
    vim.o.swapfile = false
    local ok, err = pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(path))
    vim.o.swapfile = prev_swapfile
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
    vim.api.nvim_create_autocmd('VimEnter', {
        group = grp,
        callback = function()
            local ws = M.get_worktree_root()
            if not ws then
                return
            end
            local path = M.session_path(ws)
            if vim.fn.filereadable(path) == 1 then
                source_session(path)
                for _, f in ipairs(vim.fn.argv()) do
                    if f ~= '' and f:sub(1, 1) ~= '-' then
                        local abs = vim.fn.fnamemodify(f, ':p')
                        if vim.fn.filereadable(abs) == 1 then
                            vim.cmd('edit ' .. vim.fn.fnameescape(abs))
                            break
                        end
                    end
                end
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