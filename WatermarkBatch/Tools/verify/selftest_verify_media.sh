#!/usr/bin/env bash
#
#  selftest_verify_media.sh —— 反向验证 verify_media.sh（先证明它会红，PASS 才算数）
#
#  为什么必须先跑这个：一个恒绿的检测脚本比没有检测更危险。本脚本现场造出四类
#  「已知不合格」样本和一个「已知合格」对照，逐个喂给 verify_media.sh，断言它：
#    · 对改过逐帧延时的 GIF 报 FAIL（退出码 1）
#    · 对音轨被转成 PCM 的 MOV 报 FAIL（退出码 1）
#    · 对配不上对的 Live Photo 报 FAIL（退出码 1）
#    · 对完全相同的文件对报 PASS（退出码 0）——这条是正向对照，防止检测器恒红
#
#  用法：bash selftest_verify_media.sh
#  退出码：0 全部行为符合预期；1 有不符合（此刻不要信 verify_media.sh 的任何 PASS）
#
#  依赖：ffmpeg / ffprobe（brew install ffmpeg）、exiftool（brew install exiftool）、
#        python3 + Pillow（GIF 逐帧延时样本）、sips（macOS 自带，用于出 HEIC 静帧）
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/verify_media.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vmselftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; Z=$'\033[0m'
[ -t 1 ] || { R=""; G=""; Y=""; D=""; Z=""; }

PASSED=0; FAILED=0; SKIPPED=0
declare -a SKIP_REASONS=()

[ -f "$TARGET" ] || { printf '%s找不到 %s%s\n' "$R" "$TARGET" "$Z"; exit 2; }

need() { command -v "$1" >/dev/null 2>&1; }
need ffmpeg || { printf '%s缺少 ffmpeg：brew install ffmpeg%s\n' "$R" "$Z"; exit 2; }
need ffprobe || { printf '%s缺少 ffprobe%s\n' "$R" "$Z"; exit 2; }

# expect <用例名> <期望退出码> <命令...>
expect() {
  local name="$1" want="$2"; shift 2
  local log="$WORK/case.log"
  "$@" >"$log" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    printf '  %sSELFTEST PASS%s  %s（退出码 %s，符合预期）\n' "$G" "$Z" "$name" "$got"
    PASSED=$((PASSED+1))
  else
    printf '  %sSELFTEST FAIL%s  %s（期望退出码 %s，实际 %s）\n' "$R" "$Z" "$name" "$want" "$got"
    sed -n '1,24p' "$log" | sed "s/^/      ${D}/; s/$/${Z}/"
    FAILED=$((FAILED+1))
  fi
}

skip_case() {
  printf '  %sSELFTEST SKIP%s  %s —— %s\n' "$Y" "$Z" "$1" "$2"
  SKIPPED=$((SKIPPED+1)); SKIP_REASONS+=("$1：$2")
}

printf '工作目录：%s\n被测脚本：%s\n\n' "$WORK" "$TARGET"

# ══════════════════════════════════════════════════════════
# 用例 1/2：GIF —— 改过逐帧延时的必须被抓；完全相同的必须放行
# ══════════════════════════════════════════════════════════
printf '%s\n' "── GIF 逐帧延时 ──"
if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 - "$WORK" <<'PY'
import sys, os
from PIL import Image
w = sys.argv[1]

def build(path, delays, loop=0):
    frames = []
    for color in [(230, 60, 60), (60, 200, 120), (70, 120, 240)]:
        img = Image.new("RGB", (64, 48), color)
        frames.append(img.convert("P"))
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=delays, loop=loop, optimize=False)

# 原图：三帧延时各不相同（100/200/300ms）
build(os.path.join(w, "orig.gif"), [100, 200, 300])
# 不合格：同样三帧，但延时被归一化成 100/100/100（典型的「只 SetProperties 设一次」）
build(os.path.join(w, "bad.gif"),  [100, 100, 100])
# 合格对照：原图逐字节复制
import shutil; shutil.copyfile(os.path.join(w, "orig.gif"), os.path.join(w, "good.gif"))
PY
  expect "GIF 延时被归一化 → 必须报 FAIL" 1 bash "$TARGET" gif "$WORK/orig.gif" "$WORK/bad.gif"
  expect "GIF 原图自比 → 必须报 PASS"      0 bash "$TARGET" gif "$WORK/orig.gif" "$WORK/good.gif"
