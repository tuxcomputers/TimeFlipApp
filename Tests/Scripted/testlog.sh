#!/bin/bash
# The durable record of every scripted run: `logs/testlog.sqlite`.
#
#   Tests/Scripted/testlog.sh              a report on the last few runs and what is failing
#   Tests/Scripted/testlog.sh 12           the same, over the last 12 runs
#
# Sourced by `lib.sh`, which records into it as checks happen. Run directly, it reports.
#
# **Why this exists rather than just `logs/screen.txt`.** screen.txt is one run, overwritten by the next,
# and it holds only what was printed. Two things are missing from it, and both are what a failure actually
# needs:
#
#   1. **The app's own `debug_log` rows, which the next run destroys.** They live in `test.sqlite`, and a
#      clean run rebuilds that file from the DDL. So the evidence behind this morning's failure is gone by
#      the time anybody sits down to read about it. They are copied in here as each script ends.
#   2. **Every other run.** "Has this ever passed?", "when did it start failing?", "does it fail one run in
#      four?" are the questions that decide whether a red check is a bug or a flaky script, and none of them
#      can be asked of a single file that was overwritten.
#
# **Nothing here may fail a run.** Every write is best-effort: a broken or locked log database must not turn
# a passing run red, because this file is a record of the tests and not one of them. That is why every
# statement ends `2>/dev/null || true`.
#
# **The design is for reading failures, not for storing output.** Checks carry a `check_key` -- the
# description with every run of digits replaced by `#` -- so the same check is one row across runs even
# though its text carries a clock-stamped category name and a fresh row id every time. Without that,
# comparing runs is impossible and this is just screen.txt with extra steps.

TESTLOG="${TESTLOG:-logs/testlog.sqlite}"

# Escapes a value for a single-quoted SQL literal.
sq() { printf '%s' "${1:-}" | sed "s/'/''/g"; }

# Runs a statement against the log, swallowing everything. See the note above about never failing a run.
tlog() { sqlite3 "$TESTLOG" "$1" 2>/dev/null || true; }

