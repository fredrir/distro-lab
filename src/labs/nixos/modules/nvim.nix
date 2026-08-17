{
  lib,
  pkgs,
  spec,
  ...
}:

let
  enabled = spec.kind == "project";

  # Core nvim bundles parsers for five languages.  These are the rest of what
  # the labs actually hold — the derivation carries each grammar's highlight
  # queries along with it, which is the half core nvim does not have.
  grammars =
    g: with g; [
      bash
      c
      cpp
      css
      diff
      git_config
      git_rebase
      gitcommit
      hcl
      html
      javascript
      json
      latex
      lua
      make
      markdown
      markdown_inline
      nix
      python
      query
      regex
      rust
      sql
      toml
      tsx
      typescript
      vim
      vimdoc
      yaml
    ];

  plugins = with pkgs.vimPlugins; [
    (nvim-treesitter.withPlugins grammars)
    catppuccin-nvim
    fzf-lua
    gitsigns-nvim
  ];

  pack = pkgs.vimUtils.packDir { dlab.start = plugins; };
in
{
  config = lib.mkIf enabled {
    # /etc/xdg/nvim is second in nvim's runtimepath, immediately behind
    # ~/.config/nvim, and nvim reads sysinit.vim from there before any user
    # configuration.  So the lab's editor needs no wrapped package, no symlink
    # in the home disk and no plugin manager: the flake owns /etc, plugins are
    # store paths in a pack directory rather than a runtime clone, and a
    # checkout that carries its own ~/.config/nvim still wins.
    environment.etc."xdg/nvim/sysinit.vim".source = ../nvim/sysinit.vim;
    environment.etc."xdg/nvim/lua".source = ../nvim/lua;
    environment.etc."xdg/nvim/pack".source = "${pack}/pack";
  };
}
