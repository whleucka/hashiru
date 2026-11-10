# New named session, tmux `new -A -s NAME` style. Bound in kitty.conf as
#
#   map kitty_mod+n kitten new_session.py <sessions dir>
#
# Prompts for a name, writes <dir>/<name>.kitty-session holding one shell in
# the current pane's working directory, and switches to it. A name that
# already exists is left as is and just switched to. Save the layout you build
# afterwards with save_as_session (kitty_mod+s).
#
# No UI of its own: kitty runs handle_result inside the kitty process, which
# is what gives it the boss, the built-in line prompt and goto_session.

import os

from kittens.tui.handler import result_handler


def main(args: list[str]) -> None:
    pass


@result_handler(no_ui=True)
def handle_result(args: list[str], answer: None, target_window_id: int, boss) -> None:
    from kitty.session import goto_session

    if len(args) < 2:
        boss.show_error('new_session', 'Usage: kitten new_session.py <sessions dir>')
        return
    sessions_dir = os.path.abspath(os.path.expanduser(args[1]))
    window = boss.window_id_map.get(target_window_id)
    cwd = (window.cwd_of_child if window else None) or os.path.expanduser('~')

    def create(name: str) -> None:
        name = name.strip()
        if not name:
            return
        # The name becomes a file name; nothing that could leave the directory.
        if '/' in name or name.startswith('.'):
            boss.show_error('Invalid session name', f'{name!r}: no slashes, and no leading dot.')
            return
        path = os.path.join(sessions_dir, f'{name}.kitty-session')
        if not os.path.exists(path):
            os.makedirs(sessions_dir, exist_ok=True)
            with open(path, 'w') as f:
                f.write(f'cd {cwd}\nlaunch\n')
        goto_session(boss, [path])

    boss.get_line(
        f'New session in {cwd}', create, window=window,
        prompt='Name: ', window_title='New session',
    )
