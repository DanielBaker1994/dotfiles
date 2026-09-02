local fn = vim.fn

vim.g.mapleader = ' '
vim.o.shellcmdflag = '-lc'

-- :terminal starts bash as a LOGIN shell so it reads ~/.bash_profile (PATH,
-- DOTDIR, FZF_DEFAULT_OPTS, starship, ...) by itself — no manual `source` and
-- nothing typed into the terminal after it opens.
if vim.o.shell:match('bash$') then
    vim.o.shell = vim.o.shell .. ' --login'
end

vim.g.maplocalleader = ' '
-- Options
vim.opt.relativenumber = false
vim.opt.number = true
vim.opt.smartindent = true
vim.opt.termguicolors = true
vim.o.guicursor = "n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20,a:blinkwait700-blinkoff400-blinkon250-Cursor/lCursor"
vim.o.ttimeoutlen = 0
-- <Esc><Esc> (clear notifications) exists alongside <Esc> (clear search
-- highlight), so keep the ambiguity wait short: a single Esc fires after at
-- most this many ms instead of the 1000ms default.
vim.o.timeoutlen = 300
vim.o.tabstop = 4
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
vim.opt.laststatus = 2

_G.UserWinbarDirectory = function()
    local ok, dir = pcall(function()
        local winid = vim.g.actual_curwin and tonumber(vim.g.actual_curwin) or vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(winid)
        if vim.bo[buf].buftype == 'terminal' then
            return ''
        end

        local winnr = vim.fn.win_id2win(winid)
        local tabnr = vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(winid))
        return vim.fn.fnamemodify(vim.fn.getcwd(winnr, tabnr), ':~')
    end)

    return ok and dir or ''
end

vim.opt.winbar = '%{%v:lua.UserWinbarDirectory()%}'

local function lualine_file_path()
    local ok, text = pcall(function()
        local winid = vim.g.actual_curwin and tonumber(vim.g.actual_curwin) or vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(winid)
        local bo = vim.bo[buf]

        if bo.buftype == 'terminal' then
            return '[terminal]'
        end

        if bo.filetype == 'oil' then
            return '[oil]'
        end

        local name = vim.api.nvim_buf_get_name(buf)
        if name == '' then
            return '[No Name]'
        end

        return vim.fn.fnamemodify(name, ':~')
    end)

    return ok and text or ''
end

vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('user-winbar', { clear = true }),
    pattern = { 'TelescopePrompt', 'TelescopeResults', 'TelescopePreviewer' },
    callback = function()
        vim.opt_local.winbar = ''
    end,
})

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

