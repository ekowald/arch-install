# Fish shell configuration

set -g -x LANG en_US.UTF-8
set -g -x EDITOR nvim
set -g -x VISUAL nvim

# Aliases
alias ll='ls -la'
alias gst='git status'
alias gp='git pull'
alias gd='git diff'

# Enable Tide prompt
if status is-login
    tide configure
end
