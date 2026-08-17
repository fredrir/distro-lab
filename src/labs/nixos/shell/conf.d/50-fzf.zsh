command -v fzf >/dev/null || return 0

export FZF_DEFAULT_OPTS="--height=40% --layout=reverse --border"

if command -v bat >/dev/null; then
  export FZF_CTRL_T_OPTS="--preview 'bat --color=always --style=numbers --line-range=:200 {} 2>/dev/null || ls --color=always {}'"
fi

bindkey -M emacs -r '^T'
bindkey -M vicmd -r '^T'
bindkey -M viins -r '^T'

bindkey -M emacs '^F' fzf-file-widget
bindkey -M vicmd '^F' fzf-file-widget
bindkey -M viins '^F' fzf-file-widget
