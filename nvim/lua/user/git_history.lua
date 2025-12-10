-- Interactive DiffviewFileHistory filter builder.
-- Pick filters from a menu, type their values in prompts, chain as many as you
-- want, then run. The prompt always shows the command being built, so there is
-- nothing to memorize. Esc at any step cancels/backs out.
local M = {}

local filters = {
    { name = 'Range (e.g. main..HEAD, HEAD~20..)', flag = '--range=' },
    { name = 'Message contains (e.g. fix)', flag = '--grep=' },
    { name = 'Author (e.g. daniel)', flag = '--author=' },
    { name = 'Since date (e.g. 2026-08-01, "2 weeks ago")', flag = '--since=' },
    { name = 'Until date', flag = '--until=' },
    { name = 'Content: exact string added/removed (-S)', flag = '-S' },
    { name = 'Content: regex in diff (-G)', flag = '-G' },
    { name = 'Files touched (partial ok, e.g. *telescope*)', pathspec = true },
    { name = 'Limit to current file (toggle)', current_file = true },
}

function M.open()
    local args = {}
    local paths = {}
    local current_file = false

    local function command_str()
        local parts = { 'DiffviewFileHistory' }
        if current_file then
            table.insert(parts, vim.fn.fnameescape(vim.fn.expand('%:p')))
        end
        for _, a in ipairs(args) do
            table.insert(parts, vim.fn.fnameescape(a))
        end
        if #paths > 0 then
            table.insert(parts, '--')
            for _, p in ipairs(paths) do
                table.insert(parts, vim.fn.fnameescape(p))
            end
        end
        return table.concat(parts, ' ')
    end

    local function menu()
        local items = {}
        for _, f in ipairs(filters) do
            table.insert(items, '+ ' .. f.name)
        end
        table.insert(items, '>> RUN: ' .. command_str())

        vim.ui.select(items, {
            prompt = 'git history filters (esc cancels)',
        }, function(choice, idx)
            if choice == nil then
                return
            end
            if idx == #items then
                vim.cmd(command_str())
                return
            end

            local f = filters[idx]
            if f.current_file then
                current_file = not current_file
                menu()
                return
            end

            local short = f.name:match('^[^%(]+')
            vim.ui.input({ prompt = vim.trim(short) .. ': ' }, function(value)
                if value == nil then
                    menu()
                    return
                end
                value = vim.trim(value)
                if value ~= '' then
                    if f.pathspec then
                        table.insert(paths, value)
                    else
                        table.insert(args, f.flag .. value)
                    end
                end
                menu()
            end)
        end)
    end

    menu()
end

return M
