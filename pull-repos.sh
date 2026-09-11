#!/usr/bin/env bash
# Fetches/updates the source repositories used by docker-compose.yaml: our forks of the ReCodEx
# components, our own replacement frontend, and the one component still taken from upstream.
# Run this once before the first build, and again whenever you want to pick up changes.
#
# Usage:
#   ./pull-repos.sh                      # use repos.lock (the verified revisions)
#   NO_LOCK=1 ./pull-repos.sh            # ignore the lock; take each repo's default branch
#   REF=v1.2.3 ./pull-repos.sh           # pin every repo to one tag/branch/commit
#   ISOLATE_REF=upcode ./pull-repos.sh   # per-repo override, for working on a fork
#
# Precedence, highest first: <REPO>_REF, REF, repos.lock, the repo's default branch.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Our forks live under this organisation, named `upcode-<component>`; see COMPATIBILITY.md for what
# is forked and why. The destination directories keep the bare upstream names (`repos/api`, ...)
# because docker-compose.yaml's build contexts point at them.
ORG="https://github.com/upol-kmi"
REPO_PREFIX="upcode-"
UPSTREAM_ORG="https://github.com/ReCodEx"

# Repositories we commit into: full clone, and never force over local work.
DEV_REPOS=(api worker isolate)

# Build inputs only: shallow clone, always forced to the pinned revision.
MIRROR_REPOS=(web-app broker monitor cleaner)

# Our own replacement frontend. Its repository is named `upcode-web-ui` while the service and the
# directory are `web-next` (docker-compose.yaml), so it does not go through REPO_PREFIX. SSH rather
# than HTTPS because this is the one repo everybody pushes to. Default branch is `main`, not
# `master`.
WEB_NEXT_URL="git@github.com:upol-kmi/upcode-web-ui.git"
WEB_NEXT_DEFAULT_REF="main"

LOCK_FILE="repos.lock"

mkdir -p repos

# `web-app` is the legacy frontend, which `web-next` replaces; nothing of ours will ever change in
# it, so it is pinned straight to upstream rather than forked. Everything else comes from our org.
source_url() {
    case "$1" in
        web-app) printf '%s/web-app.git\n' "$UPSTREAM_ORG" ;;
        *)       printf '%s/%s%s.git\n' "$ORG" "$REPO_PREFIX" "$1" ;;
    esac
}

# The commit recorded in repos.lock, or failure if the file or the entry is absent. Fields beyond
# the second are comments.
locked_ref() {
    [ -f "$LOCK_FILE" ] || return 1
    awk -v name="$1" '$1 == name && NF > 1 { print $2; found = 1; exit } END { exit !found }' \
        "$LOCK_FILE"
}

resolve_ref() {
    local repo="$1" default="$2" var_name from_lock
    # ISOLATE_REF, WEB_NEXT_REF, ... -- an explicit instruction beats anything written down.
    var_name="$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')_REF"
    if [ -n "${!var_name:-}" ]; then printf '%s\n' "${!var_name}"; return; fi
    if [ -n "${REF:-}" ]; then printf '%s\n' "$REF"; return; fi
    if [ "${NO_LOCK:-}" != "1" ] && from_lock="$(locked_ref "$repo")"; then
        printf '%s\n' "$from_lock"; return
    fi
    printf '%s\n' "$default"
}

# **Re-pointed on every run, and this was a real bug.** The previous version fetched from `origin`
# by name and never set its URL, so changing ORG above had no effect on an already-cloned
# repository: it went on pulling from wherever it was first cloned, silently, and the configuration
# in this file stopped describing reality.
set_origin() {
    local dest="$1" url="$2" current
    current="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
    if [ "$current" != "$url" ]; then
        echo "    origin: $current -> $url"
        git -C "$dest" remote set-url origin "$url"
    fi
}

# Fetch one revision, whether it names a branch, a tag or a commit. A shallow fetch of a commit
# works on GitHub but not on every host, so a plain fetch is the fallback.
fetch_ref() {
    local dest="$1" ref="$2" depth="$3"
    if [ "$depth" = "shallow" ]; then
        git -C "$dest" fetch -q --depth 1 origin "$ref" 2>/dev/null \
            || git -C "$dest" fetch -q origin "$ref" 2>/dev/null \
            || git -C "$dest" fetch -q --tags origin
    else
        git -C "$dest" fetch -q origin "$ref" 2>/dev/null \
            || git -C "$dest" fetch -q --tags origin
    fi
}

