local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local make_entry = require "telescope.make_entry"
local conf = require "telescope.config".values

local M = {}

function M.live_multigrep(opts)
    opts = opts or {}

    if not opts.search_dirs then
        opts.cwd = opts.cwd or vim.uv.cwd()
    end
    if not opts.prompt_title then
        opts.prompt_title = "Custom"
    end

    local finder = finders.new_async_job {
        command_generator = function(prompt)
            if not prompt or prompt == "" then
                return nil
            end

            local pieces = vim.split(prompt, "  ")
            local args = { "rg" }
            if pieces[1] then
                table.insert(args, "-e")
                table.insert(args, pieces[1])
            end

            local rest = (#pieces > 1) and table.concat(pieces, ' ', 2) or nil
            if rest and rest ~= '' then
                local new_string = string.gsub(rest, '%s+', ' ')
                local globs = vim.split(new_string, '%s+')
                --vim.notify(vim.inspect(globs))
                for _, g in ipairs(globs) do
                    if g ~= nil and g ~= '' then
                        table.insert(args, '-g')
                        table.insert(args, g)
                    end
                end
            end

            table.insert(args, '-g')
            table.insert(args, '!.pyi')
            table.insert(args, '-g')
            table.insert(args, '!.yarn')
            table.insert(args, '-g')
            table.insert(args, '!.telescope_history')
            table.insert(args, '-g')
            table.insert(args, '!.html')
            table.insert(args, '-g')
            table.insert(args, '!.pyc')
            table.insert(args, '-g')
            table.insert(args, '!.js')
            table.insert(args, '-g')
            table.insert(args, '!.png')
            if opts.search_dirs and #opts.search_dirs > 0 then
                for _, d in ipairs(type(opts.search_dirs) == 'table' and opts.search_dirs or { opts.search_dirs }) do
                    table.insert(args, d)
                end
            end

            ---@diagnostic disable-next-line: deprecated
            local rawArg = vim.tbl_flatten {
                args,
                { "--color=never", "--no-heading", "--with-filename", "--line-number", "--column", "--smart-case" },
            }
            --vim.notify(table.concat(rawArg, " "))
            return rawArg
        end,
        entry_maker = make_entry.gen_from_vimgrep(opts),
    }
    --vim.notify(vim.inspect(opts))
    pickers.new(opts, {
        debounce = 100,
        prompt_title = opts.prompt_title,
        finder = finder,
        previewer = conf.grep_previewer(opts),
        sorter = require("telescope.sorters").empty(),
        follow = true,
        mappings = {
            n = {
                ['<c-v>'] = 'select_vertical',
                ['<c-t>'] = 'select_tab',
                ['<CR>'] = 'tab_drop',
            },
        },
    }):find()
end

return M
