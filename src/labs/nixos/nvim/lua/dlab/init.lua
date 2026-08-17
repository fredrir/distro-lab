local o = vim.opt

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

o.number = true
o.relativenumber = true
o.signcolumn = 'yes'
o.cursorline = true
o.scrolloff = 4
o.wrap = false
o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.smartindent = true
o.ignorecase = true
o.smartcase = true
o.undofile = true
o.splitright = true
o.splitbelow = true
o.mouse = 'a'
o.updatetime = 250
o.completeopt = 'menuone,noselect,popup'
o.winborder = 'rounded'

-- A lab has no display server and nvim will not pick a provider on its own, so
-- route the + register through OSC 52: a yank travels back over the SSH
-- connection to the clipboard of the terminal that opened it.  Paste answers
-- from the unnamed register on purpose rather than querying the terminal, which
-- would make every p wait on a reply that a terminal denying clipboard reads
-- never sends.
local has_osc52, osc52 = pcall(require, 'vim.ui.clipboard.osc52')
if has_osc52 then
  local function unnamed()
    return vim.fn.getreg('"', 1, true)
  end

  vim.g.clipboard = {
    name = 'OSC 52',
    copy = { ['+'] = osc52.copy('+'), ['*'] = osc52.copy('*') },
    paste = { ['+'] = unnamed, ['*'] = unnamed },
  }

  o.clipboard = 'unnamedplus'
end

vim.diagnostic.config({
  severity_sort = true,
  virtual_text = true,
})

require('catppuccin').setup({ flavour = 'mocha' })
vim.cmd.colorscheme('catppuccin')

require('gitsigns').setup()

require('fzf-lua').setup({})
require('fzf-lua').register_ui_select()

-- nvim bundles parsers for five languages; the rest arrive as a pack plugin
-- from the flake, queries included, so starting treesitter per buffer is all
-- that is left to do.  pcall because a filetype without a parser is normal.
vim.api.nvim_create_autocmd('FileType', {
  callback = function(args)
    pcall(vim.treesitter.start, args.buf)
  end,
})

local map = vim.keymap.set
local function pick(name)
  return function()
    require('fzf-lua')[name]()
  end
end

map('n', '<Esc>', '<cmd>nohlsearch<cr>')
map('n', '<leader>w', '<cmd>write<cr>', { desc = 'Write' })
map('n', '<leader>e', '<cmd>Explore<cr>', { desc = 'Explore' })

map('n', '<leader>ff', pick('files'), { desc = 'Find files' })
map('n', '<leader>fg', pick('live_grep'), { desc = 'Grep' })
map('n', '<leader>fb', pick('buffers'), { desc = 'Buffers' })
map('n', '<leader>fh', pick('helptags'), { desc = 'Help' })
map('n', '<leader>fd', pick('diagnostics_document'), { desc = 'Diagnostics' })
map('n', '<leader>fr', pick('resume'), { desc = 'Resume picker' })
map('n', '<leader>gs', pick('git_status'), { desc = 'Git status' })

map('n', '<leader>lf', function()
  vim.lsp.buf.format()
end, { desc = 'Format' })

map('t', '<Esc><Esc>', '<C-\\><C-n>')

require('dlab.lsp')
