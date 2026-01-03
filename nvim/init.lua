local fn = vim.fn


-- get shell aliases
vim.g.mapleader = ' '
vim.o.shellcmdflag = '-ilc'

--vim.o.shell = '-lc source ~/.bashrc >/dev/null 2>&1'
vim.g.maplocalleader = ' '
-- Options
vim.opt.relativenumber = false
vim.opt.number = true
vim.opt.smartindent = true
vim.opt.termguicolors = true
vim.o.guicursor = "n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20,a:blinkwait700-blinkoff400-blinkon250-Cursor/lCursor"
vim.o.ttimeoutlen = 0
vim.o.tabstop = 4
vim.o.number = true
vim.o.expandtab = true
vim.o.softtabstop = 4
vim.o.shiftwidth = 4


vim.opt.mouse = 'a'
vim.opt.showmode = false
vim.opt.clipboard = "unnamedplus"



vim.opt.breakindent = true
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.signcolumn = 'yes'
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
vim.cmd [[set notermsync]]
vim.opt.inccommand = 'split'
vim.opt.cursorline = true
vim.opt.scrolloff = 10
vim.opt.hlsearch = true


vim.keymap.set('n', 'p', '"+p', { noremap = true, silent = true })


vim.keymap.set('v', 'p', '"_dP', { noremap = true, silent = true })
vim.keymap.set('n', 'd', '"_d', { noremap = true, silent = true })
vim.keymap.set('v', 'd', '"_d', { noremap = true, silent = true })


local lazypath = fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.loop.fs_stat(lazypath) then
    fn.system({ 'git', 'clone', '--filter=blob:none', 'https://github.com/folke/lazy.nvim.git', '--branch=stable',
        lazypath })
end
vim.opt.rtp:prepend(lazypath)