testlog_open() {
    mkdir -p "$(dirname "$TESTLOG")" 2>/dev/null || true
    # **Output discarded, not just errors.** `PRAGMA journal_mode` answers `wal` on stdout, and this runs
    # inside `testlog_run_start`, whose stdout *is* the new run's id. Letting it through put the word `wal`
    # in front of every id and broke every write after it.
    sqlite3 "$TESTLOG" >/dev/null 2>&1 <<'SQL' || true
PRAGMA journal_mode = WAL;

-- One row per invocation of run.sh, or per script run on its own.
CREATE TABLE IF NOT EXISTS run (
    run_id          INTEGER PRIMARY KEY,
    started_at      TEXT    NOT NULL,
    started_epoch   INTEGER NOT NULL,
    finished_at     TEXT,
    finished_epoch  INTEGER,
    branch          TEXT,
    commit_sha      TEXT,
    -- Whether the working tree had uncommitted changes. A failure against a dirty tree is not evidence
    -- about the commit it names.
    dirty           INTEGER,
    database_file   TEXT,
    -- 0 for --keep. A check that only passes on a kept database has not been proven from nothing.
    rebuilt         INTEGER,
    filter          TEXT,
    binary_built_at TEXT,
    signing         TEXT,
    os_version      TEXT,
    invocation      TEXT,
    outcome         TEXT,
    scripts_run     INTEGER,
    passed          INTEGER DEFAULT 0,
    failed          INTEGER DEFAULT 0,
    skipped         INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS script (
    script_id       INTEGER PRIMARY KEY,
    run_id          INTEGER NOT NULL REFERENCES run(run_id),
    name            TEXT    NOT NULL,
    subject         TEXT,
    sequence        INTEGER NOT NULL,
    started_epoch   INTEGER,
    finished_epoch  INTEGER,
    passed          INTEGER DEFAULT 0,
    failed          INTEGER DEFAULT 0,
    skipped         INTEGER DEFAULT 0,
    -- The app's debug_log high-water mark when this script started, so its rows can be sliced out.
    log_from        INTEGER
);

CREATE TABLE IF NOT EXISTS check_result (
    check_id      INTEGER PRIMARY KEY,
    script_id     INTEGER NOT NULL REFERENCES script(script_id),
    sequence      INTEGER NOT NULL,
    description   TEXT    NOT NULL,
    -- The description with digits normalised to `#`, so one check is one key across runs. This is what
    -- makes every cross-run question below answerable.
    check_key     TEXT    NOT NULL,
    verdict       TEXT    NOT NULL CHECK (verdict IN ('pass', 'fail', 'skip')),
    detail        TEXT,
    expected      TEXT,
    actual        TEXT,
    started_epoch INTEGER,
    seconds       INTEGER,
    -- The app's debug_log id when this check began. With the next check's, it brackets exactly the rows
    -- this check produced.
    log_from      INTEGER
);

-- Captured only when a check fails, because it costs a second and is worthless when nothing is wrong.
CREATE TABLE IF NOT EXISTS evidence (
    evidence_id INTEGER PRIMARY KEY,
    check_id    INTEGER NOT NULL REFERENCES check_result(check_id),
    kind        TEXT    NOT NULL,
    body        TEXT    NOT NULL
);

-- The app's own log, copied because test.sqlite is rebuilt by the next clean run and takes it away.
CREATE TABLE IF NOT EXISTS app_log (
    app_log_id   INTEGER PRIMARY KEY,
    run_id       INTEGER NOT NULL REFERENCES run(run_id),
    script_id    INTEGER REFERENCES script(script_id),
    debug_log_id INTEGER NOT NULL,
    logged_at    TEXT,
    tag          TEXT,
    message      TEXT
);

-- Lets the copy run twice over the same window without duplicating: once when a check fails (in case the
-- script dies before it ends) and once when it ends.
CREATE UNIQUE INDEX IF NOT EXISTS UN1_app_log ON app_log (run_id, debug_log_id);
CREATE INDEX IF NOT EXISTS IX1_check_key ON check_result (check_key);
CREATE INDEX IF NOT EXISTS IX2_check_script ON check_result (script_id);

-- ---------------------------------------------------------------------------- views, for reading it

-- Every failure with the context needed to place it: which run, which branch, what was expected.
CREATE VIEW IF NOT EXISTS v_failure AS
SELECT r.run_id, r.started_at, r.branch, s.name AS script, c.check_id,
       c.description, c.detail, c.expected, c.actual, c.check_key
  FROM check_result c
  JOIN script s ON s.script_id = c.script_id
  JOIN run r ON r.run_id = s.run_id
 WHERE c.verdict = 'fail'
 ORDER BY r.run_id DESC, s.sequence, c.sequence;

-- One row per check, across every run it has appeared in. The first question about a red check is
-- always "has it ever been green?".
CREATE VIEW IF NOT EXISTS v_check_history AS
SELECT c.check_key,
       COUNT(*)                                        AS runs,
       SUM(c.verdict = 'pass')                         AS passed,
       SUM(c.verdict = 'fail')                         AS failed,
       SUM(c.verdict = 'skip')                         AS skipped,
       MAX(s.run_id)                                   AS last_run,
       MAX(CASE WHEN c.verdict = 'pass' THEN s.run_id END) AS last_passed,
       MAX(CASE WHEN c.verdict = 'fail' THEN s.run_id END) AS last_failed
  FROM check_result c
  JOIN script s ON s.script_id = c.script_id
 GROUP BY c.check_key;

-- Checks that have both passed and failed. A check that has never passed is probably wrong; one that
-- passes sometimes is probably a race, and they want different fixes.
CREATE VIEW IF NOT EXISTS v_flaky AS
SELECT * FROM v_check_history WHERE passed > 0 AND failed > 0 ORDER BY failed DESC;

-- Never green anywhere. Usually a check written against behaviour the app does not have.
CREATE VIEW IF NOT EXISTS v_never_passed AS
SELECT * FROM v_check_history WHERE passed = 0 AND failed > 0 ORDER BY failed DESC;

-- Where the time goes. A check that suddenly takes 45 seconds is usually one that is timing out and
-- being rescued by a fallback rather than one that got slow.
CREATE VIEW IF NOT EXISTS v_slow AS
SELECT c.check_key, COUNT(*) AS runs, MAX(c.seconds) AS worst, AVG(c.seconds) AS average
  FROM check_result c
 WHERE c.seconds IS NOT NULL
 GROUP BY c.check_key
 HAVING worst >= 5
 ORDER BY worst DESC;

CREATE VIEW IF NOT EXISTS v_run AS
SELECT run_id, started_at, branch, commit_sha, dirty, rebuilt, signing, binary_built_at,
       database_file, os_version, outcome, scripts_run, passed, failed, skipped,
       finished_epoch - started_epoch AS seconds
  FROM run
 ORDER BY run_id DESC;
SQL
}

# ---------------------------------------------------------------------------- writing

# Starts a run row and prints its id. Called by run.sh, and by lib.sh when a script is run on its own.
testlog_run_start() {
    local rebuilt="${1:-1}" filter="${2:-}" invocation="${3:-}"
    testlog_open

    local branch commit dirty target built signing os
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    # The full hash, not the short one: `last-run.md` is checked against the branch's history, and an
    # abbreviation can stop being unique as a repository grows.
    commit=$(git rev-parse HEAD 2>/dev/null || echo "")
    dirty=$([ -n "$(git status --porcelain 2>/dev/null)" ] && echo 1 || echo 0)
    target=$(readlink "$HOME/Library/Application Support/Facet/appdata.sqlite" 2>/dev/null || echo "")
    built=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' ".build/bundler/apps/Facet/Facet.app/Contents/MacOS/Facet" 2>/dev/null || echo "")
    # Ad-hoc matters: it silently breaks anything that reads the Keychain, which is how a Google failure
    # once looked like a Google failure and was actually a build flag.
    if codesign -dvvv ".build/bundler/apps/Facet/Facet.app" 2>&1 | grep -q "TeamIdentifier=[A-Z0-9]"; then
        signing="signed"
    else
        signing="ad-hoc"
    fi
    os=$(sw_vers -productVersion 2>/dev/null || echo "")

    tlog "INSERT INTO run (started_at, started_epoch, branch, commit_sha, dirty, database_file, rebuilt,
                           filter, binary_built_at, signing, os_version, invocation, outcome)
          VALUES (datetime('now','localtime'), strftime('%s','now'), '$(sq "$branch")', '$(sq "$commit")',
                  $dirty, '$(sq "$target")', $rebuilt, '$(sq "$filter")', '$(sq "$built")',
                  '$signing', '$(sq "$os")', '$(sq "$invocation")', 'running');"
    tlog "SELECT MAX(run_id) FROM run;"
}

