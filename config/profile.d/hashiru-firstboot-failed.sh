# shellcheck shell=sh
# hashiru-firstboot-failed.sh — while first boot's bootstrap stands failed, say
# so on every interactive login: which stage, which attempt, and how to finish
# it. hashiru-firstboot.sh writes the marker on failure; it goes when first boot
# succeeds, or when install.sh finishes the bootstrap by hand. Installed to
# /etc/profile.d by install-firstboot.sh, before any stage runs. POSIX sh, like
# hashiru-report.sh: sourced by bash login shells directly and by zsh via
# /etc/zsh/zprofile's `emulate sh`.
case "$-" in
    *i*)
        _hashiru_marker="/var/lib/hashiru/firstboot-failed"
        if [ -r "${_hashiru_marker}" ]; then
            # Read, never sourced: it is a file of plain key=value lines.
            _hashiru_get() { sed -n "s/^$1=//p" "${_hashiru_marker}" | head -n 1; }
            _hashiru_stage="$(_hashiru_get stage)"
            _hashiru_attempt="$(_hashiru_get attempt)"
            _hashiru_max="$(_hashiru_get max)"
            _hashiru_resume="$(_hashiru_get resume)"
            printf '\n\033[0;31m==> Hashiru first boot failed in %s\033[0m (attempt %s of %s, %s)\n' \
                "${_hashiru_stage:-an unknown stage}" "${_hashiru_attempt:-?}" "${_hashiru_max:-?}" \
                "$(_hashiru_get time)"
            if [ "$(_hashiru_get gave_up)" = 1 ]; then
                printf '    It will not try again on its own.\n'
            else
                printf '    The next boot tries again from there.\n'
            fi
            printf '    See what went wrong:  hashiru log\n'
            printf '    Finish it now:        %s\n\n' "${_hashiru_resume:-hashiru install}"
            unset -f _hashiru_get
            unset _hashiru_stage _hashiru_attempt _hashiru_max _hashiru_resume
        fi
        unset _hashiru_marker
        ;;
esac
