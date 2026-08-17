-- One entry per language server the lab modules can install.  Which of them a
-- lab actually has depends on the modules its host file imports, so each is
-- enabled only when its binary is on PATH: no lspconfig, and no server
-- configured for a language the lab cannot build.
local servers = {
  nil_ls = {
    cmd = { 'nil' },
    filetypes = { 'nix' },
    root_markers = { 'flake.nix', '.git' },
  },

  lua_ls = {
    cmd = { 'lua-language-server' },
    filetypes = { 'lua' },
    root_markers = { '.luarc.json', '.luarc.jsonc', '.git' },
    settings = {
      Lua = {
        diagnostics = { globals = { 'vim' } },
        telemetry = { enable = false },
      },
    },
  },

  ruff = {
    cmd = { 'ruff', 'server' },
    filetypes = { 'python' },
    root_markers = { 'pyproject.toml', 'ruff.toml', '.git' },
  },

  rust_analyzer = {
    cmd = { 'rust-analyzer' },
    filetypes = { 'rust' },
    root_markers = { 'Cargo.toml', '.git' },
  },

  ts_ls = {
    cmd = { 'typescript-language-server', '--stdio' },
    filetypes = {
      'javascript',
      'javascriptreact',
      'typescript',
      'typescriptreact',
    },
    root_markers = { 'tsconfig.json', 'package.json', '.git' },
  },

  clangd = {
    cmd = { 'clangd' },
    filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda' },
    root_markers = { 'compile_commands.json', '.clangd', '.git' },
  },

  texlab = {
    cmd = { 'texlab' },
    filetypes = { 'tex', 'plaintex', 'bib' },
    root_markers = { '.latexmkrc', '.git' },
  },

  terraform_ls = {
    cmd = { 'terraform-ls', 'serve' },
    filetypes = { 'terraform', 'hcl' },
    root_markers = { '.terraform.lock.hcl', '.git' },
  },
}

for name, config in pairs(servers) do
  if vim.fn.executable(config.cmd[1]) == 1 then
    vim.lsp.config(name, config)
    vim.lsp.enable(name)
  end
end

-- Completion comes from the server through nvim's own omnifunc rather than a
-- completion plugin.  nvim 0.11 upwards already binds K, grn, gra, grr and gri,
-- so there is nothing else to wire up on attach.
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client:supports_method('textDocument/completion') then
      vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
    end
  end,
})
