#!/usr/bin/env sh
# Harness bootstrap — paste into the sandbox SETUP step (runs before the session).
# Claude Code binds `env` and snapshots plugins at startup, and a sandbox session
# never restarts, so this has to land first or not at all.
#
# Pin the release in the sandbox ENV field:   HARNESS_VERSION=7.2.0
# Skip every pip step with SKIP_DEPS=1 (the image already carries the deps).
set -eu

HARNESS_VERSION="${HARNESS_VERSION:-7.2.0}"
TARBALL="harness-v${HARNESS_VERSION}.tar.gz"
BASE="https://github.com/hieubui2409/sdlc-harness-release/releases/download"
TARBALL_URL="${BASE}/harness-v${HARNESS_VERSION}/${TARBALL}"

say() { echo "harness-setup: $*" >&2; }
die() { echo "harness-setup: FAILED — $*" >&2; exit 1; }

# --- interpreter -----------------------------------------------------------
# 7.x needs Python >= 3.12: preflight_deps.py rejects anything older, and the
# installer wires THIS interpreter into every hook command via HARNESS_PY. Probe
# the versioned names first (same order as the release install.sh) — Debian-family
# images keep `python3` at 3.11 while 3.12/3.13 sit on PATH only by version.
PY=""
for cand in python3.13 python3.12 python3 python; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
        PY="$cand"; break
    fi
done
[ -n "$PY" ] || die "no Python >= 3.12 on PATH (looked for python3.13, python3.12, python3, python)"
export HARNESS_PY="$PY"
say "python: $PY ($("$PY" -c 'import sys; print(sys.version.split()[0])'))"

# Install into the SAME interpreter the hooks will run on — a bare pip3 may belong
# to another Python. The retry covers PEP 668 images; the container is throwaway.
pip_install() {
    "$PY" -m pip install --quiet "$@" \
        || "$PY" -m pip install --quiet --break-system-packages "$@"
}
# requirements + constraints when the lockfile is there (hard pins, reproducible).
pip_reqs() {  # $1 = requirements file, $2 = constraints file (may not exist)
    if [ -f "$2" ]; then pip_install -r "$1" -c "$2"; else pip_install -r "$1"; fi
}

# --- locate the repo -------------------------------------------------------
# The setup step's cwd is not guaranteed to be the clone, so fall back to the
# single directory under /home/user. Refuse to guess when there is more than one:
# installing into the wrong tree is worse than stopping with a clear message.
if [ -d .git ] || [ -f CLAUDE.md ]; then
    TARGET=$(pwd)
