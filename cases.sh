#!/usr/bin/env bash
# 生成的 native 测试驱动不做参数校验
#
#   `moon test --target native` 会生成 __generated_driver_for_*_test.mbt，
#   里面的 parse_args 直接裸索引 argv，没有长度检查：
#     cli_args[1]            （生成文件 331 行）—— 没查 cli_args.length()
#     file_and_range[1]      （生成文件 337 行）—— 没查切出来的段数
#   任何不是 `file:start-end` 形状的参数都会 panic → abort → exit 134 + core。
#
#   cases.sh prepare       构建测试驱动（注意：需要 MOON_CC，见姊妹仓库）
#   cases.sh list          列出用例
#   cases.sh run <case>    跑单个用例（退出 0 = PASS）
#   cases.sh lane <name>   bug | workaround | fixed

set -u

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
if [ ! -f "$REPO_DIR/moon.mod" ]; then
  echo "cases.sh: 找不到工程根（$REPO_DIR 下没有 moon.mod）" >&2
  exit 2
fi
MOON="${MOON:-$HOME/.moon/bin/moon}"
FIX_CC="${FIX_CC:-gcc}"

RC=0; OUT=""

ERRLOG="$(mktemp)"
trap 'rm -f "$ERRLOG"' EXIT
EXE=""

prepare() {
  OUT=$(MOON_CC="$FIX_CC" "$MOON" test --target native 2>&1); RC=$?
  if [ "$RC" != 0 ]; then
    echo "prepare 失败：构建测试驱动没成功（RC=$RC）" >&2
    echo "$OUT" | tail -6 >&2
    echo "提示：本仓库需要 MOON_CC 才能编译，见姊妹仓库 moonbug-replay-native-build-fails-*" >&2
    return 1
  fi
  EXE=$(ls -1 "$REPO_DIR"/_build/native/debug/test/*.blackbox_test.exe 2>/dev/null | head -1)
  if [ -z "$EXE" ]; then
    echo "prepare 失败：没找到 *.blackbox_test.exe" >&2
    return 1
  fi
}

run_driver() {  # run_driver <argv...>
  # 外层大括号的 2>/dev/null 是为了压掉 bash 自己刷的 "已中止 (核心已转储)"，
  # 那条消息会和 PASS/FAIL 挤在一起；进程真实退出码仍然照常拿到。
  { timeout 30 "$EXE" "$@" >/dev/null 2>"$ERRLOG"; RC=$?; } 2>/dev/null
  OUT=$(head -6 "$ERRLOG" | tr -d '\r' | tr '\n' ' ')
}

c_no_args()    { run_driver; }
c_help()       { run_driver --help; }
c_plain_word() { run_driver foo; }
c_file_only()  { run_driver a_test.mbt; }
c_well_formed(){ run_driver a_test.mbt:1-3; }
c_two_ranges() { run_driver a_test.mbt:1-3/a_test.mbt:1-3; }

# 名字|函数|期望 exit|期望输出含|说明
CASES=(
  "no-args|c_no_args|134|PanicError|不带任何参数"
  "help|c_help|134|PanicError|--help"
  "plain-word|c_plain_word|134|PanicError|无冒号的普通词"
  "file-only|c_file_only|134|PanicError|只有文件名，没有 :start-end"
  "well-formed|c_well_formed|0||格式正确，应正常执行"
  "two-ranges|c_two_ranges|0||两个区间，应正常执行"
)

lookup() {
  local want="$1" e
  for e in "${CASES[@]}"; do
    [ "${e%%|*}" = "$want" ] && { printf '%s' "$e"; return 0; }
  done
  return 1
}

do_assert() {  # do_assert <case> [<op> <code>]
  local name="$1" op="${2:-eq}" want="${3:-}" e n f exp grep desc ok=0
  if ! e="$(lookup "$name")"; then echo "unknown case: $name" >&2; return 2; fi
  IFS='|' read -r n f exp grep desc <<<"$e"
  [ -n "$want" ] || want="$exp"
  "$f"
  printf '  %-12s %-34s exit=%-4s ' "$n" "$desc" "$RC"
  if [ "$op" = eq ] && [ "$RC" = "$want" ]; then ok=1; fi
  if [ "$op" = ne ] && [ "$RC" != "$want" ]; then ok=1; fi
  if [ "$ok" = 1 ] && [ -n "$grep" ]; then
    case "$OUT" in *"$grep"*) ;; *) ok=2;; esac
  fi
  case "$ok" in
    1) echo "PASS" ;;
    2) echo "FAIL (退出码对了，但输出里没有 '$grep')" ;;
    *) echo "FAIL (期望 $op $want)" ;;
  esac
  [ "$ok" = 1 ]
}

lane() {
  local fail=0
  case "${1:-}" in
    bug)
      echo "命中问题 lane —— 畸形参数期望 exit 134（PanicError → abort）"
      do_assert no-args    || fail=1
      do_assert help       || fail=1
      do_assert plain-word || fail=1
      do_assert file-only  || fail=1
      ;;
    workaround)
      echo "绕过 lane —— 参数按 file:start-end 形状给，期望 exit 0"
      do_assert well-formed || fail=1
      do_assert two-ranges  || fail=1
      ;;
    fixed)
      echo "修复验收 lane —— 期望畸形参数不再 abort（上游修好后转 PASS）"
      do_assert no-args ne 134 || fail=1
      do_assert help    ne 134 || fail=1
      ;;
    *) echo "unknown lane: ${1:-}" >&2; return 2 ;;
  esac
  return $fail
}

diagnose() {
  echo "moon      : $MOON"
  "$MOON" version 2>&1 | sed 's/^/            /'
  echo "测试可执行: ${EXE:-<未构建>}"
    gen="$REPO_DIR/_build/native/debug/test/__generated_driver_for_blackbox_test.mbt"
    echo "驱动源码  : $gen"
    echo "--- 两处裸索引（行号:内容）---"
    grep -n 'cli_args\[1\]\|file_and_range\[1\]' "$gen" 2>/dev/null | sed 's/^/    /'
}

cd "$REPO_DIR"
prepare || exit 2

case "${1:-}" in
  list)
    printf '%-12s %-8s %-12s %s\n' CASE EXPECT "输出含" "说明"
    for e in "${CASES[@]}"; do
      IFS='|' read -r n f exp grep desc <<<"$e"
      printf '%-12s %-8s %-12s %s\n' "$n" "$exp" "${grep:-—}" "$desc"
    done
    ;;
  run)
    do_assert "${2:-}"
    ;;
  lane) lane "${2:-}" ;;
  diagnose) diagnose ;;
  *) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
