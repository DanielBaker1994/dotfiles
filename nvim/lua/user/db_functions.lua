local M = {}

-- EXTERNAL_BUILD_AND_OPEN_PDF runs via the bash_external module
-- (see lua/bash_external/build_and_open_pdf.lua).
local build_and_open_pdf = require('bash_external.build_and_open_pdf')

function M.markdown_open()
    local bufname = vim.fn.expand('%:t')
    if not bufname:lower():match('%.md$') then
        vim.notify('Current buffer name must contain ".md"', vim.log.levels.ERROR)
        return
    end
    local out_name = vim.fn.expand('%:t:r')
    local out_dir = vim.fn.expand('%:p:h')
    local out_path = out_dir .. '/' .. out_name

    local src = vim.fn.expand('%:p')

    -- Async so the UI doesn't freeze while pandoc + weasyprint run.
    vim.notify('Building PDF from ' .. vim.fn.fnamemodify(src, ':~') .. ' ...', vim.log.levels.INFO)
    build_and_open_pdf.run_async(src, out_path, function(ret)
        if ret.code ~= 0 then
            local err = (ret.stderr ~= '' and ret.stderr) or ret.stdout or 'unknown'
            vim.notify('pandoc failed: ' .. err, vim.log.levels.ERROR)
        else
            vim.notify('PDF built: ' .. vim.fn.fnamemodify(out_path .. '.pdf', ':~'), vim.log.levels.INFO)
        end
    end)
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
