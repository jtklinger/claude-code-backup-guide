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
    grep -qE -- "$2" <<< "$1" || fail "expected output matching: $2"
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
    # A whole-machine rebuild: the one case for taking ~/.claude.json whole.
    bash "$RESTORE_SH" "$BACKUP_REPO" --yes --mcp-replace > "$SANDBOX/restore.log" 2>&1 \
        || fail "restore.sh exited non-zero: $(tail -n 3 "$SANDBOX/restore.log")"
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
   "args":["--verbose","config.json","db.example.com","nas.lab.local:8080","192.168.1.20",
           "server.lan","db.internal","host.home.arpa","dc1.corp:389"]}}}
JSON
    write_config '.'
    run_backup
    bash "$BACKUP_SH" "$BACKUP_REPO" --sanitize "$SANDBOX/export" > "$SANDBOX/sanitize.log" 2>&1 \
        || fail "backup.sh --sanitize exited non-zero: $(tail -n 3 "$SANDBOX/sanitize.log")"
    local args
    args=$(jq -c '.mcpServers.myserver.args' "$SANDBOX/export/global/claude.json")
    [ "$args" = '["--verbose","config.json","<HOSTNAME>","<HOSTNAME>","<HOSTNAME>","<HOSTNAME>","<HOSTNAME>","<HOSTNAME>","<HOSTNAME>"]' ] \
        || fail "unexpected sanitized args: $args"
}

# ─── Host guard (issue #20) and manifest (issue #19) ───────────────

this_host() { uname -n | tr -d '\r' | cut -d. -f1; }

test_host_mismatch_refuses_before_touching_repo() {
    write_config '.host = "some-other-machine"'
    if bash "$BACKUP_SH" "$BACKUP_REPO" > "$SANDBOX/backup.log" 2>&1; then
        fail "backup.sh should have exited non-zero"
    fi
    assert_contains "$(strip_color "$SANDBOX/backup.log")" "some-other-machine"
    assert_missing "$BACKUP_REPO/global"
    assert_missing "$BACKUP_REPO/backup-manifest.json"
}

test_host_match_runs() {
    write_config ".host = \"$(this_host)\""
    run_backup
    assert_exists "$BACKUP_REPO/global/CLAUDE.md"
}

test_force_overrides_host_mismatch() {
    write_config '.host = "some-other-machine"'
    bash "$BACKUP_SH" "$BACKUP_REPO" --force > "$SANDBOX/backup.log" 2>&1 \
        || fail "backup.sh --force exited non-zero: $(tail -n 3 "$SANDBOX/backup.log")"
    assert_exists "$BACKUP_REPO/global/CLAUDE.md"
}

test_init_records_current_host() {
    yes '' | bash "$REPO_ROOT/scripts/init.sh" "$BACKUP_REPO" > "$SANDBOX/init.log" 2>&1 \
        || fail "init.sh exited non-zero: $(tail -n 3 "$SANDBOX/init.log")"
    [ "$(jq -r '.host' "$BACKUP_REPO/backup-config.json")" = "$(this_host)" ] \
        || fail "init.sh did not record this host"
}

test_manifest_is_committed_with_expected_fields() {
    write_config '.'
    run_backup
    git -C "$BACKUP_REPO" ls-files --error-unmatch backup-manifest.json > /dev/null 2>&1 \
        || fail "backup-manifest.json is not committed"
    [ "$(jq -r '.hostname' "$BACKUP_REPO/backup-manifest.json")" = "$(this_host)" ] \
        || fail "manifest hostname is wrong"
    [ "$(jq -r '.os' "$BACKUP_REPO/backup-manifest.json")" = "$(uname -s)" ] \
        || fail "manifest os is wrong"
    jq -e '.claude_code_version and .script_version and .timestamp' "$BACKUP_REPO/backup-manifest.json" > /dev/null \
        || fail "manifest is missing fields"
}

test_manifest_timestamp_updates_when_data_changes() {
    write_config '.'
    run_backup
    jq '.timestamp = "old"' "$BACKUP_REPO/backup-manifest.json" > "$SANDBOX/m" && cp "$SANDBOX/m" "$BACKUP_REPO/backup-manifest.json"
    echo 'changed' >> "$HOME/.claude/CLAUDE.md"
    run_backup
    [ "$(jq -r '.timestamp' "$BACKUP_REPO/backup-manifest.json")" != "old" ] \
        || fail "manifest was not refreshed"
}

test_manifest_left_alone_when_nothing_changed() {
    write_config '.'
    run_backup
    jq '.timestamp = "old"' "$BACKUP_REPO/backup-manifest.json" > "$SANDBOX/m" && cp "$SANDBOX/m" "$BACKUP_REPO/backup-manifest.json"
    git -C "$BACKUP_REPO" add backup-manifest.json
    git -C "$BACKUP_REPO" commit -q -m 'age manifest'
    local before
    before=$(commit_count)
    run_backup
    [ "$(jq -r '.timestamp' "$BACKUP_REPO/backup-manifest.json")" = "old" ] \
        || fail "manifest was rewritten with no data change"
    [ "$(commit_count)" = "$before" ] || fail "a run with no changes created a commit"
}

test_sanitized_export_has_no_manifest() {
    write_config '.'
    run_backup
    bash "$BACKUP_SH" "$BACKUP_REPO" --sanitize "$SANDBOX/export" > "$SANDBOX/sanitize.log" 2>&1 \
        || fail "backup.sh --sanitize exited non-zero"
    assert_missing "$SANDBOX/export/backup-manifest.json"
}