testlog_run_finish() {
    local run="${1:-}" outcome="${2:-}" ran="${3:-0}"
    [ -z "$run" ] && return 0
    tlog "UPDATE run
             SET finished_at = datetime('now','localtime'), finished_epoch = strftime('%s','now'),
                 outcome = '$(sq "$outcome")', scripts_run = $ran,
                 passed  = (SELECT IFNULL(SUM(passed), 0)  FROM script WHERE run_id = $run),
                 failed  = (SELECT IFNULL(SUM(failed), 0)  FROM script WHERE run_id = $run),
                 skipped = (SELECT IFNULL(SUM(skipped), 0) FROM script WHERE run_id = $run)
           WHERE run_id = $run;"
}

# Opens a script row. `lib.sh` calls this from `start`.
testlog_script_start() {
    local name="$1" subject="${2:-}" run="${TESTLOG_RUN_ID:-}"

    # Run on its own rather than through run.sh: it still gets a run row, marked as such, so a check
    # recorded outside a full run is never mistaken for one inside it.
    if [ -z "$run" ]; then
        run=$(testlog_run_start 0 "" "single script")
        export TESTLOG_RUN_ID="$run"
        TESTLOG_OWN_RUN=1
    fi
    [ -z "$run" ] && return 0

    local sequence
    sequence=$(tlog "SELECT IFNULL(MAX(sequence), 0) + 1 FROM script WHERE run_id = $run;")
    tlog "INSERT INTO script (run_id, name, subject, sequence, started_epoch, log_from)
          VALUES ($run, '$(sq "$name")', '$(sq "$subject")', ${sequence:-1}, strftime('%s','now'), $(app_log_mark));"
    TESTLOG_SCRIPT_ID=$(tlog "SELECT MAX(script_id) FROM script WHERE run_id = $run;")
    TESTLOG_CHECK_SEQ=0
}

# The app's debug_log high-water mark, or 0 when there is no database to ask.
app_log_mark() {
    local id
    id=$(sqlite3 "$DB" "SELECT IFNULL(MAX(debug_log_id), 0) FROM debug_log;" 2>/dev/null || echo 0)
    printf '%s' "${id:-0}"
}

