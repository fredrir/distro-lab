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
    neovim
    nil
    nixfmt
    pkg-config
    ripgrep
    rsync
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