require('lazy').setup({
    {
        'ibhagwan/fzf-lua',
        -- dependencies and setup for fzf-lua
        config = function()
            -- basic setup
            require('fzf-lua').setup({})
        end,
        require = { 'nvim-tree/nvim-web-devicons' }, -- optional, for file icons
    },
    {
        'stevearc/oil.nvim',
        dependencies = "nvim-mini/mini.icons",
        config = function()
            require("oil").setup({
                default_file_explorer = true,
                keymaps = {
                    ["<C-u>"] = { "actions.parent", mode = "n" },
                }
            })
        end,
    },
    'farmergreg/vim-lastplace',
    {
        'nvim-lualine/lualine.nvim',
        dependencies = { 'nvim-tree/nvim-web-devicons' },
        config = function()
            require('lualine').setup({
                sections = {
                    lualine_b = {
                        {
                            require("noice").api.status.mode.get,
                            cond = require("noice").api.status.mode.has,
                            color = { fg = "#ff9e64" },
                        },
                        'branch'
                    },
                    lualine_c = {
                        {
                            function()
                                return require('mini.icons').get('directory', vim.fn.getcwd()) ..
                                    " " .. vim.fn.fnamemodify(vim.fn.getcwd(), ':~')
                            end,
                            color = 'LualineCwd'
                        },
                        {
                            function()
                                local icon = require('mini.icons').get('filetype', vim.bo.filetype)
                                return icon .. " " .. vim.fn.fnamemodify(vim.fn.expand('%:p'), ':~')
                            end,
                            color = 'LualineCwd'
                        },
                    },
                }
            })
        end,
    },
    {
        'HakonHarnes/img-clip.nvim',
        config = function()
            require('img-clip').setup()
        end,
    },
    {
        '3rd/image.nvim',
        opts = {
            rocks = {
                enabled = false
            }
        },
        config = function()
            require("image").setup({
                integrations = {
                    markdown = {
                        only_render_image_at_cursor = true,
                        max_width = 20,
                        max_height = 20,
                    }
                }
            })
        end,
    },
    'tpope/vim-fugitive',
    {
        'kyazdani42/nvim-tree.lua',
        dependencies = 'kyazdani42/nvim-web-devicons'
    },
    { 'numToStr/Comment.nvim', config = function() require('Comment').setup() end },
    {
        'alexghergh/nvim-tmux-navigation',

    },
    { 'folke/which-key.nvim',  config = function() require('which-key').setup() end },
    {
        'nvim-telescope/telescope.nvim',
        dependencies = { 'nvim-lua/plenary.nvim' },
        config = function()
            local telescope = require('telescope')
            telescope.setup({
                pickers = {
                    find_files = { follow = true },
                },
                path_display = { "smart" },
                extensions = { ['ui-select'] = require('telescope.themes').get_dropdown({}) }
            })
            pcall(telescope.load_extension, 'fzf')
            pcall(telescope.load_extension, 'ui-select')
            pcall(telescope.load_extension, 'live_grep_args')
        end,
    },
    'nvim-telescope/telescope-ui-select.nvim',
    'nvim-telescope/telescope-live-grep-args.nvim',
    { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make', cond = vim.fn.executable('make') == 1 },
    'nvim-pack/nvim-spectre',
    {
        'MunsMan/kitty-navigator.nvim',
        config = function()
            require('kitty-navigator').setup({
                keybindings = {
                    left = "<C-h>",
                    down = "<C-j>",
                    up = "<C-k>",
                    right = "<C-l>",
                },
            })
        end,
    },
    {
        "saghen/blink.cmp",
        tag = "v1.0.0",
        dependencies = { "rafamadriz/friendly-snippets" },

    },
    {
        'hrsh7th/nvim-cmp',
        dependencies = {
            'L3MON4D3/LuaSnip',
            'saadparwaiz1/cmp_luasnip',
            'hrsh7th/cmp-nvim-lsp',
            'hrsh7th/cmp-path',
            'nvim-mini/mini.icons',
            'saghen/blink.cmp'
        },
        config = function()
            local cmp = require('cmp')
            cmp.setup.cmdline(':', {
                mapping = cmp.mapping.preset.cmdline(),
                sources = cmp.config.sources({
                        { name = 'path' }
                    },
                    {
                        { name = 'cmdline' }
                    }
                )
            })
        end,

    },
    {
        "L3MON4D3/LuaSnip",
        build = "make install_jsregexp",
        config = function()
            require('luasnip.loaders.from_vscode').lazy_load()
        end,
    },
    {
        'neovim/nvim-lspconfig',
        dependencies = {
            'williamboman/mason.nvim',
            'williamboman/mason-lspconfig.nvim',
            'WhoIsSethDaniel/mason-tool-installer.nvim',
            "saghen/blink.cmp",

            'j-hui/fidget.nvim',
        },
        event = { 'BufReadPre', 'BufNewFile' },
        config = function()
            require('mason').setup()
            require('mason-tool-installer').setup({
                ensure_installed = { 'stylua', 'lua_ls', 'shellcheck', 'bash-language-server', 'pyright', 'clangd', 'lua-language-server', 'harper-ls' }
            })

            local capabilities = vim.lsp.protocol.make_client_capabilities()

            vim.lsp.config.bashls = {
                cmd = { 'bash-language-server', 'start' },
                filetypes = { 'sh' }
            }
            vim.lsp.enable 'bashls'

            vim.lsp.config['pyright'] = {
                cmd = { 'pyright-langserver', '--stdio' },
                filetypes = { 'python' },
                settings = {
                    inlayHints = {
                        enabled = true,
                        inline = true,
                    },
                    python = { analysis = { typeCheckingMode = 'basic' } }
                },
            }
            vim.lsp.enable('pyright')

            local ok_neodev, neodev = pcall(require, 'neodev')
            if ok_neodev then
                neodev.setup({})
            end

            vim.lsp.config('lua_ls', {
                on_init = function(client)
                    if client.workspace_folders then
                        local path = client.workspace_folders[1].name
                        if
                            path ~= vim.fn.stdpath('config')
                            and (vim.uv.fs_stat(path .. '/.luarc.json') or vim.uv.fs_stat(path .. '/.luarc.jsonc'))
                        then
                            return
                        end
                    end
                    client.config.settings.Lua = vim.tbl_deep_extend('force', client.config.settings.Lua, {
                        runtime = {
                            version = 'LuaJIT',
                            path = {
                                'lua/?.lua',
                                'lua/?/init.lua',
                            },
                        },
                        workspace = {
                            checkThirdParty = false,
                            library = {
                                vim.env.VIMRUNTIME,
                                '${3rd}/luv/library',
                                '${3rd}/busted/library'
                            }
                        }
                    })
                end,
                settings = {
                    Lua = { hint = { enable = true } }
                }
            })
            vim.lsp.enable('lua_ls')

            vim.lsp.config['clangd'] = {
                cmd = { 'clangd', '--background-index', '--clang-tidy', '--query-driver=clang++' },
                settings = {
                    clangd = {
                        inlayHints = {
                            enabled = true,
                            inline = true,
                        },
                    },
                },
                filetypes = { 'c', 'cpp', 'objc', 'objcpp' },
            }
            vim.lsp.enable('clangd')

            vim.lsp.config['harper_ls'] = {
                cmd = { 'harper-ls', '--stdio' },
                filetypes = { 'text', 'txt', 'md', 'markdown' },
                settings = {
                    ["harper-ls"] = {},
                },
            }
            vim.lsp.enable('harper_ls')

            vim.api.nvim_create_autocmd('BufWritePre', {
                pattern = { '**.bash', '**.sh', '**.bashrc', '**.bash_profile' },
                desc = 'Format Bash on save',
                callback = function()
                    vim.lsp.buf.format()
                end,
            })

            vim.api.nvim_create_autocmd('BufWritePre', {
                pattern = '*.lua',
                desc = 'Format Lua on save',
                callback = function()
                    vim.lsp.buf.format()
                end,
            })

            vim.api.nvim_create_autocmd('BufWritePre', {
                pattern = { '*.cpp', '*.h' },
                desc = 'Format C/C++ on save',
                callback = function()
                    vim.lsp.buf.format()
                end,
            })
        end,
    },
    'folke/neodev.nvim',
    'stevearc/conform.nvim',
    'akinsho/toggleterm.nvim',
    'sam4llis/nvim-tundra',
    {
        'numToStr/Comment.nvim',
    },
    {
        'echasnovski/mini.nvim',
        config = function()
            require('mini.ai').setup({ n_lines = 500 })
            require('mini.surround').setup()
        end,
    },
    'windwp/nvim-autopairs',
    'folke/tokyonight.nvim',
    'bluz71/vim-moonfly-colors',
    --'flazz/vim-colorschemes',
    'python-lsp/python-lsp-server',
    {
        'folke/flash.nvim',
        config = function()
            require("flash").setup()
            vim.api.nvim_set_hl(0, "FlashLabel", { fg = "#EEF5FF", bg = "#A25772", bold = true })
        end,
    },
    -- {
    --     'nvim-treesitter/nvim-treesitter',
    --     build = ':TSUpdate',
    --     lazy = false,
    --     priority = 100,
    --
    --     config = function()
    --         require('nvim-treesitter.configs').setup({
    --             ensure_installed = { "c", "lua", "vim", "cpp", "java", "bash", "markdown", "markdown_inline" },
    --             sync_install = false,
    --             highlight = {
    --                 enable = true,
    --             },
    --         })
    --     end,
    -- },
    {
        'nvim-treesitter/nvim-treesitter-textobjects',
        dependencies = { 'nvim-treesitter/nvim-treesitter' },
    },
    {
        'nvim-tree/nvim-web-devicons',
        config = function()
            require('nvim-web-devicons').setup({
                override = {
                    log = {
                        icon = "",
                        color = "#b07219",
                        name = "log",
                    },
                },
            })
        end,
    },
    {
        'folke/noice.nvim',
        dependencies = { "MunifTanjim/nui.nvim", "rcarriga/nvim-notify" },
        config = function()
            require("notify").setup({
                background_colour = "#000000",
            })
            require('noice').setup({

                views = {
                    vsplit = {
                        enter = false,
                    },
                },

                routes = {
                    {
                        view = "split",
                        filter = { event = "msg_show", min_height = 5 },
                    },
                    {
                        filter = {
                            event = { "msg_show", "notify" },
                            any = {
                                { find = "E85: There is no listed buffer" },
                                { find = ".*your config is not supported with lazy.nvim.*$" },
                                { find = "E486: Pattern not found: ?$" },
                                { find = "E21: Cannot make changes, 'modifiable' is off" },
                                { find = "E490: No fold found" },
                                { find = "Already at oldest change" },
                                { find = "; after #%d+" },
                                { find = "; before #%d+" },
                                { find = "^%d+ fewer lines;?" },
                                { find = "^%d+ more lines;?" },
                                { find = "^%d+ line lesses;?" },
                                { find = ".*Pattern not found.*$" },
                                { find = "^Content is not an.*$" },
                                { find = '^%d+ lines .ed %d+ times?$' },
                                { find = '^%d+ lines yanked$' },
                            },
                        },
                        opts = { skip = true },
                    },
                },
                lsp = {
                    override = {
                        ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
                        ["vim.lsp.util.stylize_markdown"] = true,
                        ["cmp.entry.get_documentation"] = true,
                    },
                    signature = { enabled = true },
                    message = { enabled = true },
                    documentation = { enabled = true },
                },
                presets = {
                    bottom_search = true,
                    command_palette = true,
                    long_message_to_split = true,
                    inc_rename = false,
                    lsp_doc_border = true,
                },
            })
        end,
    },
    {
        'MeanderingProgrammer/render-markdown.nvim',
        dependencies = { 'nvim-tree/nvim-web-devicons' },
        config = function()
            require('render-markdown').setup({
                code = {
                    enabled = true,
                    render_modes = true,
                    language_icon = true,
                    language_name = true
                },
                document = {
                    enabled = true,
                    render_modes = true
                },
            })
        end,
    },
    {
        'windwp/nvim-autopairs',
        config = function()
            local ok, npairs = pcall(require, 'nvim-autopairs')
            if not ok then
                vim.notify('nvim-autopairs not found', vim.log.levels.WARN)
                return
            end
            npairs.setup({
                disable_filetype = { 'TelescopePrompt' },
                enable_check_bracket_line = true,
                ignored_next_char = '[%w%.]'
            })
        end,
    },
    {
        'nvim-treesitter/nvim-treesitter-textobjects',
        branch = 'main',
        dependencies = { 'nvim-treesitter/nvim-treesitter' },
    },
    { -- Highlight, edit, and navigate code
        'nvim-treesitter/nvim-treesitter',
        build = ':TSUpdate',
        branch = 'main',
        --main = 'nvim-treesitter.configs', -- Sets main module to use for opts
        -- [[ Configure Treesitter ]] See `:help nvim-treesitter`
        opts = {
            ensure_installed = { 'bash', 'c', 'diff', 'html', 'lua', 'luadoc', 'markdown', 'markdown_inline', 'query', 'vim', 'vimdoc' },
            -- Autoinstall languages that are not installed
            auto_install = true,
            highlight = {
                enable = true,
                -- Some languages depend on vim's regex highlighting system (such as Ruby) for indent rules.
                --  If you are experiencing weird indenting issues, add the language to
                --  the list of additional_vim_regex_highlighting and disabled languages for indent.
                additional_vim_regex_highlighting = { 'ruby' },
            },
            indent = { enable = true, disable = { 'ruby' } },
        },
        -- There are additional nvim-treesitter modules that you can use to interact
        -- with nvim-treesitter. You should go explore a few and see what interests you:
        --
        --    - Incremental selection: Included, see `:help nvim-treesitter-incremental-selection-mod`
        --    - Show your current context: https://github.com/nvim-treesitter/nvim-treesitter-context
        --    - Treesitter + textobjects: https://github.com/nvim-treesitter/nvim-treesitter-textobjects
    },
})
vim.cmd [[colorscheme moonfly]]

vim.keymap.set('n', '<leader>pi', function()
    function Get_dir_path()
        local cmd = { 'bash', '-lc', 'source ~/.bash_profile >/dev/null 2>&1 && ' ..
        'echo $ASSET_PICTURES_DIRECTORY_GLOBAL' }
        local ret = vim.system(cmd):wait()
        if ret.code ~= 0 then
            vim.notify("Failed running command:" .. cmd, vim.log.levels.ERROR)
            return nil
        end
        return vim.fn.expand(ret.stdout)
    end

    local asset_path = Get_dir_path()
    if not asset_path then
        vim.notify("Failed to find directory", vim.log.levels.ERROR)
        return
    end
    asset_path = asset_path:gsub("[\n\r]", "")
    require('img-clip').paste_image({
        use_absolute_path = true,
        dir_path = asset_path,
        copy_images = true,
    })
end, { desc = 'Paste Images Markdown' })


do
    vim.keymap.set("n", "<space>to", function()
        -- 1️⃣ Find a terminal buffer and its window
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal" then
                if win and vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_hide(win)
                    return
                end
                break
            end
        end

        -- 3️⃣ If the terminal buffer exists but is hidden, show it in a new split
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal" then
                vim.cmd("botright split")
                vim.api.nvim_win_set_buf(0, buf)
                vim.cmd.wincmd("J")
                vim.api.nvim_win_set_height(0, 15)
                return
            end
        end

        -- create one - does not exist
        vim.cmd("botright split")
        vim.cmd.term()
        vim.cmd.wincmd("J")
        vim.api.nvim_win_set_height(0, 15)
    end)
end

--[[
    this assume terminal is at bottom so makes sense to invert the logic
]]
vim.keymap.set({ 'n' }, '<M-k>', function()
    vim.cmd('resize -5')
end, { noremap = true, silent = true, desc = 'Increase window height by 5 (normal mode)' })

vim.keymap.set({ 'n' }, '<M-j>', function()
    vim.cmd('resize +5')
end, { noremap = true, silent = true, desc = 'Decrease window height by 5 (normal mode)' })
--
--
vim.keymap.set({ 't' }, '<M-k>', function()
    vim.cmd('resize +5')
end, { noremap = true, silent = true, desc = 'Increase window height by 5 (terminal mode)' })

vim.keymap.set({ 't' }, '<M-j>', function()
    vim.cmd('resize -5')
end, { noremap = true, silent = true, desc = 'Decrease window height by 5 (terminal mode)' })


-- vim.keymap.set({ 'n', 't' }, '<C-h>', function() require('kitty-navigator').navigateLeft() end,
--     { silent = true, desc = 'Move left a Split' })
-- vim.keymap.set({ 'n', 't' }, '<C-j>', function() require('kitty-navigator').navigateDown() end,
--     { silent = true, desc = 'Move down a Split' })
-- vim.keymap.set({ 'n', 't' }, '<C-k>', function() require('kitty-navigator').navigateUp() end,
--     { silent = true, desc = 'Move up a Split', })
-- vim.keymap.set({ 'n', 't' }, '<C-l>', function() require('kitty-navigator').navigateRight() end,
--     { silent = true, desc = 'Move right a Split' })


vim.keymap.set("n", "<space>to", function()
    -- 1️⃣ Find a terminal buffer and its window
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal" then
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_hide(win)
                return
            end
            break
        end
    end

    -- 3️⃣ If the terminal buffer exists but is hidden, show it in a new split
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal" then
            vim.cmd("botright split")
            vim.api.nvim_win_set_buf(0, buf)
            vim.cmd.wincmd("J")
            vim.api.nvim_win_set_height(0, 15)
            return
        end
    end

    -- create one - does not exist
    vim.cmd("botright split")
    vim.cmd.term()
    vim.cmd.wincmd("J")
    vim.api.nvim_win_set_height(0, 15)
end)





vim.api.nvim_create_autocmd({ "TermOpen" }, {
    group = vim.api.nvim_create_augroup("custom-term-open-source", { clear = true }),
    callback = function()
        vim.cmd(":startinsert")
        vim.opt.number = false
        vim.opt.relativenumber = false
        vim.cmd [[hi BlackBg guibg=black]]
        vim.cmd [[set winhighlight=Normal:BlackBg]]
        vim.cmd [[setlocal nocursorline]]
        vim.api.nvim_chan_send(vim.b.terminal_job_id, "bashr\r")
    end,
})

vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = vim.api.nvim_create_augroup("custom-term-enter", { clear = true }),
    callback = function()
        if vim.api.nvim_get_option_value('buftype', { buf = vim.api.nvim_get_current_buf() }) == "terminal" then
            vim.cmd(":startinsert")
        end
    end,
})