# Backs up, then rewrites the manifest as if another machine had made it.
make_foreign_backup() {
    write_config '.'
    run_backup
    jq '.hostname = "some-other-machine"' "$BACKUP_REPO/backup-manifest.json" > "$SANDBOX/m"
    cp "$SANDBOX/m" "$BACKUP_REPO/backup-manifest.json"
}

test_restore_warns_on_hostname_mismatch() {
    make_foreign_backup
    run_restore
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "WARN.*some-other-machine"
}

test_restore_dry_run_warns_on_hostname_mismatch() {
    make_foreign_backup
    bash "$RESTORE_SH" "$BACKUP_REPO" --dry-run > "$SANDBOX/dry.log" 2>&1 \
        || fail "restore.sh --dry-run exited non-zero"
    assert_contains "$(strip_color "$SANDBOX/dry.log")" "WARN.*some-other-machine"
}

test_restore_same_host_does_not_warn() {
    write_config '.'
    run_backup
    run_restore
    if strip_color "$SANDBOX/restore.log" | grep -q 'different machine'; then
        fail "warned about a backup from this machine"
    fi
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "Backup made on $(this_host)"
}

test_restore_without_manifest_still_works() {
    write_config '.'
    run_backup
    rm -f "$BACKUP_REPO/backup-manifest.json"
    rm -rf "$HOME/.claude/rules"
    run_restore
    assert_exists "$HOME/.claude/rules/item.md"
}

# ─── Restore fixes (issues #21, #24, #22, #25) ─────────────────────

wipe_home() { rm -rf "$HOME" && mkdir -p "$HOME"; }

count_timestamp_copies() { find "$HOME" -name '*.backup.*' | wc -l | tr -d ' '; }

test_restore_makes_no_copy_of_identical_files() {
    write_config '.'
    run_backup
    run_restore
    [ "$(count_timestamp_copies)" = "0" ] || fail "made .backup copies of identical files"
}

test_restore_copies_then_replaces_changed_file() {
    write_config '.'
    run_backup
    echo 'local edit' > "$HOME/.claude/rules/item.md"
    run_restore
    [ "$(count_timestamp_copies)" = "1" ] || fail "expected exactly one .backup copy"
    [ "$(cat "$HOME/.claude/rules/item.md")" = "rules" ] || fail "changed file was not restored"
    [ "$(cat "$HOME/.claude/rules"/item.md.backup.*)" = "local edit" ] || fail "local edit was not preserved"
}

test_restore_summary_lists_only_restored_files() {
    write_config '.'
    run_backup
    wipe_home
    mkdir -p "$HOME/.claude"
    echo '{}' > "$HOME/.claude/policy-limits.json"
    run_restore
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    if grep -q 'policy-limits' <<< "$output"; then
        fail "summary listed a file the restore never wrote"
    fi
    assert_contains "$output" "skills: 2 file\(s\)"
}

test_restore_summary_counts_identical_files() {
    write_config '.'
    run_backup
    echo 'local edit' > "$HOME/.claude/rules/item.md"
    run_restore
    local same=$(($(find "$HOME" -type f -not -name '*.backup.*' | wc -l) - 1))
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "Restored files \(1 total\)"
    assert_contains "$output" "rules: 1 file\(s\)"
    assert_contains "$output" "$same file\(s\) already identical"
}

test_skip_excludes_named_categories() {
    write_config '.'
    run_backup
    wipe_home
    bash "$RESTORE_SH" "$BACKUP_REPO" --yes --skip mcp,todos > "$SANDBOX/restore.log" 2>&1 \
        || fail "restore.sh --skip exited non-zero: $(tail -n 3 "$SANDBOX/restore.log")"
    assert_missing "$HOME/.claude.json"
    assert_missing "$HOME/.claude/todos"
    assert_exists "$HOME/.claude/skills/pkg/SKILL.md"
    assert_exists "$HOME/.claude/rules/item.md"
}

test_only_restores_just_named_categories() {
    write_config '.'
    run_backup
    wipe_home
    bash "$RESTORE_SH" "$BACKUP_REPO" --yes --only=skills,rules > "$SANDBOX/restore.log" 2>&1 \
        || fail "restore.sh --only exited non-zero: $(tail -n 3 "$SANDBOX/restore.log")"
    assert_exists "$HOME/.claude/skills/pkg/SKILL.md"
    assert_exists "$HOME/.claude/rules/item.md"
    assert_missing "$HOME/.claude.json"
    assert_missing "$HOME/.claude/CLAUDE.md"
    assert_missing "$HOME/.claude/plans"
    assert_missing "$HOME/.claude/projects"
}

test_unknown_category_is_refused_before_writing() {
    write_config '.'
    run_backup
    wipe_home
    if bash "$RESTORE_SH" "$BACKUP_REPO" --yes --skip mpc > "$SANDBOX/restore.log" 2>&1; then
        fail "a misspelled category should be refused"
    fi
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "mpc"
    assert_missing "$HOME/.claude"
}

test_skip_and_only_together_are_refused() {
    write_config '.'
    run_backup
    wipe_home
    if bash "$RESTORE_SH" "$BACKUP_REPO" --yes --skip mcp --only skills > "$SANDBOX/restore.log" 2>&1; then
        fail "--skip with --only should be refused"
    fi
    assert_missing "$HOME/.claude"
}