# Copies the app's own log rows for this script's window. Safe to call twice: the unique index drops
# what is already there.
testlog_copy_app_log() {
    local run="${TESTLOG_RUN_ID:-}" script="${TESTLOG_SCRIPT_ID:-}"
    [ -z "$run" ] || [ -z "$script" ] && return 0
    local from
    from=$(tlog "SELECT IFNULL(log_from, 0) FROM script WHERE script_id = $script;")
    sqlite3 "$TESTLOG" "
        ATTACH DATABASE '$(sq "$DB")' AS app;
        INSERT OR IGNORE INTO app_log (run_id, script_id, debug_log_id, logged_at, tag, message)
        SELECT $run, $script, debug_log_id, logged_at, tag, message
          FROM app.debug_log WHERE debug_log_id > ${from:-0};
        DETACH DATABASE app;" 2>/dev/null || true
}

testlog_script_finish() {
    local passed="${1:-0}" failed="${2:-0}" skipped="${3:-0}"
    [ -z "${TESTLOG_SCRIPT_ID:-}" ] && return 0
    testlog_copy_app_log
    tlog "UPDATE script
             SET finished_epoch = strftime('%s','now'),
                 passed = $passed, failed = $failed, skipped = $skipped
           WHERE script_id = $TESTLOG_SCRIPT_ID;"

    # A script run on its own owns its run row, so it closes it too.
    if [ "${TESTLOG_OWN_RUN:-0}" = "1" ]; then
        testlog_run_finish "$TESTLOG_RUN_ID" "$([ "$failed" -eq 0 ] && echo passed || echo failed)" 1
    fi
}

# Records one check. `verdict` is pass, fail or skip.
testlog_check() {
    local verdict="$1" detail="${2:-}"
    [ -z "${TESTLOG_SCRIPT_ID:-}" ] && return 0
    TESTLOG_CHECK_SEQ=$((${TESTLOG_CHECK_SEQ:-0} + 1))

    # Digits to `#`, so a description carrying a clock-stamped name and a fresh row id is still the same
    # check as last run's. Everything cross-run in this file depends on it.
    local key seconds
    key=$(printf '%s' "$LAST" | sed 's/[0-9][0-9]*/#/g')
    seconds=$(( $(date +%s) - ${LAST_STARTED:-$(date +%s)} ))

    tlog "INSERT INTO check_result (script_id, sequence, description, check_key, verdict, detail,
                                    expected, actual, started_epoch, seconds, log_from)
          VALUES ($TESTLOG_SCRIPT_ID, $TESTLOG_CHECK_SEQ, '$(sq "$LAST")', '$(sq "$key")',
                  '$verdict', '$(sq "$detail")', '$(sq "${LAST_EXPECTED:-}")', '$(sq "${LAST_ACTUAL:-}")',
                  ${LAST_STARTED:-0}, $seconds, ${LAST_LOG_MARK:-0});"

    [ "$verdict" = "fail" ] && testlog_failure_evidence
    return 0
}

# What a failure needs and cannot be got back afterwards. Only on failure: the tree costs about a second,
# and the app is usually gone by the time anybody reads this.
testlog_failure_evidence() {
    local check
    check=$(tlog "SELECT MAX(check_id) FROM check_result WHERE script_id = $TESTLOG_SCRIPT_ID;")
    [ -z "$check" ] && return 0

    # First, so a script that dies immediately after still leaves the app's account of what happened.
    testlog_copy_app_log

    local dump
    dump=$(python3 scripts/ax-dump.py 2>&1 | head -400)
    [ -n "$dump" ] && tlog "INSERT INTO evidence (check_id, kind, body)
                            VALUES ($check, 'ax_tree', '$(sq "$dump")');"

    local sheet
    sheet=$(python3 scripts/ax-alert.py 2>&1 | head -20)
    # An alert nobody expected is the usual reason a press went nowhere, and it is invisible in screen.txt.
    [ -n "$sheet" ] && tlog "INSERT INTO evidence (check_id, kind, body)
                             VALUES ($check, 'sheet', '$(sq "$sheet")');"
    return 0
}

# ---------------------------------------------------------------------------- the committed record

