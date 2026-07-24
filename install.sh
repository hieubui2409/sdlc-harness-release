#!/usr/bin/env sh
# install.sh — one command to install a harness bundle into a target repo.
#
# Dispatches on WHAT you give it:
#   install.sh                              → online: fetch the LATEST release, install
#   install.sh <target>                     → online latest, into <target>
#   install.sh <url-to-.tar.gz> [target]    → online: download that URL, install
#   install.sh <harness-vX.Y.Z.tar.gz> [t]  → offline: install a local bundle
#
# Flags:
#   -i, --interactive   online: list releases, pick one, PREVIEW its changelog,
#                       confirm — then install (reads /dev/tty, so it works when
#                       this script is piped into sh).
#   -n, --dry-run       online: print exactly what WOULD be downloaded (URLs +
#                       expected sha256) and stop — install nothing.
#   --version=X         online: pin a version (e.g. --version=5.4.0). Same as the
#                       HARNESS_VERSION env var.
#   --run-tests         run the post-install test suite (OFF by default; ~30s).
#   --skip-tests        deprecated no-op — the suite is already off by default
#                       (alias --no-tests, kept so old invocations don't error).
#
# Whichever way the bundle arrives, the rest is one shot, no follow-ups:
#   1. verify the sha256 sidecar (if present)
#   2. extract the bundle to a temp dir (with a tar-escape guard)
#   3. check dependencies first — fail fast with the exact pip command if missing
#   4. install into the target and verify it (--strict: a drifted install fails)
#   5. (opt-in, --run-tests) run the harness test suite against the fresh copy
#
# Step 5 is OFF by default; --run-tests opts in (~30s). The strict integrity
# check in step 4 already confirms the install, so the suite is only the extra
# "does it run green in my environment" pass.
#
# Env overrides (online path): HARNESS_VERSION pins a version; HARNESS_RELEASE_BASE
# overrides the asset base URL (a test points it at a file:// dir).
set -eu

REPO="hieubui2409/sdlc-harness-release"
API="https://api.github.com/repos/${REPO}/releases"
DL="https://github.com/${REPO}/releases"

RUN_TESTS=0
INTERACTIVE=0
DRYRUN=0
BUNDLE=""          # a local *.tar.gz path → offline mode
SOURCE_URL=""      # a URL to a *.tar.gz → download-that-URL mode
TARGET=""
VER="${HARNESS_VERSION:-}"

for arg in "$@"; do
  case "$arg" in
    --run-tests)             RUN_TESTS=1 ;;
    --skip-tests|--no-tests) : ;;  # back-compat no-op: the suite is off by default
    -i|--interactive)        INTERACTIVE=1 ;;
    -n|--dry-run)            DRYRUN=1 ;;
    --version=*)             VER="${arg#--version=}" ;;
    http://*|https://*|file://*) SOURCE_URL="$arg" ;;
    *.tar.gz)                BUNDLE="$arg" ;;
    -*) echo "error: unknown flag: $arg" >&2; exit 2 ;;
    *)  if [ -z "$TARGET" ]; then TARGET="$arg"
        else echo "error: unexpected argument: $arg" >&2; exit 2; fi ;;
  esac
done
TARGET="${TARGET:-$(pwd)}"

# 0. Python is a HARD requirement, and not just for this installer: the harness
#    runtime IS Python — every hook runs as a Python script on each tool call.
#    No Python means dead gates, so fail clearly now instead of with an opaque
#    "command not found" mid-install. A bundled venv would not help: a venv
#    references a base interpreter (it does not contain Python) and is not
#    portable across machines. The command name differs by platform — POSIX has
#    `python3`, a stock Windows install has only `python` / `py` — so probe in
#    order and pin the first Python >=3.9 found. HARNESS_PY is then exported so
#    install.py wires that SAME interpreter into the hook commands.
PY=""
for cand in python3 python "py -3"; do
  name=${cand%% *}
  command -v "$name" >/dev/null 2>&1 || continue
  if $cand -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    PY="$cand"; break
  fi
done
if [ -z "$PY" ]; then
  echo "error: no Python >=3.9 found (looked for: python3, python, py -3). The" >&2
  echo "       harness runs on Python — its hooks execute as Python scripts, so" >&2
  echo "       the target machine needs it too. Install Python 3, then re-run:" >&2
  echo "         Debian/Ubuntu: sudo apt install python3" >&2
  echo "         macOS:         brew install python" >&2
  echo "         Windows:       https://www.python.org/downloads/" >&2
  exit 1
