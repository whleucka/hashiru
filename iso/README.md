# Hashiru Live ISO (stage-0)

This directory builds a bootable Arch ISO whose only job is to capture a few
machine-specific answers, lay down an encrypted base Arch system via
`archinstall`, and hand off to Hashiru's `install.sh` on first boot.

It is **stage-0**. The `scripts/10..99` stages in the repo root are unchanged —
they still do all the real work, just triggered automatically instead of via
the manual one-liner.

## Layers

```
ISO (this dir)            → archiso releng + Hashiru overlay
  └ stage0.sh             → steps: keyboard / network / account / machine / disk,
                             then a review before anything is erased
      └ archinstall       → partition, LUKS, btrfs, pacstrap, bootloader, user
          └ custom_commands → clone repo, enable first-boot unit, keyboard for Hyprland
              └ first boot → hashiru-firstboot.service runs ./install.sh as user
```

The only questions are the ones that vary per machine: keyboard, WiFi (only if
wired fails), username, password (and an optional separate disk passphrase),
hostname, timezone (pre-filled from a geo-IP lookup), language and target disk.
A review card shows every answer, any of them can be edited, and the disk is
only erased after you type its name. Everything else is fixed in
`archinstall/user_config.json`: customization in code, not prompts.

The keyboard reaches Hyprland too: `install-firstboot.sh` turns the X11 layout
systemd derives from the keymap into `~/.config/hashiru/hypr/local.lua`.

`/root/stage0.sh --dry-run` walks every step and prints the config it would
hand archinstall (secrets redacted), then stops. Nothing is written to disk.

## When stage0 fails

Every stop draws `ui_failure` (a red `!!` block plus a log tail) and a menu:

| Failure | Menu |
|---|---|
| No network after the wired wait | Retry · Set up WiFi (scan, pick, `ui_password`) · Shell · Power off |
| archinstall exits non-zero | Retry (same answers) · Edit answers · Shell · Power off. Retry first runs `umount -R /mnt` and closes the target's crypt mappings, then checks with `lsblk` |
| archinstall dies in a `custom_commands` entry (`user-command.N.sh … exit code` in its log) | Retry wiring · Retry install · Edit answers · Shell · Power off. Retry wiring re-runs the entries from N onward via `arch-chroot /mnt`, then writes the fstab: archinstall runs `genfstab` *after* `custom_commands`, so a failure there leaves the target with none. Only offered while `/mnt` holds the installed system |
| Anything else (`set -E` + `ERR` trap, top-level shell only) | Shell · Power off, naming the function, line and command |

stage0 keeps its own plain log at `/var/log/hashiru-stage0.log`
(`HASHIRU_STAGE0_LOG` overrides it): each step's answers, menu picks,
archinstall's exit code. Passwords never pass through the wrappers that write
it. The creds file is removed on every path except Shell after an archinstall
failure, which needs it to re-run by hand. `seed_wifi` writes the NM keyfile
only when `/mnt` is mounted with a readable `/etc`; otherwise the reboot screen
warns that the installed system boots without WiFi.

## Build

```bash
sudo pacman -S archiso          # one-time; pacman/dev.txt installs it
sudo ./iso/build.sh             # → iso/out/hashiru-*.iso
```

`build.sh` copies the official `releng` profile, overlays `overlay/airootfs/`,
appends `overlay/packages.x86_64.extra`, brands `profiledef.sh`, and runs
`mkarchiso`. The releng profile is intentionally **not** vendored — we track
upstream archiso for free.

## Test in QEMU (no hardware needed)

`pacman/dev.txt` installs everything this needs (stage 99). By hand:

```bash
sudo pacman -S --needed archiso qemu-base qemu-ui-gtk edk2-ovmf
```

`test-qemu.sh` checks for these before starting and says what's missing.

