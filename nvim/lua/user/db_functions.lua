local M = {}

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

    local function sh(s)
        return string.format("'%s'", tostring(s):gsub("'", "'\\''"))
    end
    local bash_call = 'EXTERNAL_BUILD_AND_OPEN_PDF ' .. sh(src) .. ' ' .. ' ' .. sh(out_path)
    vim.notify(bash_call)
    local cmd = { 'bash', '-lc', bash_call }
    local ret = vim.system(cmd):wait()
    if ret.code ~= 0 then
        --print(vim.notify(vim.insepect(cmd)))
        print('pandoc failed: ' .. (ret.stderr or ret.stdout or 'unknown'), vim.log.levels.ERROR)
    end
end

function M.search_parent_from_buffer()
    local abs = vim.fn.expand('%:p')
    abs = tostring(abs)

    local function find_special_root(path)
        local rules = {
            { pat = '.config/nvim/after/plugin/', root_pat = '.config/nvim/' },
            { pat = 'cpp_directory' },
            { pat = 'server_directory' },
            { pat = 'java_directory' },
        }
        for _, rule in ipairs(rules) do
            local s, e = string.find(path, rule.pat, 1, true)
            if s then
                local end_idx = e
                if rule.root_pat then
                    local _, root_e = string.find(path, rule.root_pat, 1, true)
                    if root_e then end_idx = root_e end
                end
                local prefix = string.sub(path, 1, end_idx)
                if not prefix:match('/$') then prefix = prefix .. '/' end
                return prefix
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


-- vim.api.nvim_create_autocmd("BufEnter", {
--     callback = function()
--         local ft = vim.bo.filetype
--         if ft ~= "help" and ft ~= "man" then return end
--         local percentage = 70
--         local total_height = vim.go.lines
--         local target_height = math.floor(total_height * (percentage / 100))
--         vim.cmd("resize " .. target_height)
--     end,
-- })
