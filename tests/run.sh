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

    echo '{"sessionId":"sess-1"}' > "$project/sess-1.meta.json"
    echo '{"a":1}' > "$HOME/.claude/settings.json"
    echo '{"b":2}' > "$HOME/.claude/settings.local.json"
    echo '[]' > "$HOME/.claude/keybindings.json"
    echo '# context' > "$HOME/.claude/EXTRA-CONTEXT.md"
    mkdir -p "$HOME/.claude/skills/pkg/nested"
    echo 'skill' > "$HOME/.claude/skills/pkg/SKILL.md"
    echo 'helper' > "$HOME/.claude/skills/pkg/nested/helper.md"
    local dir
    for dir in plans commands agents output-styles rules hooks scheduled-tasks; do
        mkdir -p "$HOME/.claude/$dir"
        echo "$dir" > "$HOME/.claude/$dir/item.md"
    done
    cat > "$HOME/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"secret-account@example.invalid"},
 "mcpServers":{"myserver":{"command":"/home/me/bin/srv",
   "args":["--host=secret-host.example.com"],
   "env":{"API_KEY":"secret-token-value"}}}}
JSON
}

strip_color() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }

assert_contains() {
    grep -qE "$2" <<< "$1" || fail "expected output matching: $2"
}

assert_same_tree() {
    diff -r "$1" "$2" > "$SANDBOX/diff.log" 2>&1 \
        || fail "trees differ: $(head -n 5 "$SANDBOX/diff.log")"
}

commit_count() { git -C "$BACKUP_REPO" rev-list --count HEAD; }

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

# ─── Core behavior (issue #4) ──────────────────────────────────────

test_round_trip_restores_identical_tree() {
    write_config '.'
    run_backup
    cp -a "$HOME" "$SANDBOX/seed"
    rm -rf "$HOME" && mkdir -p "$HOME"
    run_restore
    assert_same_tree "$SANDBOX/seed" "$HOME"
}

test_dry_run_classifies_and_writes_nothing() {
    write_config '.'
    run_backup
    rm "$HOME/.claude/plans/item.md"
    echo 'tampered' > "$HOME/.claude/rules/item.md"
    local same=$(($(find "$HOME" -type f | wc -l) - 1))
    cp -a "$HOME" "$SANDBOX/before"

    bash "$RESTORE_SH" "$BACKUP_REPO" --dry-run > "$SANDBOX/dry.log" 2>&1 \
        || fail "restore.sh --dry-run exited non-zero"
    local output
    output=$(strip_color "$SANDBOX/dry.log")
    assert_contains "$output" "NEW +1 file\(s\)"
    assert_contains "$output" "CHANGED +1 file\(s\)"
    assert_contains "$output" "SAME +$same file\(s\)"
    assert_contains "$output" "CHANGED +.*/rules/item\.md"
    assert_same_tree "$SANDBOX/before" "$HOME"
}

test_deleted_source_files_are_removed_from_backup() {
    write_config '.'
    run_backup
    rm "$HOME/.claude/skills/pkg/nested/helper.md"
    rm "$HOME/.claude/projects/-home-me-proj/memory/MEMORY.md"
    run_backup
    assert_missing "$BACKUP_REPO/skills/pkg/nested/helper.md"
    assert_missing "$PROJECT_BACKUP/memory/MEMORY.md"
    local changes
    changes=$(git -C "$BACKUP_REPO" show --name-status --format= HEAD)
    assert_contains "$changes" "^D.*skills/pkg/nested/helper\.md"
    assert_contains "$changes" "^D.*memory/MEMORY\.md"
}

test_second_backup_makes_no_commit() {
    write_config '.'
    run_backup
    local before
    before=$(commit_count)
    run_backup
    [ "$(commit_count)" = "$before" ] || fail "second run created a commit"
    assert_contains "$(strip_color "$SANDBOX/backup.log")" "No changes detected"
}

test_sanitize_removes_secrets_and_keeps_structure() {
    write_config '.'
    run_backup
    bash "$BACKUP_SH" "$BACKUP_REPO" --sanitize "$SANDBOX/export" > "$SANDBOX/sanitize.log" 2>&1 \
        || fail "backup.sh --sanitize exited non-zero: $(tail -n 3 "$SANDBOX/sanitize.log")"
    local out="$SANDBOX/export/global/claude.json"
    assert_exists "$out"
    if grep -rq 'secret-' "$SANDBOX/export"; then
        fail "export still contains a secret: $(grep -rl 'secret-' "$SANDBOX/export" | head -n 1)"
    fi
    [ "$(jq -r '.mcpServers.myserver.env.API_KEY' "$out")" = "<REDACTED>" ] \
        || fail "env value was not redacted"
}

test_sanitize_redacts_standalone_hosts_and_ips() {
    cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"myserver":{"command":"srv",
   "args":["--verbose","db.example.com","nas.lab.local:8080","192.168.1.20"]}}}
JSON
    write_config '.'
    run_backup
    bash "$BACKUP_SH" "$BACKUP_REPO" --sanitize "$SANDBOX/export" > "$SANDBOX/sanitize.log" 2>&1 \
        || fail "backup.sh --sanitize exited non-zero: $(tail -n 3 "$SANDBOX/sanitize.log")"
    local args
    args=$(jq -c '.mcpServers.myserver.args' "$SANDBOX/export/global/claude.json")
    [ "$args" = '["--verbose","<HOSTNAME>","<HOSTNAME>","<HOSTNAME>"]' ] \
        || fail "unexpected sanitized args: $args"
}

echo "Running tests"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