test_interactive_prompts_show_labels_and_honor_answers() {
    write_config '.'
    run_backup
    wipe_home
    yes n | bash "$RESTORE_SH" "$BACKUP_REPO" > "$SANDBOX/restore.log" 2>&1
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "Restore MCP config \(~/\.claude\.json\)\?"
    assert_contains "$output" "Restore rules\?"
    assert_contains "$output" "Restore Projects \(1 in backup\)\?"
    assert_missing "$HOME/.claude.json"
    assert_missing "$HOME/.claude/skills"
}

seed_imports() {
    cat > "$HOME/.claude/CLAUDE.md" <<'MD'
# settings
@/nonexistent/shared/prefs.md
@~/missing-from-home.md
@EXTRA-CONTEXT.md
@someone mentioned in prose
MD
}

assert_import_warnings() {
    assert_contains "$1" "WARNING.*/nonexistent/shared/prefs\.md"
    assert_contains "$1" "WARNING.*missing-from-home\.md"
    if grep -q 'WARNING.*EXTRA-CONTEXT' <<< "$1"; then
        fail "warned about an import that exists in the backup"
    fi
    if grep -q 'WARNING.*someone' <<< "$1"; then
        fail "treated prose as an import"
    fi
}

test_restore_warns_about_missing_imports() {
    seed_imports
    write_config '.'
    run_backup
    wipe_home
    run_restore
    assert_import_warnings "$(strip_color "$SANDBOX/restore.log")"
}

test_dry_run_warns_about_missing_imports() {
    seed_imports
    write_config '.'
    run_backup
    wipe_home
    bash "$RESTORE_SH" "$BACKUP_REPO" --dry-run > "$SANDBOX/dry.log" 2>&1 \
        || fail "restore.sh --dry-run exited non-zero"
    assert_import_warnings "$(strip_color "$SANDBOX/dry.log")"
}

# restore_as <uname -s value> <restore.sh args...>: pretend to be another OS.
restore_as() {
    local os="$1" real_uname
    shift
    real_uname=$(command -v uname)
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/uname" <<STUB
#!/bin/bash
if [ "\$1" = "-s" ]; then echo "$os"; else exec "$real_uname" "\$@"; fi
STUB
    chmod +x "$SANDBOX/bin/uname"
    PATH="$SANDBOX/bin:$PATH" bash "$RESTORE_SH" "$BACKUP_REPO" "$@" > "$SANDBOX/restore.log" 2>&1
}

# Backs up the seeded project, then renames it in the backup as if made elsewhere.
make_backup_with_slug() {
    write_config '.'
    run_backup
    [ "$PROJECT_BACKUP" = "$BACKUP_REPO/projects/$1" ] || mv "$PROJECT_BACKUP" "$BACKUP_REPO/projects/$1"
    wipe_home
}

assert_no_match() {
    if grep -qE -- "$2" <<< "$1"; then
        fail "did not expect output matching: $2"
    fi
}

test_restore_warns_about_windows_backup_on_linux() {
    make_backup_with_slug "C--Users-me-proj"
    restore_as Linux --yes || fail "restore.sh exited non-zero"
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "WARNING.*made on Windows"
    assert_contains "$output" "1 of 1 project"
    assert_contains "$output" "--remap"
    assert_exists "$HOME/.claude/projects/C--Users-me-proj/memory/MEMORY.md"
}

test_restore_warns_about_linux_backup_on_windows() {
    make_backup_with_slug "-home-me-proj"
    restore_as MINGW64_NT-10.0 --yes || fail "restore.sh exited non-zero"
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "WARNING.*made on Linux or macOS"
    assert_contains "$output" "1 of 1 project"
}

test_restore_has_no_os_warning_on_same_os() {
    make_backup_with_slug "-home-me-proj"
    restore_as Linux --yes || fail "restore.sh exited non-zero"
    assert_no_match "$(strip_color "$SANDBOX/restore.log")" "WARNING.*made on"
}

test_remap_renames_matching_projects_only() {
    make_backup_with_slug "C--Users-me-proj"
    cp -r "$BACKUP_REPO/projects/C--Users-me-proj" "$BACKUP_REPO/projects/D--work-app"
    cp -r "$BACKUP_REPO/projects/C--Users-me-proj" "$BACKUP_REPO/projects/-opt-other"
    restore_as Linux --yes --remap C--Users-me=-home-me --remap=D--work=-srv \
        || fail "restore.sh exited non-zero"
    local projects="$HOME/.claude/projects"
    assert_exists "$projects/-home-me-proj/memory/MEMORY.md"
    assert_exists "$projects/-home-me-proj/sess-1.jsonl"
    assert_exists "$projects/-home-me-proj/sess-1/subagents/agent.jsonl"
    assert_exists "$projects/-srv-app/memory/MEMORY.md"
    assert_exists "$projects/-opt-other/memory/MEMORY.md"
    assert_missing "$projects/C--Users-me-proj"
    assert_missing "$projects/D--work-app"
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "WARNING.*made on Windows"
    assert_no_match "$output" "of 3 project"
}

test_remap_first_matching_rule_wins() {
    make_backup_with_slug "C--Users-me-proj"
    restore_as Linux --yes --remap C--Users=-first --remap C--Users-me=-second \
        || fail "restore.sh exited non-zero"
    assert_exists "$HOME/.claude/projects/-first-me-proj"
    assert_missing "$HOME/.claude/projects/-second-proj"
}

test_remap_dry_run_shows_rename_and_writes_nothing() {
    make_backup_with_slug "C--Users-me-proj"
    restore_as Linux --dry-run --remap C--Users-me=-home-me \
        || fail "restore.sh exited non-zero"
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "C--Users-me-proj -> -home-me-proj"
    assert_contains "$output" "NEW.*/projects/-home-me-proj/memory/MEMORY\.md"
    assert_missing "$HOME/.claude/projects"
}

