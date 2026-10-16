#!/bin/sh
# Runs every tests/scripts/*.bs with the bs binary given as $1 and compares
# its stdout, stderr and exit status with NAME.stdout, NAME.stderr and
# NAME.status next to the script. A missing file means empty output, or
# status 0.
set -u

bs_binary=$1
# "with-formatter" when the binary was built with -Dformatter=true.
formatter_mode=${2:-without-formatter}
case $bs_binary in
  /*) ;;
  *) bs_binary=$PWD/$bs_binary ;;
esac
cd "$(dirname "$0")/scripts" || exit 1
# Lets scripts start bs again (see closed_pipe.bs).
export BS_BINARY=$bs_binary

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

# The version line embeds the git revision, so it is matched by shape, not
# compared with a file.
for version_flag in -v --version; do
  version_line=$("$bs_binary" "$version_flag")
  version_status=$?
  case $version_status:$version_line in
    "0:bs "*" ("*")") echo "ok   bs $version_flag" ;;
    *)
      echo "FAIL bs $version_flag: status $version_status, output '$version_line'"
      failure_count=$((failure_count + 1))
      ;;
  esac
done

# Without -Dformatter=true, `bs fmt` explains how to get it.
if [ "$formatter_mode" = without-formatter ]; then
  fmt_message=$("$bs_binary" fmt 2>&1 </dev/null)
  fmt_status=$?
  case $fmt_status:$fmt_message in
    "2:bs: fmt: this build does not include the formatter (build with -Dformatter=true)") echo "ok   bs fmt (not included)" ;;
    *)
      echo "FAIL bs fmt (not included): status $fmt_status, output '$fmt_message'"
      failure_count=$((failure_count + 1))
      ;;
  esac
fi

[ $failure_count -eq 0 ]
