#!/usr/bin/env sh
# web-install.sh — one command, no manual download: fetch a harness release from
# the PUBLIC distribution repo and install it into a target repo.
#
# This is the `curl ... | sh -` front door. It is deliberately THIN: it resolves a
# release (latest, a pinned version, or an interactive pick), downloads the
# version-matched bundle + its sha256 sidecar + the matching install.sh, then hands
# off to install.sh — which owns the real work (checksum verify, tar-escape guard,
# dependency preflight, copy + hook wiring, strict integrity check, and the
# post-install test run). This wrapper never re-implements any of that, and it
# trusts NOTHING from a local checkout — every byte comes from the release assets.
#
# Usage (piped — note the `-s --` so args reach the script over stdin):
#   curl -fsSL https://hieubui2409.github.io/sdlc-harness-release/install.sh \
#     | sh -s -- [target-dir] [flags]
#
# Usage (downloaded, so you can read it first — the safer path):
#   curl -fsSL .../install.sh -o install.sh && less install.sh
#   sh install.sh [target-dir] [flags]
#
# Flags:
#   -i, --interactive   list the available releases, pick one, PREVIEW its
#                       changelog, and confirm before installing (reads /dev/tty,
#                       so it works even when this script is piped into sh).
#   -n, --dry-run       resolve the version and print exactly what WOULD be
#                       downloaded (URLs + expected sha256) — install nothing.
#   --skip-tests        forwarded to install.sh (skip the post-install suite).
#   any other -flag     forwarded verbatim to install.sh.
#
# target-dir defaults to the current directory (the repo you want to harden).
#
# Env overrides:
#   HARNESS_VERSION       pin a version (e.g. 5.3.0 or harness-v5.3.0); default: latest
#   HARNESS_RELEASE_BASE  override the asset base URL (default: the public repo's
#                         per-tag download dir). A test points this at a file:// dir
#                         to exercise the whole path offline.
set -eu

REPO="hieubui2409/sdlc-harness-release"
API="https://api.github.com/repos/${REPO}/releases"
DL="https://github.com/${REPO}/releases"

# curl is the one hard external dependency here (it also handles file:// for the
# offline test path). Python is checked later by install.sh, where the failure
# message can point at the exact fix.
command -v curl >/dev/null 2>&1 || {
  echo "error: curl is required to download the release bundle" >&2
  exit 1
}

# Split args: -i/--interactive and -n/--dry-run are consumed here; the first
# non-flag positional is the target dir; every other flag is forwarded verbatim to
# install.sh. POSIX sh has no arrays, so rotate each arg once — pop from the front,
# and either capture/consume it or re-append it. After the rotation "$@" holds
# exactly the forwarded flags, so the hand-off needs no unquoted word-splitting.
TARGET=""
INTERACTIVE=0
DRYRUN=0
_n=$#
_i=0
while [ "$_i" -lt "$_n" ]; do
  _arg="$1"; shift
  case "$_arg" in
    -i|--interactive) INTERACTIVE=1 ;;
    -n|--dry-run)     DRYRUN=1 ;;
    -*)               set -- "$@" "$_arg" ;;
    *)                if [ -z "$TARGET" ]; then TARGET="$_arg"; else set -- "$@" "$_arg"; fi ;;
  esac
  _i=$((_i + 1))
done
TARGET="${TARGET:-$(pwd)}"

# Resolve tag from JSON robustly with python3 when present, else a grep/sed
# fallback (the non-interactive latest path must work without python3 — install.sh
# checks python3 later with an actionable message).
_json_first_tag() {  # stdin: a /releases/latest JSON object
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))'
  else
    grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//; s/".*//'
  fi
}

# 1. resolve the release tag.
VER="${HARNESS_VERSION:-}"
if [ -n "$VER" ]; then
  TAG="harness-v${VER#harness-v}"
elif [ "$INTERACTIVE" -eq 1 ]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "error: -i/--interactive needs python3 to render the release list" >&2
    exit 1
  }
  [ -e /dev/tty ] || {
    echo "error: -i/--interactive needs a terminal (/dev/tty) to prompt on" >&2
    exit 1
  }
  echo "fetching the release list ..." >&2
  _list="$(curl -fsSL "${API}?per_page=30")"
  # Render a numbered menu (newest first) to the terminal.
  printf '%s' "$_list" | python3 -c '