# For the mirrors: pure build inputs, nobody develops in repos/<name>. Shallow, and always forced
# to the pinned revision -- there is never local work here to lose. Checked out on a local branch
# called `pinned` rather than detached, purely so `git status` reads sanely; the revision itself is
# printed, since with a commit pin the branch name would not tell you which one.
fetch_mirror_repo() {
    local name="$1" url="$2" ref="$3"
    local dest="repos/$name"

    if [ -d "$dest/.git" ]; then
        echo "==> Updating $name ($ref)"
        set_origin "$dest" "$url"
        fetch_ref "$dest" "$ref" shallow
        git -C "$dest" checkout -q -B pinned FETCH_HEAD
    else
        echo "==> Cloning $name ($ref)"
        git clone -q --depth 1 --branch "$ref" --recurse-submodules "$url" "$dest" 2>/dev/null \
            || {
                git clone -q --recurse-submodules "$url" "$dest"
                git -C "$dest" checkout -q -B pinned "$ref"
            }
    fi
    git -C "$dest" submodule update -q --init --recursive
    echo "    at $(git -C "$dest" rev-parse --short HEAD)"
}

# For the repositories we commit into -- our forks of api, worker and isolate, and the frontend.
# Full clone, because shallow history is a poor fit for a repo you intend to commit, log, blame or
# push from: a push from a shallow clone is refused outright, which is how this list came to include
# api, worker and isolate rather than just web-next.
#
# Never discards local work. On repeat runs: fetch, then move ONLY if there are no uncommitted
# changes and no local commits the remote does not have; otherwise leave the tree alone and say
# why.
fetch_dev_repo() {
    local name="$1" url="$2" ref="$3"
    local dest="repos/$name"

    if [ ! -d "$dest/.git" ]; then
        echo "==> Cloning $name ($ref)"
        git clone -q --branch "$ref" --recurse-submodules "$url" "$dest" 2>/dev/null \
            || {
                git clone -q --recurse-submodules "$url" "$dest"
                git -C "$dest" checkout -q --detach "$ref"
            }
        echo "    at $(git -C "$dest" rev-parse --short HEAD)"
        return
    fi

    echo "==> Checking $name ($ref)"
    set_origin "$dest" "$url"

    # An existing shallow clone does not become a full one by being fetched, and these three were
    # cloned shallow by the previous version of this script. Without this, `git push` from
    # repos/{api,worker,isolate} keeps failing with "shallow update not allowed" and the reason is
    # invisible.
    if [ -f "$dest/.git/shallow" ]; then
        echo "    deepening a shallow clone (it is a repo we commit into now)"
        git -C "$dest" fetch -q --unshallow origin 2>/dev/null || git -C "$dest" fetch -q --unshallow
    fi

    fetch_ref "$dest" "$ref" full

    if ! git -C "$dest" diff --quiet || ! git -C "$dest" diff --cached --quiet; then
        echo "    ! $name has uncommitted local changes -- leaving it alone. Update it yourself" \
             "(cd $dest && git pull) once you've committed or stashed."
        return
    fi

    local local_head fetched_head
    local_head="$(git -C "$dest" rev-parse HEAD)"
    fetched_head="$(git -C "$dest" rev-parse FETCH_HEAD)"

    if [ "$local_head" = "$fetched_head" ]; then
        echo "    already at $(git -C "$dest" rev-parse --short HEAD)"
    elif git -C "$dest" merge-base --is-ancestor HEAD FETCH_HEAD; then
        echo "    fast-forwarding to $(git -C "$dest" rev-parse --short FETCH_HEAD)"
        git -C "$dest" checkout -q --detach FETCH_HEAD
        git -C "$dest" submodule update -q --init --recursive
    else
        echo "    ! $name is not an ancestor of $ref -- leaving it alone. It either carries local" \
             "commits, or the lock moved backwards. Sort it out yourself (cd $dest)."
    fi
}

if [ "${NO_LOCK:-}" = "1" ]; then
    echo "==> Ignoring $LOCK_FILE (NO_LOCK=1): taking default branches"
elif [ -f "$LOCK_FILE" ]; then
    echo "==> Using $LOCK_FILE"
fi

for repo in "${MIRROR_REPOS[@]}"; do
    fetch_mirror_repo "$repo" "$(source_url "$repo")" "$(resolve_ref "$repo" master)"
done

for repo in "${DEV_REPOS[@]}"; do
    fetch_dev_repo "$repo" "$(source_url "$repo")" "$(resolve_ref "$repo" master)"
done

fetch_dev_repo "web-next" "$WEB_NEXT_URL" "$(resolve_ref web-next "$WEB_NEXT_DEFAULT_REF")"

echo "==> Done. Source trees are in ./repos/*"