else
    n=$(find /home/user -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    [ "$n" -eq 1 ] || die "expected exactly one directory under /home/user, found $n — cd into the repo first"
    TARGET=$(find /home/user -maxdepth 1 -mindepth 1 -type d)
fi
cd "$TARGET" || die "cannot enter $TARGET"
say "target: $TARGET"

# --- skills + agents, without the marketplace ------------------------------
# This environment sets SKIP_PLUGIN_MARKETPLACE=true, which cannot be overridden
# from the env field, so the hs-local directory marketplace the installer writes
# into .claude/settings.json never loads and `hs:` skills never appear.
#
# The way around it is a skills-directory plugin: any folder under a skills
# directory that holds a .claude-plugin/plugin.json manifest loads as
# <name>@skills-dir, with no marketplace and no install step. The hs plugin
# directory already IS such a folder, so one symlink carries skills, agents and
# workflows, and the hs: namespace survives as hs@skills-dir.
#
# PERSONAL scope (~/.claude/skills), not project scope: a project-scope
# @skills-dir plugin loads only after the workspace trust dialog is accepted, and
# nobody is present to accept it. ~/.claude does not survive a container, hence
# doing it here.
wire_skills_dir() {  # $1 = path to the hs plugin directory
    [ -f "$1/.claude-plugin/plugin.json" ] || die "no plugin manifest at $1"
    mkdir -p "$HOME/.claude/skills"
    ln -sfn "$1" "$HOME/.claude/skills/hs"
    [ -f "$HOME/.claude/skills/hs/skills/plan/SKILL.md" ] \
        || die "hs@skills-dir wired but the link does not resolve"
    # Count entries that actually hold a SKILL.md — skills/ also carries resource
    # dirs (_shared, _docslib) that are not skills. -L follows symlinks: in the
    # dogfood farm every skills/ entry IS one.
    n_skills=$(find -L "$1/skills" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l)
    n_agents=$(ls "$1/agents"/*.md 2>/dev/null | wc -l)
    say "wired hs@skills-dir: ${n_skills} skills, ${n_agents} agents"
}

# --- on-PATH launchers -----------------------------------------------------
# Skill bodies tell the agent to type hs-cli / hs-run / hs-code / ...; verify_install
# warns when they are not on PATH. install.py --cli does this for the installed
# tree; the dogfood tree has no installer pass, so link harness/bin/* by hand.
# ~/.local/bin is on PATH in the cloud image; no-clobber like --cli.
link_launchers() {  # $1 = harness/bin directory
    [ -d "$1" ] || return 0
    mkdir -p "$HOME/.local/bin"
    for f in "$1"/hs-*; do
        [ -f "$f" ] || continue
        [ -e "$HOME/.local/bin/$(basename "$f")" ] || ln -s "$f" "$HOME/.local/bin/$(basename "$f")"
    done
}

# --- user-level Claude Code settings ---------------------------------------
# Written to ~/.claude/settings.json (personal scope), which does not survive a
# container. MERGED, not overwritten: an image that seeds its own keys there keeps
# them, and only the ones below are asserted.
#
# bypassPermissions + skipDangerousModePermissionPrompt turn off the approval
# prompts. That is the point in an unattended sandbox — nobody is there to answer
# one — and the blast radius is a throwaway container holding one repo. Do not
# carry this file to a workstation.
write_user_settings() {
    mkdir -p "$HOME/.claude"
    "$PY" - "$HOME/.claude/settings.json" <<'PY'
import json, sys, pathlib
want = {
    "permissions": {"defaultMode": "bypassPermissions"},
    "model": "opus",
    "language": "Vietnamese",
    "effortLevel": "high",
    "askUserQuestionTimeout": "never",
    "skipDangerousModePermissionPrompt": True,
}
p = pathlib.Path(sys.argv[1])
try:
    cur = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(cur, dict):
        cur = {}
except (OSError, ValueError):
    cur = {}          # absent or corrupt — assert the wanted keys onto a clean map
for k, v in want.items():
    # One level of merge is enough: `permissions` is the only nested key here, and
    # a blind replace would drop a seeded allow/deny list alongside defaultMode.
    if isinstance(v, dict) and isinstance(cur.get(k), dict):
        cur[k].update(v)
    else:
        cur[k] = v
p.write_text(json.dumps(cur, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("keys: " + ", ".join(sorted(want)))
PY
}

say "user settings: $(write_user_settings)"

# --- which repo is this? ---------------------------------------------------
# harness/tests/ is the discriminator: the installer drops that prefix from every
# install (courier_tree._DROP_PREFIXES), so the engine's own tree has it and an
# installed copy never does. An installed project also has a harness/ directory,
# and dogfooding one would build a skill farm against a tree with no full catalog.
if [ -d harness/tests ] && [ -f harness/install/install.py ] \
   && [ -f harness/scripts/dev_skill_farm.py ]; then
    say "detected: sdlc-harness source — dogfood, no install"
    # The full declared set, OPTIONAL rows included: the suite's documented CI argv
    # needs pytest-xdist / pytest-split / pytest-randomly / pytest-timeout etc.
    if [ "${SKIP_DEPS:-0}" != "1" ]; then
        say "deps: harness/requirements.txt ..."
        pip_reqs harness/requirements.txt harness/constraints.txt \
            || say "deps: harness set failed — continuing, the suite may not run"
        if [ -f orchestrator/requirements.txt ]; then
            # langfuse is documented optional, but orchestrator tests import it.
            pip_install -r orchestrator/requirements.txt \
                || say "deps: orchestrator set failed — continuing"
        fi
    fi
    "$PY" harness/scripts/preflight_deps.py --quiet \
        || die "preflight_deps: a REQUIRED dependency is missing — run: $PY harness/scripts/preflight_deps.py"
    [ -f scripts/dev_init.py ] || die "scripts/dev_init.py missing — pull the latest main"
    # Rebuilds .harness-dev/hs-plugins (the curated farm) + .claude/settings.json,
    # with HARNESS_* pointing at this checkout's own .harness-dev/*.yaml. Both are
    # gitignored on purpose; the .yaml they read are tracked.
    "$PY" scripts/dev_init.py || die "dev_init.py failed"
    "$PY" scripts/dev_init.py --check >/dev/null 2>&1 \
        || die "dev_init reported success but --check disagrees"
    # The farm, not harness/plugins: dogfood runs the curated subset.
    wire_skills_dir "$TARGET/.harness-dev/hs-plugins/hs"
    link_launchers "$TARGET/harness/bin"
    say "dogfood ready"
else
    say "detected: other repo — installing harness v${HARNESS_VERSION}"
    command -v curl >/dev/null 2>&1 || die "curl not on PATH"
    tmp=$(mktemp -d) || die "cannot create a temp dir"
    # shellcheck disable=SC2064 — expand tmp now, at trap-set time
    trap "rm -rf '$tmp'" EXIT INT TERM

    # Pinned, not resolved: install.sh asks api.github.com for the latest tag and
    # locked-down sandboxes 403 that. This asset URL redirects to
    # release-assets.githubusercontent.com, which the same networks do allow.
    say "downloading ${TARBALL} ..."
    curl -fsSL --max-time 300 "$TARBALL_URL" -o "$tmp/$TARBALL" \
        || die "cannot download $TARBALL_URL (network blocked, or no such version)"
    curl -fsSL --max-time 60 "${TARBALL_URL}.sha256" -o "$tmp/sha" 2>/dev/null || true
    if [ -s "$tmp/sha" ] && command -v sha256sum >/dev/null 2>&1; then
        exp=$(cut -d' ' -f1 < "$tmp/sha")
        act=$(sha256sum "$tmp/$TARBALL" | cut -d' ' -f1)
        [ "$exp" = "$act" ] || die "checksum mismatch (expected $exp, got $act)"
        say "checksum OK"
    fi

    # Tar-escape guard, as in the release install.sh: refuse an absolute member,
    # a '..' climb, or a link pointing out of the tree before extracting anything.
    "$PY" - "$tmp/$TARBALL" <<'PY' || die "unsafe tarball — refusing to extract"
import os, sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as tf:
    for m in tf.getmembers():
        name = m.name
        if os.path.isabs(name):
            sys.exit("absolute member path %r" % name)
        norm = os.path.normpath(name)
        if norm == ".." or norm.startswith(".." + os.sep):
            sys.exit("path-traversal member %r" % name)
        if m.issym() or m.islnk():
            joined = os.path.normpath(os.path.join(os.path.dirname(name), m.linkname))
            if os.path.isabs(m.linkname) or joined.startswith(".."):
                sys.exit("unsafe link %r -> %r" % (name, m.linkname))
PY
    mkdir -p "$tmp/ext"
    tar -xzf "$tmp/$TARBALL" -C "$tmp/ext" || die "cannot extract $TARBALL"
    [ -f "$tmp/ext/harness/install/install.py" ] || die "bundle has no installer — wrong asset"

    # Deps BEFORE the installer: 7.x install.py itself imports ruamel.yaml (via
    # yaml_io), so it crashes on a bare image. requirements-runtime.txt is the
    # REQUIRED subset preflight checks; the hooks need nothing else.
    if [ "${SKIP_DEPS:-0}" != "1" ]; then
        say "deps: requirements-runtime.txt ..."
        pip_reqs "$tmp/ext/harness/requirements-runtime.txt" "$tmp/ext/harness/constraints.txt" \
            || say "deps: runtime set failed — preflight decides"
    fi
    "$PY" "$tmp/ext/harness/scripts/preflight_deps.py" \
        || die "preflight_deps: a REQUIRED dependency is missing (see the pip command above)"

    # Upgrade over a committed install: snapshot the old manifest so cleanup can
    # tell version-dropped files from user-added ones (same as install.sh step 3b).
    old_manifest=""
    if [ -f harness/manifest.json ]; then
        old_manifest="$tmp/old-manifest.json"
        cp harness/manifest.json "$old_manifest"
        mkdir -p harness/state
        cp "$old_manifest" harness/state/cleanup-prev-manifest.json 2>/dev/null || true
    fi

    # Default skill selection, NOT --all-skills: the shipped policy installs the
    # working set and stashes the rest (/hs:use <name> enables one later). --project
    # is explicit so no mode warning; --cli puts hs-cli & co. on ~/.local/bin.
    # Not --strict here: on an upgrade the stale files are still present until
    # cleanup runs, so the strict gate comes after it.
    "$PY" "$tmp/ext/harness/install/install.py" \
        --target "$TARGET" --source "$tmp/ext" --non-interactive --project --cli \
        || die "install.py failed"

    if [ -n "$old_manifest" ]; then
        "$PY" "$tmp/ext/harness/scripts/cleanup_orphans.py" --target "$TARGET" \
            --old-manifest "$old_manifest" --apply \
            || say "cleanup deferred — run /hs:cleanup to review"
    fi

    [ -f .claude/settings.json ] || die "install produced no .claude/settings.json"
    [ -d harness/plugins/hs ] || die "install produced no harness/plugins/hs tree"
    "$PY" harness/scripts/verify_install.py --root "$TARGET" --strict >/dev/null \
        || die "verify_install --strict rejected the fresh install — run: $PY harness/scripts/verify_install.py --strict"
    wire_skills_dir "$TARGET/harness/plugins/hs"
    say "install ready"
fi

say "done — Claude Code picks this up at its next launch"