-- annoying errors where termnal stays open - invisible buffer
vim.api.nvim_create_autocmd("ExitPre", {
    pattern = "*",
    callback = function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal" then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
    end,
})

-- nvim-autopairs configuration loaded after plugins
-- This file ensures autopairs is configured even if plugin load order changes.

local use_marksman = false
if use_marksman then
    local mark_capabilities = vim.lsp.protocol.make_client_capabilities()


    vim.lsp.config('marksman', {
        -- on_attach function to set keymaps and other buffer-specific options when the LSP attaches
        capabilities = mark_capabilities,
        on_attach = function(client, bufnr)
            -- Example keymaps:
            -- vim.api.nvim_buf_set_keymap(bufnr, 'n', 'gd', '<cmd>lua vim.lsp.buf.definition()<CR>', {noremap = true, silent = true})
            -- vim.api.nvim_buf_set_keymap(bufnr, 'n', 'gr', '<cmd>lua vim.lsp.buf.references()<CR>', {noremap = true, silent = true})
            -- Add other on_attach logic here
        end,
        -- Optional: Add specific settings for marksman.
        -- The default configuration often works fine with Mason.
        settings = {
            -- Example: You can adjust settings if needed
            -- marksman.trace.server = "off"
        },
    })

    vim.lsp.enable('marksman')


    vim.api.nvim_create_autocmd('BufWritePre', {
        pattern = '*.lua',
        desc = 'Format Lua with lua_ls on save',
        callback = function()
            vim.lsp.buf.format()
        end,
    })