test_remap_rejects_bad_values() {
    make_backup_with_slug "C--Users-me-proj"
    local value
    for value in "no-equals" "=to" "from=" "C:/Users/me=/home/me" "from=.." 'a\b=c'; do
        if restore_as Linux --yes --remap "$value"; then
            fail "accepted bad value: $value"
        fi
    done
    if restore_as Linux --yes --remap; then
        fail "accepted --remap with no value"
    fi
    assert_missing "$HOME/.claude"
}

test_remap_collision_stops_before_writing() {
    make_backup_with_slug "C--Users-me-proj"
    cp -r "$BACKUP_REPO/projects/C--Users-me-proj" "$BACKUP_REPO/projects/-home-me-proj"
    if restore_as Linux --yes --remap C--Users-me=-home-me; then
        fail "restore continued despite two projects sharing a destination"
    fi
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "-home-me-proj"
    assert_missing "$HOME/.claude"
}

test_remap_warns_when_rule_matches_nothing() {
    make_backup_with_slug "C--Users-me-proj"
    restore_as Linux --yes --remap C--Users-typo=-home-me \
        || fail "restore.sh exited non-zero"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "WARNING.*C--Users-typo.*matched no"
}

# ─── Execute bits (issue #30) ──────────────────────────────────────

# Backs up scripts that have no execute bit, as a Windows-made backup would hold them.
make_backup_with_scripts() {
    echo 'echo hi' > "$HOME/.claude/skills/pkg/run.sh"
    printf '#!/bin/sh\necho hi\n' > "$HOME/.claude/skills/pkg/tool"
    echo 'plain' > "$HOME/.claude/skills/pkg/notes.txt"
    echo 'print(1)' > "$HOME/.claude/hooks/check.py"
    echo 'echo hi' > "$HOME/.claude/helper.sh"
    echo 'echo hi' > "$HOME/.claude/agents/not-in-scope.sh"
    write_config '.'
    run_backup
    wipe_home
}

assert_executable() { [ -x "$1" ] || fail "expected executable: ${1#"$SANDBOX"/}"; }
assert_not_executable() { [ ! -x "$1" ] || fail "expected not executable: ${1#"$SANDBOX"/}"; }

test_restore_marks_scripts_executable() {
    make_backup_with_scripts
    restore_as Linux --yes || fail "restore.sh exited non-zero"
    assert_executable "$HOME/.claude/skills/pkg/run.sh"
    assert_executable "$HOME/.claude/skills/pkg/tool"
    assert_executable "$HOME/.claude/hooks/check.py"
    assert_executable "$HOME/.claude/helper.sh"
    assert_not_executable "$HOME/.claude/skills/pkg/notes.txt"
    assert_not_executable "$HOME/.claude/agents/not-in-scope.sh"
    assert_not_executable "$HOME/.claude/CLAUDE.md"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "4 script\(s\) marked executable"
}

test_restore_fixes_execute_bit_on_identical_file() {
    make_backup_with_scripts
    restore_as Linux --yes || fail "restore.sh exited non-zero"
    chmod -x "$HOME/.claude/skills/pkg/run.sh"
    restore_as Linux --yes || fail "restore.sh exited non-zero"
    assert_executable "$HOME/.claude/skills/pkg/run.sh"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "1 script\(s\) marked executable"
    [ "$(count_timestamp_copies)" -eq 0 ] || fail "made a copy of an identical file"
}

test_dry_run_counts_scripts_and_changes_nothing() {
    make_backup_with_scripts
    restore_as Linux --yes || fail "restore.sh exited non-zero"
    chmod -x "$HOME/.claude/skills/pkg/run.sh"
    restore_as Linux --dry-run || fail "restore.sh exited non-zero"
    assert_not_executable "$HOME/.claude/skills/pkg/run.sh"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "1 script\(s\) would be marked executable"
}

test_scripts_already_executable_in_backup_are_not_counted() {
    make_backup_with_scripts
    chmod +x "$BACKUP_REPO/skills/pkg/run.sh"
    restore_as Linux --yes || fail "restore.sh exited non-zero"
    assert_executable "$HOME/.claude/skills/pkg/run.sh"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "3 script\(s\) marked executable"
}

test_windows_restore_does_not_touch_execute_bits() {
    make_backup_with_scripts
    restore_as MINGW64_NT-10.0 --yes || fail "restore.sh exited non-zero"
    assert_not_executable "$HOME/.claude/skills/pkg/run.sh"
    assert_no_match "$(strip_color "$SANDBOX/restore.log")" "marked executable"
}

# ─── Windows path limits (issue #31) ───────────────────────────────

# Prints a project folder name that makes its restored path exactly <length> long.
slug_for_length() {
    local prefix="$HOME/.claude/projects/C--"
    printf 'C--%*s\n' "$(($1 - ${#prefix}))" '' | tr ' ' x
}

# Makes cp and mkdir fail the way Windows does past its limits.
stub_windows_path_limits() {
    local real_cp real_mkdir
    real_cp=$(command -v cp)
    real_mkdir=$(command -v mkdir)
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/cp" <<STUB
#!/bin/bash
target="\${@: -1}"
if [ "\${#target}" -gt 259 ]; then echo "cp: File name too long" >&2; exit 1; fi
exec "$real_cp" "\$@"
STUB
    cat > "$SANDBOX/bin/mkdir" <<STUB
#!/bin/bash
target="\${@: -1}"
if [ "\${#target}" -gt 247 ]; then echo "mkdir: File name too long" >&2; exit 1; fi
exec "$real_mkdir" "\$@"
STUB
    chmod +x "$SANDBOX/bin/cp" "$SANDBOX/bin/mkdir"
}

