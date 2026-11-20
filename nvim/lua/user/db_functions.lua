local M = {}

-- EXTERNAL_BUILD_AND_OPEN_PDF runs via the bash_external module
-- (see lua/bash_external/build_and_open_pdf.lua).
local build_and_open_pdf = require('bash_external.build_and_open_pdf')

-- Build <name>.html/.pdf/.png next to the buffer's .md (EXTERNAL_BUILD_AND_OPEN_PDF).
--   opts.open  'html' (default) | 'pdf' | 'none'
--   opts.quiet only speak up on warnings / failure (used by the rebuild-on-save watch)
-- Exit 0 + stderr = built, with warnings (missing image, bad mermaid/math): shown
-- as WARN so they're not lost behind a "built" message.
function M.markdown_build(buf, opts)
    opts = opts or {}
    buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
    local src = vim.api.nvim_buf_get_name(buf)
    if not src:lower():match('%.md$') then
        vim.notify('Current buffer name must end in ".md"', vim.log.levels.ERROR)
        return
    end
    local out_path = vim.fn.fnamemodify(src, ':r')
    if not opts.quiet then
        vim.notify('Building ' .. vim.fn.fnamemodify(src, ':~') .. ' ...', vim.log.levels.INFO)
    end
    -- Async so the UI doesn't freeze while pandoc + mermaid + weasyprint run.
    build_and_open_pdf.run_async(src, out_path, function(ret)
        local msg = vim.trim((ret.stderr ~= '' and ret.stderr) or ret.stdout or '')
        if ret.code ~= 0 then
            vim.notify('Markdown build failed:\n' .. (msg ~= '' and msg or 'unknown error'), vim.log.levels.ERROR)
        elseif msg ~= '' then
            vim.notify('Built with warnings:\n' .. msg, vim.log.levels.WARN)
        elseif not opts.quiet then
            vim.notify('Built: ' .. vim.fn.fnamemodify(out_path, ':~') .. '.{html,pdf,png}', vim.log.levels.INFO)
        end
    end, { open = opts.open })
end

function M.markdown_open() M.markdown_build(0, { open = 'html' }) end
function M.markdown_open_pdf() M.markdown_build(0, { open = 'pdf' }) end

-- Rebuild on every :w (nothing is opened, so the browser tab just needs a
-- Cmd+R). Buffer-local; toggled by <leader>mdw or the winbar's live segment.
local watch_group = vim.api.nvim_create_augroup('user_markdown_watch', { clear = true })
function M.markdown_watching(buf)
    buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
    return #vim.api.nvim_get_autocmds({ group = watch_group, buffer = buf }) > 0
end

function M.markdown_watch_toggle()
    local buf = vim.api.nvim_get_current_buf()
    if M.markdown_watching(buf) then
        vim.api.nvim_clear_autocmds({ group = watch_group, buffer = buf })
        vim.notify('Markdown: rebuild on save OFF', vim.log.levels.INFO)
    else
        vim.api.nvim_create_autocmd('BufWritePost', {
            group = watch_group,
            buffer = buf,
            callback = function(ev) M.markdown_build(ev.buf, { open = 'none', quiet = true }) end,
        })
        vim.notify('Markdown: rebuild on save ON (refresh the browser after :w)', vim.log.levels.INFO)
        M.markdown_build(buf, { open = 'html' })
    end
    vim.cmd('redrawstatus!')   -- also repaints the winbar's live segment
end

function M.search_parent_from_buffer()
    local abs = vim.fn.expand('%:p')
    abs = tostring(abs)

    local function find_special_root(path)
        -- nvim config files (resolve() follows the ~/.config/nvim -> dotfiles
        -- symlink, matching the fully-resolved buffer paths).
        local config_dir = vim.fn.resolve(vim.fn.stdpath('config'))
        if vim.startswith(path, config_dir .. '/') then
            return config_dir .. '/'
        end
        local rules = { 'cpp_directory', 'server_directory', 'java_directory' }
        for _, pat in ipairs(rules) do
            local _, e = string.find(path, pat, 1, true)
            if e then
                return string.sub(path, 1, e) .. '/'
            end
        end
        return nil
    end

    local special = find_special_root(abs)
    local cwd = special and special or vim.fn.fnamemodify(abs, ':h')
    cwd = tostring(cwd)
    if not cwd:match('/$') then cwd = cwd .. '/' end

    local ok_db, user_telescope = pcall(require, 'user.telescope')
    if not ok_db then
        vim.notify('user.telescope', vim.log.levels.ERROR)
        return
    end
    user_telescope.live_multigrep({ cwd = cwd })
end

return M
