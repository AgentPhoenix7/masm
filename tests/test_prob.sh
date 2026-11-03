#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
source_file="$repo_root/programs/prob.asm"
tools_dir="$repo_root/dos-tools"

if [[ ! -f "$source_file" ]]; then
    echo "FAIL: programs/prob.asm is missing"
    exit 1
fi

test_dir=$(mktemp -d /tmp/masm-prob-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

cp "$source_file" "$test_dir/PROB.ASM"

printf '12 + 3 * (4 ^ 2)\r\n' > "$test_dir/CASE1.IN"
printf '2^3^4\r\n'             > "$test_dir/CASE2.IN"
printf '(10+20)*3-8/4\r\n'     > "$test_dir/CASE3.IN"
printf '2+*3\r\n'              > "$test_dir/BAD1.IN"
printf '(1+2\r\n'              > "$test_dir/BAD2.IN"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
timeout 15s dosbox -noconsole \
    -c "z:" \
    -c "mount -u c" \
    -c "mount -u t" \
    -c "mount c $test_dir" \
    -c "mount t $tools_dir" \
    -c "c:" \
    -c "path t:\\" \
    -c "masm prob.asm;" \
    -c "link prob.obj;" \
    -c "exit" >/dev/null 2>&1

if [[ ! -f "$test_dir/PROB.EXE" ]]; then
    echo "FAIL: MASM or LINK did not create PROB.EXE"
    exit 1
fi

# DOSBox 0.74 does not reliably reset redirected stdin between several DOS
# programs in one shell session. Give every fixture a fresh shell session.
run_case() {
    local case_name=$1
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 10s dosbox -noconsole \
        -c "z:" \
        -c "mount -u c" \
        -c "mount c $test_dir" \
        -c "c:" \
        -c "prob < $case_name.in > $case_name.out" \
        -c "exit" >/dev/null 2>&1
}

run_case case1
run_case case2
run_case case3
run_case bad1
run_case bad2

normalize() {
    tr -d '\r\032' < "$1"
}

assert_contains() {
    local file=$1
    local expected=$2
    local output
    output=$(normalize "$file")
    if [[ "$output" != *"$expected"* ]]; then
        echo "FAIL: $(basename "$file")"
        echo "Expected to contain: $expected"
        echo "Actual output:"
        echo "$output"
        exit 1
    fi
}

# Catches broken precedence, parentheses, multi-digit token grouping, and spaces.
assert_contains "$test_dir/CASE1.OUT" "Postfix expression: 12 3 4 2 ^ * +"

# Catches treating exponentiation as left-associative.
assert_contains "$test_dir/CASE2.OUT" "Postfix expression: 2 3 4 ^ ^"

# Catches incorrect precedence across every left-associative operator.
assert_contains "$test_dir/CASE3.OUT" "Postfix expression: 10 20 + 3 * 8 4 / -"

# Catches accepting an operator where an operand is required.
assert_contains "$test_dir/BAD1.OUT" "ERROR: invalid infix expression."

# Catches accepting unmatched parentheses.
assert_contains "$test_dir/BAD2.OUT" "ERROR: invalid infix expression."

echo "PASS: all prob.asm behavior tests passed"
