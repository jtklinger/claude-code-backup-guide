#!/usr/bin/env bash
# Test entrypoint. Every test runs against a throwaway HOME, so the real
# ~/.claude is never read or written. Usage: bash tests/run.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_SH="$REPO_ROOT/scripts/backup.sh"
RESTORE_SH="$REPO_ROOT/scripts/restore.sh"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

PASSED=0
FAILED=0
CURRENT_FAILED=0

fail() {
    echo "    FAIL: $1"
    CURRENT_FAILED=1
}

assert_exists() { [ -e "$1" ] || fail "expected to exist: ${1#"$SANDBOX"/}"; }
assert_missing() { [ ! -e "$1" ] || fail "expected to be absent: ${1#"$SANDBOX"/}"; }

# Creates a throwaway HOME holding one project with every kind of session data.
seed_home() {
    local project="$HOME/.claude/projects/-home-me-proj"
    mkdir -p "$project/memory" "$project/sess-1/subagents" "$project/sess-1/tool-results" "$HOME/.claude/todos"
    echo '# settings' > "$HOME/.claude/CLAUDE.md"
    echo 'note' > "$project/memory/MEMORY.md"
    echo '{}' > "$project/sess-1.jsonl"
    echo '{}' > "$project/sess-1/subagents/agent.jsonl"
    echo 'out' > "$project/sess-1/tool-results/result.txt"
    echo '[]' > "$HOME/.claude/todos/todo.json"
}

# write_config <jq expression applied to the default template>
write_config() {
    jq "$1" "$REPO_ROOT/templates/backup-config.json" > "$BACKUP_REPO/backup-config.json"
}

run_backup() {
    bash "$BACKUP_SH" "$BACKUP_REPO" > "$SANDBOX/backup.log" 2>&1 \
        || fail "backup.sh exited non-zero: $(tail -n 3 "$SANDBOX/backup.log")"
}

run_restore() {
    bash "$RESTORE_SH" "$BACKUP_REPO" --yes > "$SANDBOX/restore.log" 2>&1 \
        || fail "restore.sh exited non-zero: $(tail -n 3 "$SANDBOX/restore.log")"
}

run_test() {
    local name="$1"
    SANDBOX=$(mktemp -d)
    HOME="$SANDBOX/home"
    BACKUP_REPO="$SANDBOX/backup"
    PROJECT_BACKUP="$BACKUP_REPO/projects/-home-me-proj"
    export HOME
    mkdir -p "$HOME" "$BACKUP_REPO"
    git -C "$BACKUP_REPO" init -q -b main
    seed_home

    CURRENT_FAILED=0
    echo "  $name"
    "$name"

    if [ "$CURRENT_FAILED" -eq 0 ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    rm -rf "$SANDBOX"
}

# ─── include_sessions / include_todos (issue #15) ──────────────────

test_sessions_false_skips_all_session_data() {
    write_config '.include_sessions = false'
    run_backup
    assert_exists "$PROJECT_BACKUP/memory/MEMORY.md"
    assert_missing "$PROJECT_BACKUP/sessions/sess-1.jsonl"
    assert_missing "$PROJECT_BACKUP/subagents"
    assert_missing "$PROJECT_BACKUP/tool-results"
}

test_todos_false_skips_todos() {
    write_config '.include_todos = false'
    run_backup
    assert_missing "$BACKUP_REPO/todos/todo.json"
}

test_absent_flags_default_to_included() {
    write_config 'del(.include_sessions, .include_todos)'
    run_backup
    assert_exists "$PROJECT_BACKUP/sessions/sess-1.jsonl"
    assert_exists "$PROJECT_BACKUP/subagents/sess-1/agent.jsonl"
    assert_exists "$PROJECT_BACKUP/tool-results/sess-1/result.txt"
    assert_exists "$BACKUP_REPO/todos/todo.json"
}

test_turning_sessions_off_keeps_data_already_backed_up() {
    write_config '.'
    run_backup
    write_config '.include_sessions = false'
    run_backup
    assert_exists "$PROJECT_BACKUP/sessions/sess-1.jsonl"
    assert_exists "$PROJECT_BACKUP/subagents/sess-1/agent.jsonl"
    assert_exists "$PROJECT_BACKUP/tool-results/sess-1/result.txt"
}

test_restore_honors_todos_false() {
    write_config '.'
    run_backup
    write_config '.include_todos = false'
    rm -rf "$HOME/.claude/todos"
    run_restore
    assert_missing "$HOME/.claude/todos/todo.json"
}

echo "Running tests"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