import json, sys
rels = json.load(sys.stdin)
if not rels:
    sys.exit("no releases found")
for i, r in enumerate(rels, 1):
    date = (r.get("published_at") or "")[:10]
    print("%2d) %-16s %s  %s" % (i, r.get("tag_name",""), date, r.get("name","")))
' > /dev/tty
  printf 'pick a release [1]: ' > /dev/tty
  read -r _choice < /dev/tty
  _choice="${_choice:-1}"
  # Resolve the chosen tag + preview its changelog, both from the fetched list.
  TAG="$(printf '%s' "$_list" | python3 -c '
import json, sys
rels = json.load(sys.stdin)
n = sys.argv[1]
if not n.isdigit() or not (1 <= int(n) <= len(rels)):
    sys.exit("invalid selection: %s" % n)
print(rels[int(n)-1]["tag_name"])
' "$_choice")"
  echo >/dev/tty
  echo "──────── changelog: ${TAG} ────────" >/dev/tty
  printf '%s' "$_list" | python3 -c '
import json, sys
rels = json.load(sys.stdin)
body = (rels[int(sys.argv[1])-1].get("body") or "").strip()
print(body if body else "(no release notes published for this version)")
' "$_choice" > /dev/tty
  echo "───────────────────────────────────" >/dev/tty
  printf 'install %s into %s? [y/N]: ' "$TAG" "$TARGET" > /dev/tty
  read -r _yes < /dev/tty
  case "$_yes" in
    y|Y|yes|YES) : ;;
    *) echo "aborted." >&2; exit 1 ;;
  esac
else
  echo "resolving the latest harness release ..." >&2
  TAG="$(curl -fsSL "${API}/latest" | _json_first_tag)"
  [ -n "$TAG" ] || {
    echo "error: could not resolve the latest release tag from ${API}/latest" >&2
    exit 1
  }
fi

BASE="${HARNESS_RELEASE_BASE:-${DL}/download/${TAG}}"
BUNDLE="${TAG}.tar.gz"

# 2. dry-run: print the plan (what would be fetched + the expected checksum) and
#    stop. Nothing is written to the target — the "show me first" surface.
if [ "$DRYRUN" -eq 1 ]; then
  echo "DRY-RUN — would install ${TAG} into ${TARGET}, fetching:"
  echo "  bundle:    ${BASE}/${BUNDLE}"
  echo "  checksum:  ${BASE}/${BUNDLE}.sha256"
  echo "  installer: ${BASE}/install.sh"
  _sha="$(curl -fsSL "${BASE}/${BUNDLE}.sha256" 2>/dev/null || true)"
  [ -n "$_sha" ] && echo "  expected sha256: ${_sha}"
  echo "re-run without --dry-run to install."
  exit 0
fi

# 3. download the version-matched bundle + sidecar + installer to a temp dir.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "downloading ${BUNDLE} from ${BASE} ..."
curl -fsSL "${BASE}/${BUNDLE}" -o "${WORK}/${BUNDLE}"
# The sha256 sidecar is what makes install.sh's checksum step meaningful — but it
# is optional there, so a missing sidecar only downgrades to "no verify", it does
# not abort. install.sh runs a cross-platform tar-escape guard regardless.
curl -fsSL "${BASE}/${BUNDLE}.sha256" -o "${WORK}/${BUNDLE}.sha256" 2>/dev/null \
  || echo "  (no sha256 sidecar published — install.sh will skip checksum verify)" >&2
curl -fsSL "${BASE}/install.sh" -o "${WORK}/install.sh"

# 4. hand off to the version-matched installer. It owns verify + install + strict
#    + tests; the forwarded flags left in "$@" (e.g. --skip-tests) pass through.
echo "installing harness ${TAG} into ${TARGET} ..."
sh "${WORK}/install.sh" "${WORK}/${BUNDLE}" "$TARGET" "$@"
