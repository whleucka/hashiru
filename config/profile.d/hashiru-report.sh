# shellcheck shell=sh
# hashiru-report.sh — show the Hashiru install warnings digest once, on the
# first interactive login after a bootstrap that finished with warnings, then
# archive it. Installed to /etc/profile.d by install.sh. POSIX sh: sourced by
# bash login shells directly and by zsh via /etc/zsh/zprofile's `emulate sh`.
case "$-" in
    *i*)
        _hashiru_report="${HOME}/.local/share/hashiru/report.txt"
        if [ -s "${_hashiru_report}" ]; then
            printf '\n\033[0;33m==> Hashiru install finished with warnings:\033[0m\n'
            cat "${_hashiru_report}"
            printf 'Full log: %s\n\n' "${HOME}/.local/share/hashiru/install.log"
            mv -f "${_hashiru_report}" "${_hashiru_report%.txt}.last.txt"
        fi
        unset _hashiru_report
        ;;
esac
