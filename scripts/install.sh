#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
install_dir="$HOME/.local/bin"

mkdir -p -- "$install_dir"
staged=$(mktemp "$install_dir/.patra.XXXXXX")
trap 'rm -f -- "$staged"' EXIT
install -m 0755 -T -- "$script_dir/patra" "$staged"
"$staged"
mv -fT -- "$staged" "$install_dir/patra"
printf 'Installed Patra to %s\n' "$install_dir/patra"

case ":${PATH-}:" in
    *":$install_dir:"*|*":$install_dir/:"*) ;;
    *)
        printf '\nAdd ~/.local/bin to PATH in your shell configuration, then open a new terminal.\n'
        user_shell=${SHELL:-sh}
        case "${user_shell##*/}" in
            fish) printf '%s\n' 'fish_add_path "$HOME/.local/bin"' ;;
            *) printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' ;;
        esac
        ;;
esac