```bash
./iso/test-qemu.sh             # install mode — boots latest out/*.iso (the installer)
./iso/test-qemu.sh run         # run mode    — boots the INSTALLED disk, no ISO attached
```

The installer reboots when it finishes. Because the ISO is still "in the drive"
in install mode, that reboot would loop back into the installer — so after the
base install completes, switch to `run` mode to boot the system you just
installed (the equivalent of pulling the USB stick out). That first disk boot is
where `hashiru-firstboot.service` runs stages 10–99.

Iterate: edit → `build.sh` → `test-qemu.sh`. `build.sh` refuses a commit that
isn't pushed, since the installed system clones it from GitHub
(`HASHIRU_ALLOW_UNPUSHED=1` builds anyway, for testing only the live side). Delete `iso/work/test-disk.qcow2`
(and `iso/work/OVMF_VARS.fd`) to start from a completely clean machine.

## Files

| File | Role |
|------|------|
| `build.sh` | Assemble + build the ISO |
| `test-qemu.sh` | Boot the ISO in QEMU (UEFI) |
| `verify.sh` | Check a built ISO without booting it: size, commit pin, stage0 mode, `lib/ui.sh` copy |
| `overlay/airootfs/root/stage0.sh` | Interactive front-end (runs on tty1) |
| `overlay/airootfs/root/.zprofile`, `.bash_profile` | Auto-launch stage0 on tty1 |
| `overlay/packages.x86_64.extra` | Extra live-ISO packages (`jq`, `gum`) |
| `../lib/ui.sh` → `/root/lib/ui.sh` | Shared installer UI (banner, palette, prompts), copied in by `build.sh`; `verify.sh` checks it matches the pinned commit |
| `archinstall/user_config.json` | Fixed install layout (templated) |
| `archinstall/user_creds.example.json` | Reference creds shape (real one generated at runtime) |
| `firstboot/install-firstboot.sh` | Runs in chroot; installs the first-boot unit, hands `/opt/hashiru` to the user |
| `firstboot/hashiru-firstboot.service` | One-shot unit, first boot |
| `firstboot/hashiru-firstboot.sh` | Runs `install.sh` as the user, then disables itself; on failure, resumes next boot (point 9) |
| `../config/profile.d/hashiru-firstboot-failed.sh` | Login notice while first boot stands failed; installed by `install-firstboot.sh` |

## Known fragile points (validate in QEMU before trusting)

1. **archinstall schema drift is the #1 risk.** The `disk_config` block in
   `user_config.json` and the credential keys in `stage0.sh`
   (`encryption_password`, `users[].!password`) were captured from and verified
   against **archinstall v4.3**. They change between releases. The reliable way
   to refresh them: boot the ISO, run `archinstall --dry-run`, configure the
   layout/user/encryption you want, use "Save configuration" (decline credential
   encryption so the creds file is readable), and copy the exported
   `user_configuration.json` / `user_credentials.json` back into this dir —
   re-inserting the `__TIMEZONE__` / `__HOSTNAME__` / `__KB_LAYOUT__` /
   `__SYS_LANG__` / `__HASHIRU_USER__` / `__TARGET_DISK__` placeholders and the
   `custom_commands`. Pin your ISO to a known archiso snapshot to avoid
   surprise breakage.

2. **The btrfs partition size is recomputed at runtime.** The saved layout
   freezes an absolute partition size (whatever disk it was captured on), so
   `stage0.sh` rewrites the btrfs partition's `size.value` via `jq` to fill the
   actual target disk. If you regenerate `disk_config`, keep the two-partition
   shape (fat32 `/boot` + btrfs) or update that `jq` selector accordingly.

3. **btrfs is required for snapper.** `scripts/50-snapper.sh` only runs on
   btrfs, and the config requests GRUB so `grub-btrfs` works. Keep the
   filesystem btrfs + bootloader GRUB if you want snapshots.