test_windows_long_paths_warn_and_restore_continues() {
    local slug
    slug=$(slug_for_length 245)
    make_backup_with_slug "$slug"
    stub_windows_path_limits
    restore_as MINGW64_NT-10.0 --yes || fail "restore stopped at an over-long path: $(tail -n 3 "$SANDBOX/restore.log")"
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "WARNING.*too long.*MEMORY.md"
    assert_contains "$output" "4 file\(s\) could not be restored"
    assert_no_match "$output" "cp: File name too long"
    assert_exists "$HOME/.claude/projects/$slug/sess-1.jsonl"
    assert_missing "$HOME/.claude/projects/$slug/memory/MEMORY.md"
    assert_exists "$HOME/.claude/skills/pkg/SKILL.md"
    assert_exists "$HOME/.claude/todos/todo.json"
}

test_windows_directory_limit_counts_as_too_long() {
    local slug
    slug=$(slug_for_length 241)
    make_backup_with_slug "$slug"
    stub_windows_path_limits
    restore_as MINGW64_NT-10.0 --yes || fail "restore stopped at an over-long folder: $(tail -n 3 "$SANDBOX/restore.log")"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "WARNING.*too long.*MEMORY.md"
}

test_windows_long_path_is_kept_when_copy_succeeds() {
    local slug
    slug=$(slug_for_length 245)
    make_backup_with_slug "$slug"
    restore_as MINGW64_NT-10.0 --yes || fail "restore.sh exited non-zero"
    assert_exists "$HOME/.claude/projects/$slug/memory/MEMORY.md"
    assert_no_match "$(strip_color "$SANDBOX/restore.log")" "too long|could not be restored"
}

test_windows_dry_run_reports_long_paths_and_writes_nothing() {
    make_backup_with_slug "$(slug_for_length 245)"
    restore_as MINGW64_NT-10.0 --dry-run || fail "restore.sh exited non-zero"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "4 file\(s\) .*Windows path limit"
    assert_missing "$HOME/.claude"
}

test_long_paths_are_not_flagged_on_linux() {
    make_backup_with_slug "$(slug_for_length 245)"
    restore_as Linux --dry-run || fail "restore.sh exited non-zero"
    assert_no_match "$(strip_color "$SANDBOX/restore.log")" "Windows path limit"
}

# ─── MCP merge (issue #23) ─────────────────────────────────────────

# edit_json <file> <jq expression>: rewrite a JSON file in place.
edit_json() {
    jq "$2" "$1" > "$SANDBOX/edit.json" && mv "$SANDBOX/edit.json" "$1"
}

# Backup holds myserver (changed) and newserver; this machine has its own login and
# a server of its own.
make_mcp_backup() {
    write_config '.'
    run_backup
    edit_json "$BACKUP_REPO/global/claude.json" '
        .mcpServers.myserver.command = "/new/bin/srv"
        | .mcpServers.myserver.env = {"API_KEY": "backup-token"}
        | .mcpServers.newserver = {"type": "http", "url": "https://mcp.example.invalid"}'
    cat > "$HOME/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"local-login@example.invalid"},
 "projects":{"/home/me/proj":{"hasTrustDialogAccepted":true}},
 "mcpServers":{"myserver":{"command":"/old/bin/srv","env":{"API_KEY":"local-token"}},
   "localonly":{"command":"local-srv"}}}
JSON
}

test_mcp_merge_keeps_login_and_local_env() {
    make_mcp_backup
    restore_as Linux --yes --only mcp || fail "restore.sh exited non-zero"
    local f="$HOME/.claude.json"
    [ "$(jq -r '.oauthAccount.emailAddress' "$f")" = "local-login@example.invalid" ] || fail "login replaced"
    [ "$(jq -r '.projects | keys[0]' "$f")" = "/home/me/proj" ] || fail "projects map replaced"
    [ "$(jq -r '.mcpServers.myserver.command' "$f")" = "/new/bin/srv" ] || fail "server command not taken from backup"
    [ "$(jq -r '.mcpServers.myserver.env.API_KEY' "$f")" = "local-token" ] || fail "local env replaced"
    [ "$(jq -r '.mcpServers.newserver.url' "$f")" = "https://mcp.example.invalid" ] || fail "new server not added"
    [ "$(jq -r '.mcpServers.localonly.command' "$f")" = "local-srv" ] || fail "local-only server removed"
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "Added: newserver"
    assert_contains "$output" "Updated: myserver"
    assert_no_match "$output" "overwrites OAuth|re-authenticate"
    [ "$(count_timestamp_copies)" -eq 1 ] || fail "expected one copy of the old ~/.claude.json"
}

test_mcp_merge_twice_leaves_file_alone() {
    make_mcp_backup
    restore_as Linux --yes --only mcp || fail "restore.sh exited non-zero"
    restore_as Linux --yes --only mcp || fail "restore.sh exited non-zero"
    [ "$(count_timestamp_copies)" -eq 1 ] || fail "second merge made another copy"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "1 file\(s\) already identical"
}

test_mcp_merge_onto_bare_machine_writes_only_servers() {
    make_mcp_backup
    rm "$HOME/.claude.json"
    restore_as Linux --yes --only mcp || fail "restore.sh exited non-zero"
    [ "$(jq -c 'keys' "$HOME/.claude.json")" = '["mcpServers"]' ] || fail "wrote more than mcpServers: $(jq -c 'keys' "$HOME/.claude.json")"
    [ "$(jq -r '.mcpServers.myserver.env.API_KEY' "$HOME/.claude.json")" = "backup-token" ] || fail "backup env not used"
}

