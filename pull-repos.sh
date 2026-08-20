#!/usr/bin/env bash
# Fetches/updates the source repositories used by docker-compose.yaml: the upstream
# ReCodEx repos, plus our own replacement frontend (a separate repo, not upstream).
# Run this once before the first build, and again whenever you want to pick up changes.
#
# Usage:
#   ./pull-repos.sh              # clone/update all repos on their default branch
#   REF=v1.2.3 ./pull-repos.sh   # pin ALL upstream ReCodEx repos to a specific tag/branch/commit
#
# Per-repo pins can also be set individually, e.g.:
#   API_REF=abcdef1 WORKER_REF=v2.4.0 WEB_NEXT_REF=some-branch ./pull-repos.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ORG="https://github.com/ReCodEx"
REPOS=(api web-app worker broker monitor isolate cleaner)

REF_DEFAULT="${REF:-master}"

# Our own replacement frontend (docs/DECISIONS.md's recodex-web-next, brief-driven rewrite of
# web-app) -- not part of the upstream ReCodEx org, so it isn't in REPOS/ORG above, but it's
# fetched the same way for the same reason: one script brings the whole stack together.
# Destination is repos/web-next (matching docker-compose.yaml's `web-next` service), independent
# of whatever the repo itself happens to be named on its remote. Default branch is `main`, not
# `master` -- kept as its own variable rather than folded into REF_DEFAULT above, since forcing
# `master` here would silently fail to clone.
WEB_NEXT_URL="git@github.com:jurja00/codeUp-web-ui.git"
WEB_NEXT_REF_DEFAULT="${WEB_NEXT_REF:-main}"

mkdir -p repos

# For the upstream repos: pure build inputs, nobody develops in repos/<name> directly. Shallow
# clone (fast, small) and always force the working tree to match the pinned ref on every run --
# there is never local work here to lose. Ends up on a real local branch named after $ref (not a
# detached HEAD) purely for a saner `git status` if anyone looks; still fine either way for these.
fetch_readonly_repo() {
    local name="$1" url="$2" ref="$3"
    local dest="repos/$name"

    if [ -d "$dest/.git" ]; then
        echo "==> Updating $name (ref: $ref)"
        git -C "$dest" fetch --depth 1 origin "$ref"
        git -C "$dest" checkout -q -B "$ref" FETCH_HEAD
        git -C "$dest" submodule update --init --recursive
    else
        echo "==> Cloning $name (ref: $ref)"
        git clone --depth 1 --branch "$ref" --recurse-submodules "$url" "$dest" 2>/dev/null \
            || { git clone --recurse-submodules "$url" "$dest" && git -C "$dest" checkout -q -B "$ref" "$ref" && git -C "$dest" submodule update --init --recursive; }
    fi
}

# For web-next: this one gets developed in directly (repos/web-next IS a normal working copy of
# its own separate repo), so this must never silently discard local work. Full clone (not
# --depth 1) -- shallow history is a poor fit for a repo you intend to commit/log/blame in. On
# repeat runs: fetch, then fast-forward ONLY if there are no uncommitted changes and no local
# commits that aren't on the remote yet; otherwise leave the working tree untouched and say why,
# rather than force-resetting over someone's in-progress work.
fetch_dev_repo() {
    local name="$1" url="$2" ref="$3"
    local dest="repos/$name"

    if [ ! -d "$dest/.git" ]; then
        echo "==> Cloning $name (ref: $ref)"
        git clone --branch "$ref" --recurse-submodules "$url" "$dest"
        return
    fi

    echo "==> Checking $name (ref: $ref)"
    git -C "$dest" fetch origin "$ref"

    if ! git -C "$dest" diff --quiet || ! git -C "$dest" diff --cached --quiet; then
        echo "    ! $name has uncommitted local changes -- leaving it alone. Update it yourself" \
             "(cd $dest && git pull) once you've committed or stashed."
        return
    fi

    local local_head fetched_head
    local_head="$(git -C "$dest" rev-parse HEAD)"
    fetched_head="$(git -C "$dest" rev-parse FETCH_HEAD)"

    if [ "$local_head" = "$fetched_head" ]; then
        echo "    already up to date."
    elif git -C "$dest" merge-base --is-ancestor HEAD FETCH_HEAD; then
        echo "    fast-forwarding to latest $ref"
        git -C "$dest" checkout -q -B "$ref" FETCH_HEAD
        git -C "$dest" submodule update --init --recursive
    else
        echo "    ! $name has local commits not on origin/$ref -- leaving it alone. Push your work," \
             "or update it yourself (cd $dest && git pull), when ready."
    fi
}

for repo in "${REPOS[@]}"; do
    var_name="$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')_REF"
    ref="${!var_name:-$REF_DEFAULT}"
    fetch_readonly_repo "$repo" "$ORG/$repo.git" "$ref"
done

fetch_dev_repo "web-next" "$WEB_NEXT_URL" "$WEB_NEXT_REF_DEFAULT"

echo "==> Done. Source trees are in ./repos/*"