else
  skip_case "GIF 反向样本" "未安装 Pillow（python3 -m pip install --user pillow）"
fi

# ══════════════════════════════════════════════════════════
# 用例 3/4：视频 —— 音轨被转成 PCM 的必须被抓；相同文件必须放行
# ══════════════════════════════════════════════════════════
printf '\n%s\n' "── 视频音轨 passthrough ──"
ffmpeg -y -hide_banner -v error \
  -f lavfi -i "testsrc2=size=640x360:rate=30:duration=2" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -b:v 2000k \
  -c:a aac -b:a 128k -shortest "$WORK/orig.mov" 2>"$WORK/ff.log"
if [ -s "$WORK/orig.mov" ]; then
  # 不合格：视频流原样 copy，只把音频解成 PCM（= 音频被重编码）
  ffmpeg -y -hide_banner -v error -i "$WORK/orig.mov" -c:v copy -c:a pcm_s16le "$WORK/bad_audio.mov" 2>>"$WORK/ff.log"
  cp "$WORK/orig.mov" "$WORK/good.mov"

  expect "音轨变 PCM → 必须报 FAIL" 1 bash "$TARGET" video "$WORK/orig.mov" "$WORK/bad_audio.mov" --factor 1.0
  expect "视频原片自比 → 必须报 PASS" 0 bash "$TARGET" video "$WORK/orig.mov" "$WORK/good.mov" --factor 1.0
else
  printf '  %sSELFTEST FAIL%s  连基准视频都生成失败，ffmpeg 不可用\n' "$R" "$Z"
  sed -n '1,10p' "$WORK/ff.log" | sed 's/^/      /'
  FAILED=$((FAILED+1))
fi

# ══════════════════════════════════════════════════════════
# 用例 5：Live Photo —— 配对键缺失的必须被抓
# ══════════════════════════════════════════════════════════
printf '\n%s\n' "── Live Photo 配对键 ──"
if need sips && need exiftool; then
  ffmpeg -y -hide_banner -v error -i "$WORK/orig.mov" -frames:v 1 "$WORK/still.png" 2>/dev/null \
    && sips -s format heic "$WORK/still.png" --out "$WORK/still-export.heic" >/dev/null 2>&1
  if [ -s "$WORK/still-export.heic" ]; then
    cp "$WORK/orig.mov" "$WORK/pair-unpaired.mov"   # 无 content identifier
    expect "静帧无 key17 / MOV 无 identifier → 必须报 FAIL" 1 \
      bash "$TARGET" live "$WORK/still-export.heic" "$WORK/pair-unpaired.mov"
  else
    skip_case "Live Photo 反向样本" "sips 未能生成 HEIC（某些 macOS 版本不支持此转换）"
  fi
else
  skip_case "Live Photo 反向样本" "缺 sips 或 exiftool"
fi

# ══════════════════════════════════════════════════════════
printf '\n%s\n' "── 自测结论 ──"
printf '  符合预期 %d ｜ 不符合 %d ｜ 未能构造 %d\n' "$PASSED" "$FAILED" "$SKIPPED"
if [ "$SKIPPED" -gt 0 ]; then
  printf '  %s未验全的情况（同样不算通过）：%s\n' "$Y" "$Z"
  for r in "${SKIP_REASONS[@]}"; do printf '    - %s\n' "$r"; done
fi

RC=0
[ "$FAILED" -gt 0 ] && { printf '  %s检测脚本行为不符合预期：在修好之前，不要相信它给出的任何 PASS%s\n' "$R" "$Z"; RC=1; }
[ "$SKIPPED" -gt 0 ] && { printf '  %s有用例没构造出来：检测器覆盖不全，按「跳过≠通过」判未完成%s\n' "$Y" "$Z"; RC=1; }
[ "$PASSED" -eq 0 ] && { printf '  %s一条都没验到%s\n' "$R" "$Z"; RC=1; }
[ "$RC" -eq 0 ] && printf '  %s%s\n' "$G" "自测通过：脚本对不合格样本会红、对相同样本会绿，可以开始信它的结果$Z"
exit "$RC"