test_mcp_replace_restores_whole_file() {
    make_mcp_backup
    restore_as Linux --yes --only mcp --mcp-replace || fail "restore.sh exited non-zero"
    cmp -s "$BACKUP_REPO/global/claude.json" "$HOME/.claude.json" || fail "file not replaced whole"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "overwrites OAuth"
}

test_mcp_merge_dry_run_reports_and_writes_nothing() {
    make_mcp_backup
    cp "$HOME/.claude.json" "$SANDBOX/before.json"
    restore_as Linux --dry-run --only mcp || fail "restore.sh exited non-zero"
    cmp -s "$SANDBOX/before.json" "$HOME/.claude.json" || fail "dry run changed ~/.claude.json"
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "CHANGED.*\.claude\.json"
    assert_contains "$output" "Added: newserver"
    assert_no_match "$output" "OAuth"
}

test_mcp_merge_skips_unreadable_local_file() {
    make_mcp_backup
    echo '{ not json' > "$HOME/.claude.json"
    restore_as Linux --yes || fail "restore.sh exited non-zero"
    [ "$(cat "$HOME/.claude.json")" = '{ not json' ] || fail "unreadable file was changed"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "WARNING.*\.claude\.json.*--mcp-replace"
    assert_exists "$HOME/.claude/skills/pkg/SKILL.md"
}

# ─── settings.json merge with OS filtering (issue #29) ─────────────

# Backup made on Windows; settings carry Windows-only entries.
make_windows_settings_backup() {
    write_config '.'
    run_backup
    edit_json "$BACKUP_REPO/backup-manifest.json" '.os = "MINGW64_NT-10.0-26100"'
    cat > "$BACKUP_REPO/global/settings.json" <<'JSON'
{"theme":"dark","model":"backup-model",
 "permissions":{"allow":["Bash(git status:*)","Bash(powershell.exe:*)","Read(C:\\Users\\me\\notes)"],
   "deny":["Bash(rm -rf /:*)"]},
 "env":{"KEEP_ME":"1","CLAUDE_CODE_PLUGIN_DIRS":"C:\\a\\plugins;D:\\b"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"pwsh -File check.ps1"}]},
   {"matcher":"Edit","hooks":[{"type":"command","command":"echo ok"}]}]},
 "statusLine":{"type":"command","command":"powershell.exe -File status.ps1"},
 "mcpServers":{"winsrv":{"command":"npx","args":["-y","srv","C:/Users/me/data"]},"portable":{"command":"npx","args":["-y","srv"]}}}
JSON
}

test_settings_merge_unions_permissions_and_keeps_local_choices() {
    write_config '.'
    run_backup
    cat > "$BACKUP_REPO/global/settings.json" <<'JSON'
{"theme":"dark","model":"backup-model","permissions":{"allow":["Bash(git status:*)","Bash(ls:*)"]},
 "env":{"SHARED":"backup"},"hooks":{"Stop":[]}}
JSON
    cat > "$HOME/.claude/settings.json" <<'JSON'
{"theme":"light","model":"local-model","localOnly":true,"permissions":{"allow":["Bash(ls:*)","Bash(make:*)"]},
 "env":{"SHARED":"local","LOCAL":"1"},"statusLine":{"type":"command","command":"local-status"},
 "hooks":{"PreToolUse":[]}}
JSON
    restore_as Linux --yes --only global || fail "restore.sh exited non-zero"
    local f="$HOME/.claude/settings.json"
    [ "$(jq -c '.permissions.allow' "$f")" = '["Bash(ls:*)","Bash(make:*)","Bash(git status:*)"]' ] \
        || fail "allow lists not unioned: $(jq -c '.permissions.allow' "$f")"
    [ "$(jq -r '.theme' "$f")" = "dark" ] || fail "backup value did not win for theme"
    [ "$(jq -r '.model' "$f")" = "local-model" ] || fail "local model replaced"
    [ "$(jq -r '.statusLine.command' "$f")" = "local-status" ] || fail "local statusLine replaced"
    [ "$(jq -c '.hooks' "$f")" = '{"PreToolUse":[]}' ] || fail "local hooks replaced"
    [ "$(jq -c '.env' "$f")" = '{"SHARED":"backup","LOCAL":"1"}' ] || fail "env not merged per key"
    [ "$(jq -r '.localOnly' "$f")" = "true" ] || fail "local-only key removed"
}

test_settings_from_windows_drops_windows_entries_on_linux() {
    make_windows_settings_backup
    rm "$HOME/.claude/settings.json"
    restore_as Linux --yes --only global || fail "restore.sh exited non-zero"
    local f="$HOME/.claude/settings.json"
    [ "$(jq -c '.permissions.allow' "$f")" = '["Bash(git status:*)"]' ] || fail "allow not filtered: $(jq -c '.permissions.allow' "$f")"
    [ "$(jq -c '.env' "$f")" = '{"KEEP_ME":"1"}' ] || fail "env not filtered: $(jq -c '.env' "$f")"
    [ "$(jq -c '.hooks.PreToolUse | map(.matcher)' "$f")" = '["Edit"]' ] || fail "hooks not filtered"
    [ "$(jq -r 'has("statusLine")' "$f")" = "false" ] || fail "Windows statusLine kept"
    [ "$(jq -r '.theme' "$f")" = "dark" ] || fail "portable setting lost"
    [ "$(jq -c '.mcpServers | keys' "$f")" = '["portable"]' ] || fail "server with a Windows path not dropped whole: $(jq -c '.mcpServers' "$f")"
    local output
    output=$(strip_color "$SANDBOX/restore.log")
    assert_contains "$output" "Dropped .*permissions\.allow.*powershell\.exe"
    assert_contains "$output" "Dropped .*CLAUDE_CODE_PLUGIN_DIRS"
    assert_contains "$output" "Dropped .*statusLine"
    assert_contains "$output" "Dropped .*check\.ps1"
}

