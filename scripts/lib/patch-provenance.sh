# shellcheck shell=bash
#
# patch-provenance.sh — single source of truth for Trio-Patch-* provenance
# trailers. Sourced (never executed) by scripts/generate-patch.sh and
# scripts/mid-stack-update.sh. Callers already run `set -euo pipefail`, so this
# file sets no shell options; every function is safe under those options and
# bash 3.2 (macOS /bin/bash).

# Stable patch-id of a single commit's diff (empty on failure). A patch-id hashes the
# diff content, so it is stable across rebase/amend — the canonical identity for
# "is this change already represented in the patch?". Always at most one line of
# output; a merge commit has no single meaningful patch-id and yields empty.
_patch_id() {
    if [ "$(git rev-list --no-walk --count --merges "$1" 2>/dev/null || echo 0)" != 0 ]; then
        return 0
    fi
    git show --no-color "$1" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}' | head -1
}
# Every patch-id line of a commit's diff, including the multiple lines a merge
# commit's combined diff produces. Exists only for legacy-trailer compatibility:
# patches generated before v1.13 could record a merge-derived id, and the
# alignment gate must still be able to match those. Never use this to build a
# cherry-pick candidate list.
_patch_ids_all() {
    git show --no-color "$1" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}'
}

# Extract patch-ids recorded in a patch file under the `Trio-Patch-Source-PatchIds:`
# trailer (one indented hex id per line until the block ends). The block ends at a
# blank line, a new `Key:`-style trailer line, or a bare `---` (the mail-body/diff
# separator in a git-am patch). A malformed line inside the block warns on stderr
# and scanning continues. Empty if none recorded.
_recorded_patch_ids() {
    awk -v f="$1" '
        /^Trio-Patch-Source-PatchIds:[[:space:]]*$/ { cap=1; next }
        cap && /^[[:space:]]+[0-9a-f]{7,}[[:space:]]*$/ { gsub(/[[:space:]]/,""); print; next }
        cap && (/^[[:space:]]*$/ || /^[A-Za-z][A-Za-z0-9-]*:/ || /^[[:space:]]*---[[:space:]]*$/) { cap=0; next }
        cap { printf "warning: %s: unrecognized line in Trio-Patch-Source-PatchIds block: %s\n", f, $0 > "/dev/stderr"; next }
    ' "$1"
}

# Branch name recorded in the patch's `Trio-Patch-Source-Branch:` trailer (empty if none).
_recorded_source_branch() {
    awk -F': ' '/^Trio-Patch-Source-Branch:[[:space:]]/ { print $2; exit }' "$1" 2>/dev/null
}

# write_provenance_trailers <feature_branch> <out_file> [base_ref]
# Writes the Trio-Patch-* trailer block for <feature_branch> (relative to
# base_ref, default dev) to <out_file>. Writes nothing and returns 1 when the
# merge-base or tip cannot be resolved. Prints nothing itself.
write_provenance_trailers() {
    local _wp_branch="$1" _wp_out="$2" _wp_base="${3:-dev}"
    local _wp_mb _wp_tip _wp_c _wp_id
    _wp_mb=$(git merge-base "$_wp_base" "$_wp_branch" 2>/dev/null || true)
    _wp_tip=$(git rev-parse "$_wp_branch" 2>/dev/null || true)
    if [ -z "$_wp_mb" ] || [ -z "$_wp_tip" ]; then
        return 1
    fi
    {
        echo "Trio-Patch-Source-Branch: $_wp_branch"
        echo "Trio-Patch-Base: $_wp_mb"
        echo "Trio-Patch-Feature-Tip: $_wp_tip"
        echo "Trio-Patch-Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Trio-Patch-Source-Commits:"
        git log --reverse --format=' %H %s' "$_wp_mb..$_wp_tip" 2>/dev/null
        echo "Trio-Patch-PatchIds-Note: merge commits are omitted (no single patch-id); see Trio-Patch-Source-Commits for full history"
        echo "Trio-Patch-Source-PatchIds:"
        git log --reverse --no-merges --format='%H' "$_wp_mb..$_wp_tip" 2>/dev/null | while read -r _wp_c; do
            [ -n "$_wp_c" ] || continue
            _wp_id=$(_patch_id "$_wp_c")
            # if/then (not `[ -n ] && echo`): an empty id on the last commit
            # must not make the loop, pipeline and function return non-zero.
            if [ -n "$_wp_id" ]; then
                echo " $_wp_id"
            fi
        done
    } > "$_wp_out"
    return 0
}

# provenance_eligible_branch <branch>
# Returns 0 if provenance should be recorded for <branch>, 1 otherwise: an empty
# name, `dev`, and any `tmp/*` branch (mid-stack-update.sh's throwaway update and
# baseline branches) are not eligible.
provenance_eligible_branch() {
    case "${1:-}" in
        "" | dev | tmp/*) return 1 ;;
        *) return 0 ;;
    esac
}
