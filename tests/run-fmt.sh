#!/bin/sh
# Runs the `bs fmt` command-line tests (formatter spec §7, item 5) against
# the binary given as $1, which must be built with -Dformatter=true.
set -u

bs_binary=$1
case $bs_binary in
  /*) ;;
  *) bs_binary=$PWD/$bs_binary ;;
esac
cd "$(dirname "$0")" || exit 1

scratch_directory=$(mktemp -d)
trap 'chmod -R u+w "$scratch_directory"; rm -rf "$scratch_directory"' EXIT
failure_count=0

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failure_count=$((failure_count + 1))
}

# expect NAME EXPECTED_STATUS ACTUAL_STATUS: records a status check.
expect_status() {
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1: status $3, expected $2"; fi
}

# Every fixture formats to its .expected file through stdin.
for input in fmt/*.bs; do
  name=${input%.bs}
  "$bs_binary" fmt <"$input" >"$scratch_directory/stdout" 2>"$scratch_directory/stderr"
  status=$?
  if [ $status -eq 0 ] && cmp -s "$name.expected" "$scratch_directory/stdout"; then
    pass "stdin $input"
  else
    fail "stdin $input (status $status)"
    diff -u "$name.expected" "$scratch_directory/stdout"
    cat "$scratch_directory/stderr"
  fi
done

# Formatting is idempotent on every golden script that parses.
for script in scripts/*.bs; do
  "$bs_binary" fmt <"$script" >"$scratch_directory/once" 2>/dev/null || continue
  "$bs_binary" fmt <"$scratch_directory/once" >"$scratch_directory/twice" 2>&1
  if cmp -s "$scratch_directory/once" "$scratch_directory/twice"; then
    pass "idempotent $script"
  else
    fail "idempotent $script"
    diff -u "$scratch_directory/once" "$scratch_directory/twice"
  fi
done

# In-place rewrite keeps permissions and leaves no temporary file.
messy=$scratch_directory/messy.bs
cp fmt/example.bs "$messy"
chmod 750 "$messy"
"$bs_binary" fmt "$messy"
expect_status "in place: status" 0 $?
if cmp -s fmt/example.expected "$messy"; then pass "in place: content"; else fail "in place: content"; fi
case $(ls -l "$messy" | cut -c1-10) in
  -rwxr-x---) pass "in place: permissions" ;;
  *) fail "in place: permissions $(ls -l "$messy" | cut -c1-10)" ;;
esac
if [ ! -e "$messy.bs-fmt" ]; then pass "in place: no temporary file"; else fail "in place: temporary file left"; fi

# An already formatted file is not rewritten.
tidy=$scratch_directory/tidy.bs
reference=$scratch_directory/reference
cp fmt/example.expected "$tidy"
touch -t 200001010000 "$tidy" "$reference"
"$bs_binary" fmt "$tidy"
expect_status "unchanged: status" 0 $?
if [ "$tidy" -nt "$reference" ]; then fail "unchanged: file was rewritten"; else pass "unchanged: not rewritten"; fi

# --check lists the files that would change and writes nothing.
cp fmt/example.bs "$messy"
check_output=$("$bs_binary" fmt --check "$tidy" "$messy")
expect_status "check: status with changes" 1 $?
if [ "$check_output" = "$messy" ]; then pass "check: lists changed file"; else fail "check: output '$check_output'"; fi
if cmp -s fmt/example.bs "$messy"; then pass "check: writes nothing"; else fail "check: file was modified"; fi
check_output=$("$bs_binary" fmt --check "$tidy")
expect_status "check: status when formatted" 0 $?
if [ -z "$check_output" ]; then pass "check: silent when formatted"; else fail "check: output '$check_output'"; fi
"$bs_binary" fmt --check <fmt/example.bs >"$scratch_directory/stdout"
expect_status "check: stdin with changes" 1 $?
if [ ! -s "$scratch_directory/stdout" ]; then pass "check: stdin prints nothing"; else fail "check: stdin printed output"; fi

# A syntax error is reported with diagnostics and leaves the file untouched.
broken=$scratch_directory/broken.bs
printf 'f (a' >"$broken"
"$bs_binary" fmt "$broken" 2>"$scratch_directory/stderr"
expect_status "syntax error: status" 2 $?
if grep -q "broken.bs:1:5: error: expected ')'" "$scratch_directory/stderr"; then pass "syntax error: diagnostic"; else fail "syntax error: diagnostic"; cat "$scratch_directory/stderr"; fi
if [ "$(cat "$broken")" = "f (a" ]; then pass "syntax error: file untouched"; else fail "syntax error: file modified"; fi

# Mixed files: the valid one is still formatted; the worst status wins.
cp fmt/example.bs "$messy"
"$bs_binary" fmt "$broken" "$messy" 2>/dev/null
expect_status "mixed files: status" 2 $?
if cmp -s fmt/example.expected "$messy"; then pass "mixed files: valid file formatted"; else fail "mixed files: valid file not formatted"; fi

# A file in a directory bs cannot write is reported and left untouched.
if [ "$(id -u)" -ne 0 ]; then
  locked_directory=$scratch_directory/locked
  mkdir "$locked_directory"
  cp fmt/example.bs "$locked_directory/messy.bs"
  chmod 555 "$locked_directory"
  "$bs_binary" fmt "$locked_directory/messy.bs" 2>"$scratch_directory/stderr"
  expect_status "unwritable directory: status" 1 $?
  if grep -q "^bs: fmt: $locked_directory/messy.bs: " "$scratch_directory/stderr"; then pass "unwritable directory: message"; else fail "unwritable directory: message"; cat "$scratch_directory/stderr"; fi
  if cmp -s fmt/example.bs "$locked_directory/messy.bs"; then pass "unwritable directory: untouched"; else fail "unwritable directory: modified"; fi
  if [ ! -e "$locked_directory/messy.bs.bs-fmt" ]; then pass "unwritable directory: no temporary file"; else fail "unwritable directory: temporary file left"; fi
  chmod 755 "$locked_directory"
fi

# Empty stdin gives empty output.
"$bs_binary" fmt </dev/null >"$scratch_directory/stdout"
expect_status "empty stdin: status" 0 $?
if [ ! -s "$scratch_directory/stdout" ]; then pass "empty stdin: no output"; else fail "empty stdin: output"; fi

# Unknown options and unreadable files.
message=$("$bs_binary" fmt --frob 2>&1)
expect_status "unknown option: status" 2 $?
if [ "$message" = "bs: fmt: unknown option '--frob'" ]; then pass "unknown option: message"; else fail "unknown option: '$message'"; fi
message=$("$bs_binary" fmt "$scratch_directory/missing.bs" 2>&1)
expect_status "missing file: status" 1 $?
if [ "$message" = "bs: fmt: $scratch_directory/missing.bs: no such file or directory" ]; then pass "missing file: message"; else fail "missing file: '$message'"; fi

[ $failure_count -eq 0 ]
