#!/usr/bin/env bash
#
#  acceptance_gate.sh —— 真机验收闸门（SKIP 不算通过）
#
#  背景：xcodebuild 里 XCTSkip 只是 skipped，整轮仍报 TEST SUCCEEDED。
#        「四项全跳过」和「四项全验过」退出码一样，这就是假绿。
#        本脚本跑完测试后统计 passed / failed / skipped 三项，并打印一行
#           [GATE] SKIPPED=N PASSED=M FAILED=K
#        只要 SKIPPED≠0、FAILED≠0 或 PASSED=0，就以非 0 退出。
#
#  用法：
#    ./acceptance_gate.sh <设备UDID>                 # 跑真机验收 + 闸门
#    ./acceptance_gate.sh --log <已有日志文件>        # 只对已有日志做闸门（离线复判）
#    ./acceptance_gate.sh --all <设备UDID>            # 连 SourceGuardTests + ConcurrencyLimiterTests 一起跑
#
#  前置：设备已连接并信任；相册里已有一批导出结果；Info.plist 权限已授权。
#
set -uo pipefail

LOG=""
MODE="device"
UDID=""
RUN_ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --log) MODE="log"; LOG="$2"; shift 2 ;;
    --all) RUN_ALL=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^#//; s/^ //'; exit 0 ;;
    *) UDID="$1"; shift ;;
  esac
done

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_0=""; }

if [ "$MODE" = "device" ]; then
  [ -n "$UDID" ] || { printf '用法：%s <设备UDID>  （xcodebuild -showdestinations 可查）\n' "$0"; exit 2; }
  command -v xcodebuild >/dev/null || { printf '缺少 xcodebuild\n'; exit 2; }

  LOG="$(mktemp "${TMPDIR:-/tmp}/acceptance.XXXXXX")"; trap 'rm -f "$LOG"' EXIT
  printf '跑真机验收：%s\n日志：%s\n\n' "$UDID" "$LOG"

  ONLY="-only-testing:WatermarkBatchTests/AcceptanceTests"
  if [ "$RUN_ALL" -eq 1 ]; then
    ONLY="-only-testing:WatermarkBatchTests/AcceptanceTests -only-testing:WatermarkBatchTests/ConcurrencyLimiterTests -only-testing:WatermarkBatchTests/SourceGuardTests"
  fi

  # shellcheck disable=SC2086
  xcodebuild test \
    -project WatermarkBatch.xcodeproj \
    -scheme WatermarkBatch \
    -destination "platform=iOS,id=$UDID" \
    $ONLY 2>&1 | tee "$LOG"
  XC_STATUS=${PIPESTATUS[0]}
else
  [ -f "$LOG" ] || { printf '日志不存在：%s\n' "$LOG"; exit 2; }
  XC_STATUS=0
  printf '离线复判日志：%s\n\n' "$LOG"
fi

# ---- 统计 ----
# 1) 逐用例行（最细粒度）：Test Case '-[Suite testX]' passed (0.123 seconds).
PASSED=$(grep -cE "^Test Case .* passed \(" "$LOG")
FAILED=$(grep -cE "^Test Case .* failed \(" "$LOG")
SKIPPED=$(grep -cE "^Test Case .* skipped \(" "$LOG")

# 2) xcodebuild 汇总行兜底："Executed 4 tests, with 0 failures (0 unexpected) in ... (0.5 seconds)"
#    注意：老版本不打印 skipped 计数，所以以逐用例统计为准，汇总行只做交叉验证。
EXEC_LINE=$(grep -E "^\s*Executed [0-9]+ test" "$LOG" | tail -1)
SKIP_EXEC=$(printf '%s' "$EXEC_LINE" | grep -oE '[0-9]+ skipped' | grep -oE '^[0-9]+' || true)

# 3) 我们自己的统计行："[Acceptance] testX SKIPPED=0 VERIFIED=3"
VERIFIED_SUM=$(grep -oE '\[Acceptance\] .* VERIFIED=[0-9]+' "$LOG" | grep -oE 'VERIFIED=[0-9]+' | cut -d= -f2 | awk '{s+=$1} END{print s+0}')
NO_VERIFY=$(grep -E '\[Acceptance\] .* SKIPPED=1' "$LOG" | wc -l | tr -d ' ')

printf '\n%s\n' "---- 闸门 ----"
if [ -n "$EXEC_LINE" ]; then printf 'xcodebuild: %s\n' "$(printf '%s' "$EXEC_LINE" | sed 's/^[[:space:]]*//')"; fi
printf '逐用例统计：passed=%s failed=%s skipped=%s ｜ 实际验过的样本数=%s ｜ 主动跳过项=%s\n' \
  "$PASSED" "$FAILED" "$SKIPPED" "$VERIFIED_SUM" "$NO_VERIFY"
printf '%s\n' "[GATE] SKIPPED=$SKIPPED PASSED=$PASSED FAILED=$FAILED"

RC=0
[ "$FAILED" -gt 0 ] && { printf '%s判未通过：有 %s 个失败用例%s\n' "$C_R" "$FAILED" "$C_0"; RC=1; }
[ "$SKIPPED" -gt 0 ] && { printf '%s判未通过：有 %s 个用例被跳过（跳过的验收等于没验）%s\n' "$C_R" "$SKIPPED" "$C_0"; RC=1; }
if [ -n "${SKIP_EXEC:-}" ] && [ "${SKIP_EXEC:-0}" -gt 0 ]; then
  printf '%s判未通过：xcodebuild 汇总行报告 %s skipped%s\n' "$C_R" "$SKIP_EXEC" "$C_0"; RC=1
fi
[ "$PASSED" -eq 0 ] && { printf '%s判未通过：一条用例都没跑起来（检查 destination / scheme）%s\n' "$C_R" "$C_0"; RC=1; }
[ "$VERIFIED_SUM" -eq 0 ] && { printf '%s判未通过：没有任何样本被真正校验（VERIFIED 合计为 0）%s\n' "$C_R" "$C_0"; RC=1; }
if [ "$XC_STATUS" -ne 0 ]; then
  printf '%s判未通过：xcodebuild 退出码 %s（编译失败或测试失败）%s\n' "$C_R" "$XC_STATUS" "$C_0"; RC=1
fi

if [ "$RC" -eq 0 ]; then
  printf '%s闸门通过：%s 个用例全过，共校验 %s 个样本，0 跳过%s\n' "$C_G" "$PASSED" "$VERIFIED_SUM" "$C_0"
fi
exit "$RC"