fi
export HARNESS_PY="$PY"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Online path: no local bundle → resolve a URL and download it ──────────────
# "give a URL → handle the URL; give a tarball → handle the tarball; give neither
# → fetch the latest release." Interactive/dry-run only apply here.
if [ -z "$BUNDLE" ]; then
  command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required to download a release (or pass a local *.tar.gz)" >&2
    exit 1
  }

  if [ -n "$SOURCE_URL" ]; then
    case "$SOURCE_URL" in
      *.tar.gz) : ;;
      *) echo "error: the URL must point at a harness-vX.Y.Z.tar.gz bundle" >&2; exit 2 ;;
    esac
    BUNDLE_URL="$SOURCE_URL"
    SHA_URL="${SOURCE_URL}.sha256"
    BUNDLE_NAME="$(basename "$SOURCE_URL")"
    TAG="${BUNDLE_NAME%.tar.gz}"
  else
    # Resolve a tag: pinned version, interactive pick, or the latest release.
    if [ -n "$VER" ]; then
      TAG="harness-v${VER#harness-v}"
    elif [ "$INTERACTIVE" -eq 1 ]; then
      [ -e /dev/tty ] || { echo "error: -i needs a terminal (/dev/tty) to prompt on" >&2; exit 1; }
      echo "fetching the release list ..." >&2
      _list="$(curl -fsSL "${API}?per_page=30")"
      printf '%s' "$_list" | $PY -c '
import json, sys
rels = json.load(sys.stdin)
if not rels:
    sys.exit("no releases found")
for i, r in enumerate(rels, 1):
    print("%2d) %-16s %s  %s" % (i, r.get("tag_name",""), (r.get("published_at") or "")[:10], r.get("name","")))
' > /dev/tty
      printf 'pick a release [1]: ' > /dev/tty
      read -r _choice < /dev/tty
      _choice="${_choice:-1}"
      TAG="$(printf '%s' "$_list" | $PY -c '
import json, sys
rels = json.load(sys.stdin); n = sys.argv[1]
if not n.isdigit() or not (1 <= int(n) <= len(rels)):
    sys.exit("invalid selection: %s" % n)
print(rels[int(n)-1]["tag_name"])
' "$_choice")"
      echo >/dev/tty
      echo "──────── changelog: ${TAG} ────────" >/dev/tty
      printf '%s' "$_list" | $PY -c '
import json, sys
b = (json.load(sys.stdin)[int(sys.argv[1])-1].get("body") or "").strip()
print(b if b else "(no release notes published for this version)")
' "$_choice" > /dev/tty
      echo "───────────────────────────────────" >/dev/tty
      printf 'install %s into %s? [y/N]: ' "$TAG" "$TARGET" > /dev/tty
      read -r _yes < /dev/tty
      case "$_yes" in y|Y|yes|YES) : ;; *) echo "aborted." >&2; exit 1 ;; esac
    else
      echo "resolving the latest harness release ..." >&2
      TAG="$(curl -fsSL "${API}/latest" | $PY -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))')"
      [ -n "$TAG" ] || { echo "error: could not resolve the latest release tag" >&2; exit 1; }
    fi
    _base="${HARNESS_RELEASE_BASE:-${DL}/download/${TAG}}"
    BUNDLE_NAME="${TAG}.tar.gz"
    BUNDLE_URL="${_base}/${BUNDLE_NAME}"
    SHA_URL="${BUNDLE_URL}.sha256"
  fi

  if [ "$DRYRUN" -eq 1 ]; then
    echo "DRY-RUN — would install ${TAG} into ${TARGET}, fetching:"
    echo "  bundle:   ${BUNDLE_URL}"
    echo "  checksum: ${SHA_URL}"
    _sha="$(curl -fsSL "${SHA_URL}" 2>/dev/null || true)"
    [ -n "$_sha" ] && echo "  expected sha256: ${_sha}"
    echo "re-run without --dry-run to install."
    exit 0
  fi

  echo "downloading ${BUNDLE_NAME} ..."
  curl -fsSL "${BUNDLE_URL}" -o "${WORK}/${BUNDLE_NAME}"
  # sidecar is optional to step 1 (missing → skip verify), so don't abort on it.
  curl -fsSL "${SHA_URL}" -o "${WORK}/${BUNDLE_NAME}.sha256" 2>/dev/null \
    || echo "  (no sha256 sidecar — checksum verify will be skipped)" >&2
  BUNDLE="${WORK}/${BUNDLE_NAME}"
elif [ "$DRYRUN" -eq 1 ]; then
  echo "DRY-RUN — would install the local bundle ${BUNDLE} into ${TARGET}."
  echo "re-run without --dry-run to install."
  exit 0
fi

# 1. verify the bundle before trusting its contents.
if [ -f "${BUNDLE}.sha256" ]; then
  echo "verifying ${BUNDLE}.sha256 ..."
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256" )
  elif command -v shasum >/dev/null 2>&1; then
    ( cd "$(dirname "$BUNDLE")" && shasum -a 256 -c "$(basename "$BUNDLE").sha256" )
  else
    echo "  (no sha256 tool found — skipping checksum verification)" >&2
  fi
fi

