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
    starship
    tmux
    tree
    unzip
    wget
    zsh
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

  # A lab is only ever reached from a terminal on the host, and SSH forwards its
  # TERM.  Without the matching terminfo every shell start prints "can't find
  # terminal definition for xterm-ghostty" and falls back to a dumb terminal.
  # The whole set is terminfo outputs only, so it costs kilobytes and covers
  # wezterm and kitty too.
  environment.enableAllTerminfo = true;
}
