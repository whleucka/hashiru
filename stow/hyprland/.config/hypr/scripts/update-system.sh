#!/usr/bin/env bash

# This is really, really dumb lol
echo "╔══════════════════════════════════════════╗"
echo "║                                          ║"
echo "║          ⚡  SYSTEM UPDATE  ⚡           ║"
echo "║                                          ║"
echo "║         Updating system. Stand by.       ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo
yay -Syu --noconfirm
paplay "/opt/hashiru/tools/assets/wow.mp3" &
confetti
