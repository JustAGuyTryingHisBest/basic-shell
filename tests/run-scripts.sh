#!/bin/sh
# Runs every tests/scripts/*.bs with the bs binary given as $1 and compares
# its stdout, stderr and exit status with NAME.stdout, NAME.stderr and
# NAME.status next to the script. A missing file means empty output, or
# status 0.
set -u

bs_binary=$1
case $bs_binary in
  /*) ;;
  *) bs_binary=$PWD/$bs_binary ;;
esac
cd "$(dirname "$0")/scripts" || exit 1

scratch_directory=$(mktemp -d)
trap 'rm -rf "$scratch_directory"' EXIT
failure_count=0

for script in *.bs; do
  name=${script%.bs}
  "$bs_binary" "$script" >"$scratch_directory/stdout" 2>"$scratch_directory/stderr" </dev/null
  actual_status=$?
  expected_status=0
  [ -f "$name.status" ] && expected_status=$(cat "$name.status")

  passed=yes
  for stream in stdout stderr; do
    expected_file=$name.$stream
    [ -f "$expected_file" ] || expected_file=/dev/null
    if ! cmp -s "$expected_file" "$scratch_directory/$stream"; then
      echo "FAIL $script: $stream differs"
      diff -u "$expected_file" "$scratch_directory/$stream"
      passed=no
    fi
  done
  if [ "$actual_status" != "$expected_status" ]; then
    echo "FAIL $script: status $actual_status, expected $expected_status"
    passed=no
  fi
  if [ $passed = yes ]; then
    echo "ok   $script"
  else
    failure_count=$((failure_count + 1))
  fi
done

[ $failure_count -eq 0 ]
