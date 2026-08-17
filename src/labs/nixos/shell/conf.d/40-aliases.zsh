# /etc/zshrc already defines l, ll and ls.  Redefining two of them here is
# deliberate; a lab should answer to the same keys as the workstation.

alias cp="cp -i"
alias mv="mv -i"
alias rm="rm -i"

alias grep="grep --color=auto"
alias f='find . -type f -name'

alias n="nvim"
alias nn="nvim ."
alias v="nvim"
alias vv="nvim ."

alias la="ls -a"
alias ll="ls -l"

(( $+commands[bat] )) && alias cat='bat -pp'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias cd..="cd .."
alias cd...="cd ../.."

alias cdh="cd $HOME"
alias cdc="cd $CONFIG"
alias cdz="cd $CONFIG/zsh/conf.d"
alias cdj='cd "$OLDPWD"'

alias cdf="cd ../frontend"
alias cdb="cd ../backend"

# One lab, one checkout: DLAB_PROJECT is where it landed, set by the flake from
# the registry.  Without a configured repository it is the home directory.
alias cdp='cd "${DLAB_PROJECT:-$HOME}"'
alias gs='git status'
alias ga='git add .'
alias gc='git commit -m'
alias gcm='git commit -m'
alias gp='git push'
alias gl='git log'
alias gd='git diff'

alias gca='git add -A && git commit --amend --no-edit && git push --force-with-lease'

alias penv="python -m venv .venv && source .venv/bin/activate"

# Hold the idle stopper for the lifetime of a long unattended command.
(( $+commands[dlab-run] )) && alias dr='dlab-run'