test_settings_same_os_is_not_filtered() {
    make_windows_settings_backup
    edit_json "$BACKUP_REPO/backup-manifest.json" '.os = "Linux"'
    rm "$HOME/.claude/settings.json"
    restore_as Linux --yes --only global || fail "restore.sh exited non-zero"
    cmp -s "$BACKUP_REPO/global/settings.json" "$HOME/.claude/settings.json" || fail "same-OS settings were altered"
    assert_no_match "$(strip_color "$SANDBOX/restore.log")" "Dropped"
}

test_settings_from_linux_drops_home_paths_on_windows() {
    write_config '.'
    run_backup
    echo '{"permissions":{"allow":["Read(/home/me/notes)","Read(C:/Users/me/x)","Bash(ls:*)"]}}' \
        > "$BACKUP_REPO/global/settings.json"
    rm "$HOME/.claude/settings.json"
    restore_as MINGW64_NT-10.0 --yes --only global || fail "restore.sh exited non-zero"
    [ "$(jq -c '.permissions.allow' "$HOME/.claude/settings.json")" = '["Read(C:/Users/me/x)","Bash(ls:*)"]' ] \
        || fail "not filtered for Windows: $(jq -c '.permissions.allow' "$HOME/.claude/settings.json")"
}

test_settings_os_comes_from_project_names_without_manifest() {
    make_windows_settings_backup
    rm "$BACKUP_REPO/backup-manifest.json"
    mv "$PROJECT_BACKUP" "$BACKUP_REPO/projects/C--Users-me-proj"
    rm "$HOME/.claude/settings.json"
    restore_as Linux --yes --only global || fail "restore.sh exited non-zero"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "Dropped .*powershell\.exe"
}

test_settings_replace_copies_whole_file() {
    make_windows_settings_backup
    restore_as Linux --yes --only global --settings-replace || fail "restore.sh exited non-zero"
    cmp -s "$BACKUP_REPO/global/settings.json" "$HOME/.claude/settings.json" || fail "file not replaced whole"
    assert_no_match "$(strip_color "$SANDBOX/restore.log")" "Dropped"
}

test_settings_dry_run_lists_drops_and_writes_nothing() {
    make_windows_settings_backup
    cp "$HOME/.claude/settings.json" "$SANDBOX/before.json"
    restore_as Linux --dry-run --only global || fail "restore.sh exited non-zero"
    cmp -s "$SANDBOX/before.json" "$HOME/.claude/settings.json" || fail "dry run changed settings.json"
    assert_contains "$(strip_color "$SANDBOX/restore.log")" "Dropped .*powershell\.exe"
}

# ─── Shared-config sync (issue #32) ────────────────────────────────

SYNC_SH="$REPO_ROOT/scripts/sync/sync-claude-config.sh"
CHECK_RUN_SH="$REPO_ROOT/scripts/sync/config-check-run.sh"

make_shared() {
    SHARED="$SANDBOX/shared"
    mkdir -p "$SHARED/skills/shared-skill"
    echo '# shared prefs' > "$SHARED/GLOBAL-PREFS.md"
    echo 'shared skill' > "$SHARED/skills/shared-skill/SKILL.md"
    cat > "$SHARED/settings.shared.json" <<'JSON'
{"alwaysThinkingEnabled":true,
 "permissions":{"allow":["Bash(git status:*)"],"deny":["Bash(rm -rf /:*)"]},
 "retiredAllows":["Bash(old-tool:*)"],
 "env":{"SHARED_VAR":"1"},
 "statusLine":{"type":"command","command":"shared-status"}}
JSON
    echo '{"mcpServers":{"myserver":{"type":"stdio","command":"npx","args":["-y","pkg"]}}}' > "$SHARED/mcp.shared.json"
    cat > "$HOME/.claude/settings.json" <<'JSON'
{"model":"local-model","permissions":{"allow":["Bash(make:*)","Bash(old-tool:*)"]},
 "env":{"LOCAL_VAR":"1"},"statusLine":{"type":"command","command":"local-status"}}
JSON
}

# sync_as <uname -s value> <sync-claude-config.sh args...>
sync_as() {
    local os="$1" real_uname
    shift
    real_uname=$(command -v uname)
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/uname" <<STUB
#!/bin/bash
if [ "\$1" = "-s" ]; then echo "$os"; else exec "$real_uname" "\$@"; fi
STUB
    chmod +x "$SANDBOX/bin/uname"
    PATH="$SANDBOX/bin:$PATH" bash "$SYNC_SH" "$@" > "$SANDBOX/sync.log" 2>&1
}

home_snapshot() { (cd "$HOME" && find . -type f -exec md5sum {} + | sort); }