end


--[[
    this assume terminal is at bottom so makes sense to invert the logic
]]
vim.keymap.set({ 'n' }, '<M-k>', function()
    vim.cmd('resize -5')
end, { noremap = true, silent = true, desc = 'Increase window height by 5 (normal mode)' })

vim.keymap.set({ 'n' }, '<M-j>', function()
    vim.cmd('resize +5')
end, { noremap = true, silent = true, desc = 'Decrease window height by 5 (normal mode)' })
--
--
vim.keymap.set({ 't' }, '<M-k>', function()
    vim.cmd('resize +5')
end, { noremap = true, silent = true, desc = 'Increase window height by 5 (terminal mode)' })

vim.keymap.set({ 't' }, '<M-j>', function()
    vim.cmd('resize -5')
end, { noremap = true, silent = true, desc = 'Decrease window height by 5 (terminal mode)' })


vim.keymap.set({ 'n', 't' }, '<C-h>', function() require('kitty-navigator').navigateLeft() end,
    { silent = true, desc = 'Move left a Split' })
vim.keymap.set({ 'n', 't' }, '<C-j>', function() require('kitty-navigator').navigateDown() end,
    { silent = true, desc = 'Move down a Split' })
vim.keymap.set({ 'n', 't' }, '<C-k>', function() require('kitty-navigator').navigateUp() end,
    { silent = true, desc = 'Move up a Split', })
vim.keymap.set({ 'n', 't' }, '<C-l>', function() require('kitty-navigator').navigateRight() end,
    { silent = true, desc = 'Move right a Split' })

-- vim.lsp.config['harper_ls'] = {
-- 	cmd = { 'harper-ls', '--stdio' },
-- 	filetypes = { 'text', 'txt', 'md', 'markdown' }, -- add any filetypes you edit
-- 	settings = {
-- 		["harper-ls"] = {
-- 			-- set your user dict path if needed
-- 			-- userDictPath = vim.fn.expand("~/.harper-dictionary.txt"),
-- 		},
-- 	},
-- }
--
-- vim.lsp.enable('harper_ls')
local nvim_tmux_nav = require('nvim-tmux-navigation')

nvim_tmux_nav.setup({})

vim.keymap.set('n', "<C-h>", nvim_tmux_nav.NvimTmuxNavigateLeft)
vim.keymap.set('n', "<C-j>", nvim_tmux_nav.NvimTmuxNavigateDown)
vim.keymap.set('n', "<C-k>", nvim_tmux_nav.NvimTmuxNavigateUp)
vim.keymap.set('n', "<C-l>", nvim_tmux_nav.NvimTmuxNavigateRight)