4. **First-boot needs network.** `custom_commands` git-clones during install
   (live env has network) and `archinstall` enables NetworkManager, so the
   first boot has connectivity for the bootstrap. If you go fully offline,
   bake the repo into the image instead of cloning.

5. **`/opt/hashiru` is permanent, and must stay a pullable checkout.** The
   installed system stows its desktop config out of that directory and
   `hashiru update` fast-forwards it, so `custom_commands` pins the clone with
   `reset --hard` rather than `checkout --detach` — a detached HEAD has no
   upstream to pull from. `install-firstboot.sh` then chowns the tree to the
   user (`install.sh` refuses to run as root) and symlinks `~/hashiru` and
   `/usr/local/bin/hashiru`. Deleting `/opt/hashiru` breaks the desktop.

6. **Unattended mode is wired up via `HASHIRU_UNATTENDED`.** The first-boot
   unit runs `install.sh` with `HASHIRU_UNATTENDED=1` (defaulted to `0` in
   `lib/common.sh`). That makes stage 99 auto-reboot instead of prompting, and
   stage 30 sets the default shell via `sudo chsh` so it never blocks on a PAM
   password prompt. If you add new interactive prompts to any stage, branch on
   `${HASHIRU_UNATTENDED}` the same way.

7. **Temporary passwordless sudo.** `hashiru-firstboot.sh` drops a
   `/etc/sudoers.d/hashiru-firstboot` NOPASSWD rule for the bootstrap and
   removes it on exit. If the run is killed uncleanly, confirm that file is
   gone.

8. **The bootstrap owns tty1.** `install-firstboot.sh` ships a
   `getty@tty1.service.d/10-hashiru-firstboot.conf` drop-in gated on
   `ConditionPathExists=!/etc/hashiru-firstboot.env`, so no login prompt
   appears while the bootstrap is pending — otherwise the getty paints a prompt
   at `multi-user.target` and the bootstrap's console logging scribbles over it
   a moment later. It also stops someone logging in mid-install, which matters
   once stage 30 has written the autologin drop-in. The getty returns on its
   own when the bootstrap clears the env file. On the failure path the drop-in
   stays (it keeps tty1 quiet for the next boot's retry), and the `EXIT` trap
   writes a runtime override instead,
   `/run/systemd/system/getty@tty1.service.d/zz-hashiru-failed.conf`: it
   cancels the gate's condition, resets `ExecStart` to a plain `agetty` (no
   `--autologin`), and sets `TTYVTDisallocate=no` so the failure screen isn't
   wiped. `zz-` sorts after both the gate and stage 30's `autologin.conf`;
   `/run` is tmpfs, so the next boot is untouched. If you ever need tty1 back
   by hand: `rm` the gate drop-in, `systemctl daemon-reload`, then start
   `getty@tty1`.

9. **A failed first boot resumes, three times at most.** On a stage failure
   `install.sh` writes the stage number to `~/.local/share/hashiru/failed-stage`
   (removed once that stage succeeds). `hashiru-firstboot.sh` then rewrites
   `/etc/hashiru-firstboot.env`:

   ```
   HASHIRU_USER=alice
   HASHIRU_FIRSTBOOT_ATTEMPTS=1     # seeded as 0 by install-firstboot.sh
   HASHIRU_RESUME_FROM=50           # the next boot runs ./install.sh 50+
   ```

   and writes the marker `/var/lib/hashiru/firstboot-failed` (stage, attempt,
   resume command, time). While it exists, `/etc/profile.d/hashiru-firstboot-failed.sh`
   prints it at every login and `.zprofile` doesn't start Hyprland on tty1.
   The third failure disables the unit and removes the gate drop-in. Success
   removes the env file, the marker and both drop-ins; so does a manual
   `install.sh` run that completes the final stage (the marker, via `sudo`).
   To start the count over by hand, set `HASHIRU_FIRSTBOOT_ATTEMPTS=0` and
   `systemctl enable hashiru-firstboot.service`.
