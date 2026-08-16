{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    bat
    curl
    delta
    difftastic
    fd
    file
    fzf
    gcc
    gnumake
    git
    gh
    htop
    jq
    lsof
    lua-language-server
    luajit
    neovim
    nil
    nixfmt
    pkg-config
    ripgrep
    rsync
    stylua
    tmux
    tree
    unzip
    wget
  ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.git = {
    enable = true;

    config = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  environment.variables.EDITOR = "nvim";
}