-- Guard so a <leader>rl reload doesn't re-invoke lazy.setup (which would just
-- warn "Re-sourcing your config is not supported"). On reload the plugins are
-- already loaded; only options/keymaps/autocmds/user modules get re-applied.
if not vim.g.lazy_did_setup then
    require('lazy').setup({
        {
            'stevearc/oil.nvim',
            dependencies = "nvim-mini/mini.icons",
            config = function()
                require("oil").setup({
                    default_file_explorer = true,
                    keymaps = {
                        ["<C-u>"] = { "actions.parent", mode = "n" },
                        ["<C-h>"] = false,
                        ["<C-l>"] = false,
                        ["gr"] = "actions.refresh",
                    }
                })
            end,
        },
        'farmergreg/vim-lastplace',
        {
            'cosminadrianpopescu/vim-sql-workbench',
            cmd = {
                'SWSqlBufferConnect', 'SWSqlExecuteCurrent', 'SWSqlExecuteSelected',
                'SWSqlExecuteAll', 'SWDbExplorer', 'SWSqlBufferDisconnect',
            },
            config = function()
                -- this  sqlwbconsole.sh file ships with sql work bench, it is the script to launch the app
                vim.g.sw_exe = 'sqlwbconsole.sh'
                vim.g.sw_config_dir = vim.fn.stdpath('config') .. '/sqlworkbench'
                vim.g.sw_cache = vim.fn.stdpath('cache') .. '/sw'
                -- vim.g.sw_tmp = '/tmp'
            end,
        },
        {
            'nvim-lualine/lualine.nvim',
            dependencies = { 'nvim-tree/nvim-web-devicons' },
            config = function()
                require('lualine').setup({
                    options = {
                        globalstatus = false,
                        disabled_filetypes = { 'TelescopePrompt' },
                    },
                    sections = {
                        lualine_a = { 'mode' },
                        lualine_b = { 'branch' },
                        lualine_c = {
                            {
                                lualine_file_path,
                                color = 'LualineCwd',
                                separator = '',
                            },
                        },
                        lualine_x = {},
                        lualine_y = {},
                        lualine_z = {},
                    },
                    inactive_sections = {
                        lualine_a = {},
                        lualine_b = {},
                        lualine_c = {
                            {
                                lualine_file_path,
                                color = 'LualineCwd',
                                separator = '',
                            },
                        },
                        lualine_x = {},
                        lualine_y = {},
                        lualine_z = {},
                    },
                    tabline = {},
                    extensions = {},
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
            -- Interactive git history: commit list panel + diffs.
            -- In the panel: <CR> opens a commit diff, <tab>/<s-tab> cycle,
            -- <C-d> opens the commit in its own Diffview, y yanks the hash,
            -- g! opens the options panel to change git-log filters on the fly.
            'sindrets/diffview.nvim',
            cmd = { 'DiffviewOpen', 'DiffviewFileHistory' },
        },
        {
            'lewis6991/gitsigns.nvim',
            event = { 'BufReadPre', 'BufNewFile' },
            opts = {},
        },
        { 'numToStr/Comment.nvim',          config = function() require('Comment').setup() end },
        {
            'folke/todo-comments.nvim',
            dependencies = { 'nvim-treesitter/nvim-treesitter' },
            config = function() require('todo-comments').setup() end,
        },
        {
            'RRethy/vim-illuminate',
            config = function()
                require('illuminate').configure({ under_cursor = true })
            end,
        },
        {
            'szw/vim-maximizer',
            keys = {
                { '<C-w>z', '<cmd>MaximizerToggle<CR>', desc = 'Zoom current window (toggle)' },
            },
        },
        {
            'folke/which-key.nvim',
            config = function()
                require('which-key').setup()
                require('which-key').add({
                    { '<leader>s', group = 'Search' },
                    { '<leader>g', group = 'Git' },
                    { '<leader>d', group = 'Diagnostics / Dotfiles' },
                    { '<leader>m', group = 'Markdown / Messages' },
                    { '<leader>p', group = 'Paste / Parent' },
                    { '<leader>y', group = 'Yank' },
                    { '<leader>c', group = 'Code / Config' },
                    { '<leader>o', group = 'Oil' },
                    { '<leader>r', group = 'Reload' },
                })
            end
        },
        {
            'nvim-telescope/telescope.nvim',
            dependencies = { 'nvim-lua/plenary.nvim' },
            config = function()
                local telescope = require('telescope')
                local telescope_actions = require('telescope.actions')
                telescope.setup({
                    defaults = {
                        mappings = {
                            n = {
                                ['<Esc>'] = {
                                    telescope_actions.close,
                                    type = 'action',
                                    opts = { nowait = true },
                                },
                            },
                        },
                    },
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
            "saghen/blink.cmp",
            tag = "v1.0.0",
            dependencies = { "rafamadriz/friendly-snippets", "L3MON4D3/LuaSnip" },
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
                    ensure_installed = { 'stylua', 'lua_ls', 'shellcheck', 'bash-language-server', 'pyright', 'clangd', 'lua-language-server', --[[ 'harper-ls' ]] }
                })

                local capabilities = vim.lsp.protocol.make_client_capabilities()
                local ok_blink, blink_cmp = pcall(require, 'blink.cmp')
                if ok_blink and blink_cmp.get_lsp_capabilities then
                    capabilities = blink_cmp.get_lsp_capabilities(capabilities)
                end
                vim.lsp.config['*'] = { capabilities = capabilities }

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

                -- vim.lsp.config['harper_ls'] = {
                --     cmd = { 'harper-ls', '--stdio' },
                --     filetypes = { 'text', 'txt', 'md', 'markdown' },
                --     settings = {
                --         ["harper-ls"] = {},
                --     },
                -- }
                -- vim.lsp.enable('harper_ls')

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
        {
            'echasnovski/mini.nvim',
            config = function()
                require('mini.ai').setup({ n_lines = 500 })
                require('mini.surround').setup()
            end,
        },
        {
            'catppuccin/nvim',
            name = 'catppuccin',
            priority = 1000,
            opts = { flavour = 'mocha' },
        },
        {
            'akinsho/toggleterm.nvim',
            version = '*',
            config = function()
                require('toggleterm').setup({
                    direction = 'horizontal',
                    size = 15,
                    shade_terminals = false,
                })
                local Terminal = require('toggleterm.terminal').Terminal
                local lazygit = Terminal:new({
                    cmd = 'lazygit',
                    direction = 'float',
                    float_opts = { border = 'curved' },
                })
                function _G.LazyGitToggle()
                    local dir = vim.fn.expand('%:p:h')
                    if dir == '' then
                        dir = vim.fn.getcwd()
                    end
                    lazygit.dir = dir
                    lazygit:toggle()
                end

                vim.keymap.set('n', '<leader>lg', _G.LazyGitToggle, { desc = 'Toggle LazyGit' })
            end,
        },
        {
            'folke/flash.nvim',
            config = function()
                require("flash").setup()
                vim.api.nvim_set_hl(0, "FlashLabel", { fg = "#EEF5FF", bg = "#A25772", bold = true })
            end,
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
                                    { find = "DB: Query.*$" },
                                    { find = "DB: Running query..." },
                                    { find = ".*your config is not supported with lazy.nvim.*$" },
                                    { find = ".*L,.*B written*$" },
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
        {
            'nvim-treesitter/nvim-treesitter',
            build = ':TSUpdate',
            branch = 'main',
            opts = {
                ensure_installed = { 'bash', 'c', 'diff', 'html', 'lua', 'luadoc', 'markdown', 'markdown_inline', 'query', 'vim', 'vimdoc' },
                auto_install = true,
                highlight = {
                    enable = true,
                    -- ruby indent rules depend on vim's regex highlighting, not treesitter
                    additional_vim_regex_highlighting = { 'ruby' },
                },
                indent = { enable = true, disable = { 'ruby' } },
            },
        },
    })
end -- if not vim.g.lazy_did_setup
vim.cmd.colorscheme('catppuccin-mocha')

vim.keymap.set('n', '<leader>pi', function()
    -- ASSET_PICTURES_DIRECTORY_GLOBAL is fetched/cached by the bash_external
    -- module (see lua/bash_external/asset_pictures_dir.lua).
    local asset_path = require('bash_external.asset_pictures_dir').get()
    if not asset_path or asset_path == '' then
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

local user_term_buf

local function user_term_alive(buf)
    if buf == nil or not vim.api.nvim_buf_is_valid(buf) then return false end
    if vim.api.nvim_get_option_value("buftype", { buf = buf }) ~= "terminal" then return false end
    local ok, chan = pcall(function() return vim.bo[buf].channel end)
    if not ok or not chan or chan == 0 then return false end
    return vim.fn.jobwait({ chan }, 0)[1] == -1 -- -1 = job still running
end

function _G.UserTermToggle()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal" then
            vim.api.nvim_win_hide(win)
            return
        end
    end

    if not user_term_alive(user_term_buf) then
        user_term_buf = nil
    end

    vim.cmd("botright split")
    if user_term_buf then
        vim.api.nvim_win_set_buf(0, user_term_buf)
    else
        vim.cmd.term()
        user_term_buf = vim.api.nvim_get_current_buf()
    end
    vim.cmd.wincmd("J")
    vim.api.nvim_win_set_height(0, 15)
    vim.cmd("startinsert")
end

vim.keymap.set("n", "<space>to", _G.UserTermToggle, { desc = "Toggle terminal" })

vim.api.nvim_create_autocmd("TermClose", {
    group = vim.api.nvim_create_augroup("user-term-close-quit", { clear = true }),
    callback = function(args)
        if args.buf and vim.api.nvim_buf_is_valid(args.buf) then
            pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
        end
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            local name = vim.api.nvim_buf_get_name(b)
            local bt = vim.bo[b].buftype
            -- Only LISTED buffers keep nvim alive. :bd unlists a buffer but
            -- leaves it registered with its name, so hidden/unlisted leftovers
            -- (the "background no-name buffer") would otherwise block the quit.
            if bt ~= "terminal" and vim.bo[b].buflisted
                and name ~= "" and not name:match("^oil://") then
                return
            end
        end
        vim.cmd("qa!")
    end,
})

-- M-hjkl resize: resize the vim split, EXCEPT when it would be meaningless —
-- on panel-like buffers (diffview panels, quickfix, oil, ...) or when nvim has
-- a single window — then resize the surrounding tmux pane instead.
local user_resize_panel_fts = {
    DiffviewFiles = true,
    DiffviewFileHistory = true, -- history panel AND the g! options panel
    qf = true,
    oil = true,
    help = true,
    TelescopePrompt = true,
    TelescopeResults = true,
    lazy = true,
    mason = true,
}

local function user_smart_resize(kind)
    local vim_cmds = { up = 'resize -5', down = 'resize +5', left = 'vertical resize -5', right = 'vertical resize +5' }
    local tmux_flags = { up = '-U', down = '-D', left = '-L', right = '-R' }

    local single_win = #vim.api.nvim_tabpage_list_wins(0) == 1
    if vim.env.TMUX and vim.env.TMUX_PANE and (single_win or user_resize_panel_fts[vim.bo.filetype]) then
        vim.fn.system({ 'tmux', 'resize-pane', '-t', vim.env.TMUX_PANE, tmux_flags[kind], '5' })
        return
    end
    vim.cmd(vim_cmds[kind])
end

vim.keymap.set({ 'n' }, '<M-k>', function() user_smart_resize('up') end,
    { noremap = true, silent = true, desc = 'Resize up (vim split or tmux pane)' })
vim.keymap.set({ 'n' }, '<M-j>', function() user_smart_resize('down') end,
    { noremap = true, silent = true, desc = 'Resize down (vim split or tmux pane)' })
vim.keymap.set({ 'n' }, '<M-h>', function() user_smart_resize('left') end,
    { noremap = true, silent = true, desc = 'Resize left (vim split or tmux pane)' })
vim.keymap.set({ 'n' }, '<M-l>', function() user_smart_resize('right') end,
    { noremap = true, silent = true, desc = 'Resize right (vim split or tmux pane)' })

--[[
    this assume terminal is at bottom so makes sense to invert the logic
]]
vim.keymap.set({ 't' }, '<M-k>', function()
    vim.cmd('resize +5')
end, { noremap = true, silent = true, desc = 'Increase window height by 5 (terminal mode)' })

vim.keymap.set({ 't' }, '<M-j>', function()
    vim.cmd('resize -5')
end, { noremap = true, silent = true, desc = 'Decrease window height by 5 (terminal mode)' })

vim.api.nvim_create_autocmd({ "TermOpen" }, {
    group = vim.api.nvim_create_augroup("custom-term-open-source", { clear = true }),
    callback = function()
        vim.cmd(":startinsert")
        vim.opt.number = false
        vim.opt.relativenumber = false
        vim.opt_local.winbar = ''
        vim.cmd [[setlocal nocursorline]]
        -- env comes from the login shell itself (see vim.o.shell above) — the
        -- old chan_send of `source ~/.bash_profile` was racy and re-ran the
        -- whole profile on every terminal open.
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



-- Clean up DEAD terminal buffers only (invisible leftovers). Never delete a
-- live shell — that used to force a respawn + re-source of ~/.bash_profile on
-- the next <space>to, since ExitPre also fires when preview windows close
-- (inccommand = 'split' does that on every substitution preview).
vim.api.nvim_create_autocmd("ExitPre", {
    group = vim.api.nvim_create_augroup("custom-term-cleanup", { clear = true }), -- clear: survives <leader>rl reloads without duplicating
    pattern = "*",
    callback = function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal"
                and not user_term_alive(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
                if buf == user_term_buf then user_term_buf = nil end
            end
        end
    end,
})

-- C-h/j/k/l: move between nvim splits; at a split edge, hand control to tmux.
-- Uses a direct `tmux select-pane` call (no key echo) so it can't loop with
-- tmux.conf's `is_vim` forwarding. The list-form vim.fn.system avoids a shell
-- spawn, which keeps the nvim -> pane hop snappy.
local tmux_dir = { h = 'L', j = 'D', k = 'U', l = 'R' }
local function tmux_nav(dir)
    local winnr = vim.fn.winnr()
    pcall(vim.cmd, 'wincmd ' .. dir)
    if winnr == vim.fn.winnr() and vim.env.TMUX then
        local socket = vim.fn.split(vim.env.TMUX, ',')[1]
        vim.fn.system({ 'tmux', '-S', socket, 'select-pane', '-' .. tmux_dir[dir] })
    end
end

for _, dir in ipairs({ 'h', 'j', 'k', 'l' }) do
    vim.keymap.set('n', '<C-' .. dir .. '>', function() tmux_nav(dir) end)
    -- Same navigation from the built-in terminal (<space>to), so you can jump
    -- to the tmux pane above/below/left/right just like from a normal pane.
    -- Tradeoff (requested): in the terminal shell C-h no longer acts as
    -- readline backspace and C-l no longer clears the screen — backspace still
    -- works, it sends DEL (C-?), not C-h.
    vim.keymap.set('t', '<C-' .. dir .. '>', function() tmux_nav(dir) end)
end

-- Same zoom (<C-w>z) from inside a terminal so the key is consistent with
-- normal buffers. The plugin's `normal! ze` can't run from terminal mode, so
-- exit to normal mode first, toggle, then re-enter the terminal. Tradeoff: in
-- the shell C-w + z is intercepted (bash C-w alone still deletes a word).
vim.keymap.set('t', '<C-w>z', '<C-\\><C-n>:MaximizerToggle<CR>i',
    { desc = 'Zoom current window (toggle)' })