# Writes `Tests/Scripted/last-run.md`, the one part of this that goes into the repository.
#
# **Because CI cannot run the suite and must still be able to tell whether anybody did.** There is no
# screen, no Keychain and no Google account on a build machine, so the only thing that can gate a merge is
# a record of a run that happened somewhere else. `logs/testlog.sqlite` holds far more, but `/logs/` is
# ignored by git and CI never sees it, so the few fields a check needs are written out here.
#
# **Written whether the run passed or failed.** A stamp that only appeared on success would let a failing
# branch keep an older passing one, which is the exact staleness this is for.
#
# It is generated from the recorded run rather than from shell variables, so what it claims is what the
# database saw. See `scripts/check_interactive_checklists.sh` for what is enforced.
testlog_stamp() {
    local run="${1:-}" path="${2:-Tests/Scripted/last-run.md}"
    [ -z "$run" ] && return 0

    local row branch commit dirty rebuilt started finished outcome passed failed skipped
    row=$(tlog "SELECT branch, commit_sha, dirty, rebuilt, started_at, IFNULL(finished_at, ''),
                       IFNULL(outcome, ''), IFNULL(passed, 0), IFNULL(failed, 0), IFNULL(skipped, 0)
                  FROM run WHERE run_id = $run;")
    [ -z "$row" ] && return 0
    IFS='|' read -r branch commit dirty rebuilt started finished outcome passed failed skipped <<EOF
$row
EOF

    local scripts_run scripts_failed
    scripts_run=$(tlog "SELECT COUNT(*) FROM script WHERE run_id = $run;")
    scripts_failed=$(tlog "SELECT COUNT(*) FROM script WHERE run_id = $run AND failed > 0;")

    {
        echo "# Scripted suite: last run"
        echo ""
        echo "Written by \`Tests/Scripted/run.sh\` at the end of every run, and committed."
        echo "**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually"
        echo "run, and a stamp that does not describe a real run is worse than no stamp at all."
        echo ""
        echo "    branch:   ${branch}"
        echo "    commit:   ${commit}"
        echo "    tree:     $([ "${dirty:-0}" = "1" ] && echo dirty || echo clean)"
        echo "    database: $([ "${rebuilt:-1}" = "1" ] && echo 'rebuilt from the DDL' || echo 'kept (--keep)')"
        echo "    started:  ${started}"
        echo "    finished: ${finished}"
        echo "    outcome:  ${outcome}"
        echo "    scripts:  ${scripts_run:-0} run, ${scripts_failed:-0} with failures"
        echo "    checks:   ${passed} passed, ${failed} failed, ${skipped} skipped"
        echo ""
        echo "| script | passed | failed | skipped |"
        echo "|---|---|---|---|"
        sqlite3 -noheader -separator '|' "$TESTLOG" \
            "SELECT name, passed, failed, skipped FROM script WHERE run_id = $run ORDER BY sequence;" \
            2>/dev/null |
            while IFS='|' read -r name p f s; do
                echo "| $name | $p | $f | $s |"
            done
        echo ""
        if [ "${dirty:-0}" = "1" ]; then
            echo "> The working tree had uncommitted changes when this ran, so it is not evidence about the"
            echo "> commit it names. CI refuses a stamp in this state."
            echo ""
        fi
        echo "The full record, including the app's own log rows and the accessibility tree at each failure,"
        echo "is in \`logs/testlog.sqlite\` on the machine that ran it. That file is not in the repository."
    } > "$path" 2>/dev/null || true
}

# ---------------------------------------------------------------------------- reading

testlog_report() {
    local limit="${1:-8}"
    if [ ! -f "$TESTLOG" ]; then
        echo "No log at $TESTLOG yet. It is written by Tests/Scripted/run.sh."
        return 0
    fi
    echo "== the last $limit run(s) =="
    sqlite3 -header -column "$TESTLOG" \
        "SELECT run_id, started_at, branch, dirty, rebuilt, outcome, passed, failed, skipped, seconds
           FROM v_run LIMIT $limit;"

    echo ""
    echo "== failures in those runs =="
    sqlite3 -header -column "$TESTLOG" \
        "SELECT run_id, script, description, detail FROM v_failure
          WHERE run_id > (SELECT IFNULL(MAX(run_id), 0) - $limit FROM run);" \
        | head -60

    echo ""
    echo "== never passed, in any run =="
    sqlite3 -header -column "$TESTLOG" "SELECT check_key, failed FROM v_never_passed LIMIT 20;"

    echo ""
    echo "== flaky: passed sometimes, failed others =="
    sqlite3 -header -column "$TESTLOG" "SELECT check_key, passed, failed, last_failed FROM v_flaky LIMIT 20;"

    echo ""
    echo "To read a failure's evidence:"
    echo "  sqlite3 $TESTLOG \"SELECT body FROM evidence WHERE check_id = <id> AND kind = 'ax_tree';\""
    echo "  sqlite3 $TESTLOG \"SELECT logged_at, tag, message FROM app_log WHERE script_id = <id> ORDER BY debug_log_id;\""
}

# Sourced by lib.sh, or run on its own to report.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    cd "$(dirname "${BASH_SOURCE[0]}")/../.."
    testlog_report "${1:-8}"
fi
