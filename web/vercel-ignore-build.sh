#!/usr/bin/env bash
# Vercel "Ignored Build Step" for TetherShot.
# Build ONLY when files under /web changed; skip otherwise.
#   exit 0  -> Vercel CANCELS (skips) the build
#   exit 1  -> Vercel PROCEEDS with the build
#
# Set it in Vercel: Settings -> Git -> Ignored Build Step:
#   bash vercel-ignore-build.sh
# (':(top)web/' is repo-root-relative, so this works whether the project's
#  Root Directory is the repo root or /web.)

if ! git rev-parse "HEAD^" >/dev/null 2>&1; then
  echo "No previous commit — building."
  exit 1
fi

if git diff --quiet "HEAD^" "HEAD" -- ':(top)web/'; then
  echo "No changes under /web — skipping build."
  exit 0
else
  echo "Changes under /web — building."
  exit 1
fi
