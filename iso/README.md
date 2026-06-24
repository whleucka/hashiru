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
  └ stage0.sh             → prompts: user / password / timezone / disk (+LUKS)
      └ archinstall       → partition, LUKS, btrfs, pacstrap, bootloader, user
          └ custom_commands → clone repo + enable first-boot unit
              └ first boot → hashiru-firstboot.service runs ./install.sh as user
```

Only username, password, timezone and target disk are interactive. Everything
else is fixed in `archinstall/user_config.json` — customization in code, not
prompts.

## Build

```bash
sudo pacman -S archiso          # one-time
sudo ./iso/build.sh             # → iso/out/hashiru-*.iso
```

`build.sh` copies the official `releng` profile, overlays `overlay/airootfs/`,
appends `overlay/packages.x86_64.extra`, brands `profiledef.sh`, and runs
`mkarchiso`. The releng profile is intentionally **not** vendored — we track
upstream archiso for free.

## Test in QEMU (no hardware needed)

```bash
./iso/test-qemu.sh              # boots latest out/*.iso against a throwaway disk
```

Iterate: edit → `build.sh` → `test-qemu.sh`. Delete `iso/work/test-disk.qcow2`
to start from a clean disk.

## Files

| File | Role |
|------|------|
| `build.sh` | Assemble + build the ISO |
| `test-qemu.sh` | Boot the ISO in QEMU (UEFI) |
| `overlay/airootfs/root/stage0.sh` | Interactive front-end (runs on tty1) |
| `overlay/airootfs/root/.zprofile`, `.bash_profile` | Auto-launch stage0 on tty1 |
| `overlay/packages.x86_64.extra` | Extra live-ISO packages (`jq`) |
| `archinstall/user_config.json` | Fixed install layout (templated) |
| `archinstall/user_creds.example.json` | Reference creds shape (real one generated at runtime) |
| `firstboot/install-firstboot.sh` | Runs in chroot; installs the first-boot unit |
| `firstboot/hashiru-firstboot.service` | One-shot unit, first boot |
| `firstboot/hashiru-firstboot.sh` | Runs `install.sh` as the user, then disables itself |

## Known fragile points (validate in QEMU before trusting)

1. **archinstall schema drift is the #1 risk.** The `disk_config` block in
   `user_config.json` and the credential key names in `stage0.sh`
   (`!users`, `!encryption_password`, `!root-password`) track archinstall's
   JSON schema, which changes between releases. The reliable way to refresh
   them: boot the ISO, run `archinstall` interactively once, configure the
   layout you want, use its "Save configuration" option, and copy the exported
   `user_configuration.json` / `user_credentials.json` back into this dir
   (re-inserting the `__TIMEZONE__` / `__HASHIRU_USER__` / `__TARGET_DISK__`
   placeholders). Pin your ISO to a known archiso snapshot to avoid surprise
   breakage.

2. **`disk_config` here is illustrative.** `"config_type": "default_layout"`
   with a single `device` is a readable placeholder, not guaranteed-valid for
   your archinstall version — real configs use explicit `device_modifications`.
   Regenerate per point 1.

3. **btrfs is required for snapper.** `scripts/50-snapper.sh` only runs on
   btrfs, and the config requests GRUB so `grub-btrfs` works. Keep the
   filesystem btrfs + bootloader GRUB if you want snapshots.

4. **First-boot needs network.** `custom_commands` git-clones during install
   (live env has network) and `archinstall` enables NetworkManager, so the
   first boot has connectivity for the bootstrap. If you go fully offline,
   bake the repo into the image instead of cloning.

5. **Unattended mode is wired up via `HASHIRU_UNATTENDED`.** The first-boot
   unit runs `install.sh` with `HASHIRU_UNATTENDED=1` (defaulted to `0` in
   `lib/common.sh`). That makes stage 99 auto-reboot instead of prompting, and
   stage 30 sets the default shell via `sudo chsh` so it never blocks on a PAM
   password prompt. If you add new interactive prompts to any stage, branch on
   `${HASHIRU_UNATTENDED}` the same way.

6. **Temporary passwordless sudo.** `hashiru-firstboot.sh` drops a
   `/etc/sudoers.d/hashiru-firstboot` NOPASSWD rule for the bootstrap and
   removes it on exit. If the run is killed uncleanly, confirm that file is
   gone.