test_sync_apply_merges_shared_layer() {
    make_shared
    sync_as Linux "$SHARED" || fail "sync exited non-zero: $(tail -n 3 "$SANDBOX/sync.log")"
    grep -qxF "@$SHARED/GLOBAL-PREFS.md" "$HOME/.claude/CLAUDE.md" || fail "import line missing"
    local f="$HOME/.claude/settings.json"
    [ "$(jq -c '.permissions.allow' "$f")" = '["Bash(git status:*)","Bash(make:*)"]' ] \
        || fail "allow not merged: $(jq -c '.permissions.allow' "$f")"
    [ "$(jq -c '.env' "$f")" = '{"LOCAL_VAR":"1","SHARED_VAR":"1"}' ] || fail "env not merged: $(jq -c '.env' "$f")"
    [ "$(jq -r '.statusLine.command' "$f")" = "local-status" ] || fail "local statusLine replaced"
    [ "$(jq -r '.model' "$f")" = "local-model" ] || fail "local model replaced"
    [ "$(jq -r 'has("autoMode")' "$f")" = "false" ] || fail "wrote autoMode the shared layer does not have"
    assert_exists "$HOME/.claude/skills/shared-skill/SKILL.md"
    assert_exists "$HOME/.claude/skills/pkg/SKILL.md"
    assert_contains "$(cat "$SANDBOX/sync.log")" "skills/pkg: untracked"
    [ "$(jq -r '.mcpServers.myserver.env.API_KEY' "$HOME/.claude.json")" = "secret-token-value" ] \
        || fail "local MCP env not kept"
    [ "$(jq -r '.mcpServers.myserver.command' "$HOME/.claude.json")" = "npx" ] || fail "shared MCP definition not applied"
    [ "$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json")" = "secret-account@example.invalid" ] \
        || fail "rest of ~/.claude.json changed"
    sync_as Linux --check "$SHARED" || fail "--check reported drift right after apply: $(tail -n 5 "$SANDBOX/sync.log")"
    assert_contains "$(cat "$SANDBOX/sync.log")" "shared Claude config in sync"
}

test_sync_check_reports_drift_and_writes_nothing() {
    make_shared
    local before
    before=$(home_snapshot)
    if sync_as Linux --check "$SHARED"; then
        fail "--check exited 0 despite drift"
    fi
    [ "$before" = "$(home_snapshot)" ] || fail "--check changed files"
    assert_contains "$(cat "$SANDBOX/sync.log")" "out of sync"
}

test_sync_dry_run_on_bare_machine_writes_nothing() {
    make_shared
    rm "$HOME/.claude/settings.json" "$HOME/.claude.json"
    local before
    before=$(home_snapshot)
    sync_as Linux --dry-run "$SHARED" || fail "dry run exited non-zero: $(tail -n 3 "$SANDBOX/sync.log")"
    [ "$before" = "$(home_snapshot)" ] || fail "dry run wrote files"
    assert_missing "$HOME/.claude/settings.json"
    assert_missing "$HOME/.claude.json"
    assert_contains "$(cat "$SANDBOX/sync.log")" "mcp/myserver: MISSING"
}

test_sync_apply_on_bare_machine_creates_files() {
    make_shared
    rm "$HOME/.claude/settings.json" "$HOME/.claude.json"
    sync_as Linux "$SHARED" || fail "sync exited non-zero: $(tail -n 3 "$SANDBOX/sync.log")"
    [ "$(jq -r '.statusLine.command' "$HOME/.claude/settings.json")" = "shared-status" ] || fail "shared statusLine not set"
    [ "$(jq -c '.mcpServers | keys' "$HOME/.claude.json")" = '["myserver"]' ] || fail "MCP server not added"
}

test_sync_takes_shared_dir_from_environment() {
    make_shared
    CLAUDE_SHARED_DIR="$SHARED" sync_as Linux --dry-run || fail "CLAUDE_SHARED_DIR not used: $(tail -n 3 "$SANDBOX/sync.log")"
    local rc=0
    sync_as Linux --dry-run || rc=$?
    [ "$rc" -eq 2 ] || fail "expected exit 2 with no shared dir, got $rc"
    assert_contains "$(cat "$SANDBOX/sync.log")" "usage"
}

test_sync_on_windows_wraps_npx_and_uses_semicolons() {
    make_shared
    mkdir -p "$SHARED/mods/one" "$SHARED/mods/two"
    sync_as MINGW64_NT-10.0 "$SHARED" || fail "sync exited non-zero: $(tail -n 3 "$SANDBOX/sync.log")"
    [ "$(jq -c '[.mcpServers.myserver.command, .mcpServers.myserver.args]' "$HOME/.claude.json")" = '["cmd",["/c","npx","-y","pkg"]]' ] \
        || fail "npx not wrapped: $(jq -c '.mcpServers.myserver' "$HOME/.claude.json")"
    [ "$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS' "$HOME/.claude/settings.json")" = "~/.claude/mods/one;~/.claude/mods/two" ] \
        || fail "plugin dirs: $(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS' "$HOME/.claude/settings.json")"
}

test_config_check_runner_logs_and_exits_with_check_status() {
    make_shared
    export CLAUDE_CHECK_LOG_DIR="$SANDBOX/logs"
    if bash "$CHECK_RUN_SH" "$SHARED"; then
        fail "runner exited 0 despite drift"
    fi
    assert_contains "$(cat "$SANDBOX"/logs/check-*.log)" "=== run finished rc=1 at "
    sync_as Linux "$SHARED" || fail "sync exited non-zero"
    bash "$CHECK_RUN_SH" "$SHARED" || fail "runner exited non-zero when in sync"
    assert_contains "$(tail -n 1 "$SANDBOX"/logs/check-*.log)" "=== run finished rc=0 at "
    unset CLAUDE_CHECK_LOG_DIR
}

echo "Running tests"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
