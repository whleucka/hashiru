# ~/.bash_profile — executed for login shells (stow-managed: stow/bash/.bash_profile)
#
# Bash reads this for login shells and ~/.bashrc for interactive non-login ones,
# and never both. Arch's /etc/skel/.bash_profile bridges that by sourcing
# ~/.bashrc; 45-config.sh deletes the pristine skel copy so this package can
# claim the path, so the bridge has to live here or `ssh host` and `bash -l`
# would get none of the Hashiru bash config.

[[ -f ~/.bashrc ]] && . ~/.bashrc