# 2. extract to the temp tree (the installer reads from here).
# 2a. validate members cannot escape the extract dir before trusting the tar.
#     GNU/bsdtar already refuse '..' members and strip a leading '/', but the
#     checksum step above is skipped when no sidecar/hash tool is present, so a
#     MITM'd bundle is the threat. This cross-platform Python guard rejects any
#     absolute path, '..' traversal, or out-of-tree symlink/hardlink member.
"$PY" - "$BUNDLE" <<'PYEOF'
import os, sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as tf:
    for m in tf.getmembers():
        name = m.name
        if os.path.isabs(name) or name.startswith("/"):
            sys.exit("refusing tarball: absolute member path %r" % name)
        norm = os.path.normpath(name)
        if norm == ".." or norm.startswith(".." + os.sep):
            sys.exit("refusing tarball: path-traversal member %r" % name)
        if m.issym() or m.islnk():
            tgt = m.linkname
            joined = os.path.normpath(os.path.join(os.path.dirname(name), tgt))
            if os.path.isabs(tgt) or joined.startswith(".."):
                sys.exit("refusing tarball: unsafe link %r -> %r" % (name, tgt))
PYEOF
tar -xzf "$BUNDLE" -C "$WORK"

# 3. dependencies first — the installer and the harness both need them, so check
#    before installing. preflight_deps.py prints the exact pip command and exits
#    non-zero when something is missing, and set -e stops the script here.
echo "checking dependencies ..."
$PY "$WORK/harness/scripts/preflight_deps.py"

# 3b. snapshot the EXISTING install's manifest BEFORE the copy overwrites it, so
#     cleanup (step 4b) can tell version-dropped files from user-added ones. Read
#     from $TARGET (the install in place), not $WORK (the new bundle). Absent on a
#     first install -> OLD_MANIFEST stays empty -> cleanup is a no-op.
#     PERSIST the durable copy HERE, before install.py — a strict failure in a
#     later step must not skip it, or the first upgrade after a fresh install has
#     nothing to diff and the hs:cleanup recovery door is dead. harness/state/ is
#     gitignored and never in the bundle, so the copy below cannot clobber it.
OLD_MANIFEST=""
if [ -f "$TARGET/harness/manifest.json" ]; then
  OLD_MANIFEST="$WORK/old-manifest.json"
  cp "$TARGET/harness/manifest.json" "$OLD_MANIFEST"
  mkdir -p "$TARGET/harness/state"
  cp "$OLD_MANIFEST" "$TARGET/harness/state/cleanup-prev-manifest.json" 2>/dev/null || true
fi

# 4. install: copy the tree + wire settings. NOT --strict here. On an upgrade that
#    drops files, the freshly-copied tree is valid but the target still carries
#    orphans + stale hook wiring from the OLD version — which --strict would abort
#    on (set -e) BEFORE cleanup (4b) could remove them. The strict gate moves to
#    4c, after cleanup.
echo "installing harness into ${TARGET} ..."
$PY "$WORK/harness/install/install.py" --source "$WORK" --target "$TARGET"

# 4b. clean up files the previous version left behind (safe layer only). This must
#     NEVER fail the install — the harness is already copied — so the call is
#     guarded: a backup/rollback error just defers to the manual door. Modified
#     orphans are reported, not removed (the shell can't prompt).
if [ -n "$OLD_MANIFEST" ]; then
  echo "cleaning up files dropped by the previous version ..."
  $PY "$WORK/harness/scripts/cleanup_orphans.py" --target "$TARGET" \
    --old-manifest "$OLD_MANIFEST" --apply \
    || echo "  cleanup deferred — run hs:cleanup in ${TARGET} to review"
fi

# 4c. strict integrity gate, AFTER cleanup so version-dropped orphans are already
#     gone. A drift now is a genuine copy/wiring defect, not old-version residue.
echo "verifying install (strict) ..."
$PY "$TARGET/harness/scripts/verify_install.py" --root "$TARGET" --strict

# 5. run the suite against the installed copy (opt-in; --run-tests to enable).
if [ "$RUN_TESTS" -eq 1 ]; then
  echo "running the harness test suite in ${TARGET} (--run-tests) ..."
  # --confcutdir pins the conftest boundary at the installed harness/ tree so a
  # host conftest.py ABOVE $TARGET (which may import packages the harness does not)
  # is never loaded; -p no:cacheprovider keeps pytest from writing a cache into the
  # host repo. dev-repo-only tests (@pytest.mark.dev_repo) self-skip off the dev tree.
  ( cd "$TARGET" && $PY -m pytest --confcutdir "$TARGET/harness" -p no:cacheprovider harness/tests/ -q )
else
  echo "skipping the harness test suite (default; use --run-tests to run it)."
fi

echo "done."
echo "  - enable the hs plugin: run /reload-plugins in Claude Code (or restart it)"
echo "  - re-verify any time: $PY \"${TARGET}/harness/scripts/verify_install.py\" --strict"
if [ "$RUN_TESTS" -eq 0 ]; then
  echo "  - run the suite any time: ( cd \"${TARGET}\" && $PY -m pytest harness/tests/ -q )"
fi
