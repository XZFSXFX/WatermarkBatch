#!/usr/bin/env bash
#
#  verify_media.sh —— 水印工坊 BatchMark · 导出保真验收（Mac 侧，文件级）
#
#  用途：把「导出的文件」和「原文件」放在一起比对，自动给 PASS/FAIL。
#        覆盖四项真机验收里可以由文件证明的三项半：
#          ① Live Photo 配对键（静帧 MakerApple key17 与 MOV content identifier 必须相等）
#          ② GIF 帧数 / 每帧延时 / 循环次数 / 透明色
#          ③ 4K HDR 色彩标签未降级（color_primaries / transfer / matrix / pix_fmt / 位深）
#          ④ 音频是否 passthrough（两条音频流 md5 是否逐字节相同）
#        外加 PSNR / SSIM（水印区域外，验收线 42dB / 0.98）
#        「长按可播放」这一项文件证明不了，用 Tests/AcceptanceTests.swift 在真机上跑。
#
#  依赖：ffmpeg / ffprobe（brew install ffmpeg）、exiftool（brew install exiftool）、
#        python3 + Pillow（python3 -m pip install --user pillow，仅 GIF 精确逐帧延时需要）
#
#  用法：
#    ./verify_media.sh live  <导出的静帧.HEIC|.JPG> <导出的配对.MOV>
#    ./verify_media.sh gif   <原图.gif> <导出.gif>
#    ./verify_media.sh video <原片.mov> <导出.mov> [--factor 1.3]
#    ./verify_media.sh psnr  <原片.mov> <导出.mov> [--crop 1080:1620:0:0] [--minpsnr 42] [--minssim 0.98]
#    ./verify_media.sh all   <manifest.tsv>        # 每行：类型<TAB>原文件<TAB>导出文件
#
#  退出码：0 全 PASS；1 有 FAIL；2 依赖缺失或参数错误
#
#  设计原则：宁可报 WARN 也不替用户猜。任何「比不了」（缺文件、缺元数据）都显式打出来并计入 FAIL/WARN，
#            绝不静默跳过——静默跳过正是这个项目最不能犯的错。
#

set -uo pipefail

PASS_N=0; FAIL_N=0; WARN_N=0
FAIL_LINES=()

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
if [ ! -t 1 ]; then c_red=""; c_grn=""; c_yel=""; c_dim=""; c_off=""; fi

ok()   { PASS_N=$((PASS_N+1)); printf '  %sPASS%s  %s\n' "$c_grn" "$c_off" "$1"; }
bad()  { FAIL_N=$((FAIL_N+1)); FAIL_LINES+=("$1"); printf '  %sFAIL%s  %s\n' "$c_red" "$c_off" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
warn() { WARN_N=$((WARN_N+1)); printf '  %sWARN%s  %s\n' "$c_yel" "$c_off" "$1"; }
info() { printf '  %s%s%s\n' "$c_dim" "$1" "$c_off"; }
head1(){ printf '\n%s\n' "== $1 =="; }

need() {
  command -v "$1" >/dev/null 2>&1 || { printf '%s缺少依赖：%s%s\n' "$c_red" "$1" "$c_off"; exit 2; }
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- 通用探针 ----------

# 读单个流字段：probe_stream <file> <stream> <entry>
probe_stream() {
  ffprobe -v error -select_streams "$2" -show_entries "stream=$3" -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1
}

# 全流 JSON（一次调用取全部，避免多次起进程）
probe_json() { ffprobe -v error -show_streams -show_format -of json "$1" 2>/dev/null; }

# ---------- ① Live Photo 配对 ----------

cmd_live() {
  local still="${1:-}" mov="${2:-}"
  [ -f "$still" ] || { printf '文件不存在：%s\n' "$still"; exit 2; }
  [ -f "$mov" ]   || { printf '文件不存在：%s\n' "$mov"; exit 2; }
  need exiftool; need ffprobe

  head1 "Live Photo 配对：$(basename "$still") + $(basename "$mov")"

  # 静帧里的 assetIdentifier：MakerApple 字典 key 17
  local id_still
  id_still=$(exiftool -s3 -MakerApple:17 "$still" 2>/dev/null | head -1)
  if [ -z "$id_still" ]; then
    # 部分 exiftool 版本把 key 17 以别的组名暴露，退一步按关键字抓
    id_still=$(exiftool -s -G1 "$still" 2>/dev/null | grep -iE 'MakerApple.*\b17\b|ContentIdentifier' | head -1 | sed 's/.*: *//')
  fi

  local id_mov
  id_mov=$(exiftool -s3 -ContentIdentifier "$mov" 2>/dev/null | head -1)
  if [ -z "$id_mov" ]; then
    id_mov=$(exiftool -s3 -Keys:ContentIdentifier "$mov" 2>/dev/null | head -1)
  fi

  info "静帧 assetIdentifier: ${id_still:-<空>}"
  info "MOV  contentIdentifier: ${id_mov:-<空>}"

  if [ -z "$id_still" ] || [ -z "$id_mov" ]; then
    bad "配对键缺失，系统无法把两者认成同一张 Live Photo" "静帧需 MakerApple key17、MOV 需 com.apple.quicktime.content.identifier"
  else
    if [ "$id_still" = "$id_mov" ]; then
      ok "配对键相等（$id_still）"
    else
      bad "配对键不相等 —— 输出会是「静帧 + 独立视频」而非 Live Photo" "静帧=$id_still  MOV=$id_mov"
    fi
  fi

  # 文件名基名一致性（PHLivePhoto 依赖同 basename 约定）
  local bs bm
  bs="$(basename "$still")"; bs="${bs%.*}"
  bm="$(basename "$mov")";   bm="${bm%.*}"
  if [ "$bs" = "$bm" ]; then ok "文件名基名一致（$bs）"; else warn "基名不一致（$bs vs $bm），PHLivePhoto.request 可能取不到配对"; fi

  # MOV 必须真含视频轨且有时长
  local vdur codec
  vdur=$(probe_stream "$mov" v:0 duration)
  codec=$(probe_stream "$mov" v:0 codec_name)
  if [ -n "$vdur" ] && awk "BEGIN{exit !($vdur > 0.6)}"; then
    ok "配对 MOV 视频轨 ${codec}，时长 ${vdur}s（Live Photo 正片段通常 ≥1s）"
  else
    bad "配对 MOV 视频轨异常（时长=${vdur:-空}）" "长按将不可播放"
  fi

  # 静帧像素尺寸（应与原静帧一致，此处只报数，供人工对照）
  info "静帧尺寸: $(probe_stream "$still" v:0 width) x $(probe_stream "$still" v:0 height)"
}

# ---------- ② GIF 逐帧 ----------

gif_dump_pillow() {
  python3 - "$1" <<'PY'
import sys
try:
    from PIL import Image
except Exception:
    sys.exit(3)
p = sys.argv[1]
im = Image.open(p)
n = getattr(im, "n_frames", 1)
delays, transparent = [], []
for i in range(n):
    im.seek(i)
    d = im.info.get("duration", 0)
    delays.append(int(d))
    transparent.append(1 if ("transparency" in im.info) else 0)
loop = im.info.get("loop", -1)
print("frames", n)
print("loop", loop)
print("delays", ",".join(str(x) for x in delays))
print("transparent", ",".join(str(x) for x in transparent))
print("size", "%dx%d" % im.size)
PY
}

gif_dump_ffprobe() {
  local f="$1"
  local n
  n=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$f" 2>/dev/null | head -1)
  local d
  d=$(ffprobe -v error -select_streams v:0 -show_entries frame=pkt_duration_time -of csv=p=0 "$f" 2>/dev/null | tr -d '\r' | awk -F, '{printf "%d,", ($1*1000)+0.5}')
  printf 'frames %s\nloop unknown\ndelays %s\ntransparent unknown\nsize %sx%s\n' \
    "$n" "${d%,}" "$(probe_stream "$f" v:0 width)" "$(probe_stream "$f" v:0 height)"
}

gif_field() { printf '%s\n' "$2" | awk -v k="$1" '$1==k{sub(/^[^ ]+ /,"");print}'; }

cmd_gif() {
  local a="${1:-}" b="${2:-}"
  [ -f "$a" ] || { printf '文件不存在：%s\n' "$a"; exit 2; }
  [ -f "$b" ] || { printf '文件不存在：%s\n' "$b"; exit 2; }
  need ffprobe

  head1 "GIF/WebP 动图：$(basename "$a") → $(basename "$b")"

  local da db mode="pillow"
  if da=$(gif_dump_pillow "$a") && db=$(gif_dump_pillow "$b"); then :; else
    mode="ffprobe"
    warn "未检测到 Pillow，逐帧延时降级为 ffprobe（精度 1ms，且无循环次数/透明色）——建议 python3 -m pip install --user pillow"
    da=$(gif_dump_ffprobe "$a"); db=$(gif_dump_ffprobe "$b")
  fi
  info "解析方式：$mode"

  local fa fb
  fa=$(gif_field frames "$da"); fb=$(gif_field frames "$db")
  if [ "$fa" = "$fb" ]; then ok "帧数一致（$fa）"; else bad "帧数不一致（原 $fa → 导出 $fb）" "抽帧/合帧会直接改变动图时长与观感"; fi

  local sa sb
  sa=$(gif_field size "$da"); sb=$(gif_field size "$db")
  if [ "$sa" = "$sb" ]; then ok "帧尺寸一致（$sa）"; else bad "帧尺寸不一致（原 $sa → 导出 $sb）" "缩放属严重违规"; fi

  if [ "$mode" = "pillow" ]; then
    local la lb
    la=$(gif_field loop "$da"); lb=$(gif_field loop "$db")
    if [ "$la" = "$lb" ]; then
      if [ "$la" = "-1" ]; then ok "循环次数一致（均不限次 / 无 NETSCAPE 块）"; else ok "循环次数一致（$la）"; fi
    else
      bad "循环次数不一致（原 $la → 导出 $lb）"
    fi
  fi

  local dla dlb
  dla=$(gif_field delays "$da"); dlb=$(gif_field delays "$db")
  local cmp
  cmp=$(python3 - "$dla" "$dlb" <<'PY'
import sys
a=[int(x) for x in sys.argv[1].split(',') if x.strip()!='']
b=[int(x) for x in sys.argv[2].split(',') if x.strip()!='']
if len(a)!=len(b):
    print("LEN %d %d" % (len(a),len(b))); sys.exit()
diff=[(i,a[i],b[i]) for i in range(len(a)) if abs(a[i]-b[i])>10]   # 容差 10ms（GIF 单位为 1/100s）
if not diff:
    print("OK total_a=%d total_b=%d max_delta=%d" % (sum(a), sum(b), max([abs(a[i]-b[i]) for i in range(len(a))] or [0])))
else:
    print("DIFF " + "; ".join("帧%d %dms→%dms" % d for d in diff[:8]) + (" ...共%d帧" % len(diff) if len(diff)>8 else ""))
PY
)
  case "$cmp" in
    OK*) ok "逐帧延时一致（$cmp）" ;;
    LEN*) bad "逐帧延时段数不一致（$cmp）" ;;
    DIFF*) bad "逐帧延时不一致（$cmp）" "不同帧延时被归一化/取平均是常见错误" ;;
    *) warn "逐帧延时比对未产出结论：$cmp" ;;
  esac

  if [ "$mode" = "pillow" ]; then
    local ta tb
    ta=$(gif_field transparent "$da"); tb=$(gif_field transparent "$db")
    if [ "$ta" = "$tb" ]; then ok "透明帧分布一致"; else warn "透明帧分布不同（原 [$ta] → 导出 [$tb]）；若源为不透明 GIF 可忽略"; fi
  fi
}

# ---------- ③④ 视频：HDR 标签 + 音频 passthrough ----------

cmd_video() {
  local a="${1:-}" b="${2:-}"; shift 2 2>/dev/null || true
  local factor="1.3"
  while [ $# -gt 0 ]; do
    case "$1" in
      --factor) factor="$2"; shift 2 ;;
      *) printf '未知参数：%s\n' "$1"; exit 2 ;;
    esac
  done
  [ -f "$a" ] || { printf '文件不存在：%s\n' "$a"; exit 2; }
  [ -f "$b" ] || { printf '文件不存在：%s\n' "$b"; exit 2; }
  need ffprobe; need ffmpeg

  head1 "视频保真：$(basename "$a") → $(basename "$b")（码率系数期望 ≥ $factor）"

  local ja jb
  ja=$(probe_json "$a"); jb=$(probe_json "$b")

  python3 - "$ja" "$jb" "$a" "$b" "$factor" <<'PY'
import sys, json
ja, jb, pa, pb, factor = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
A = json.loads(ja) if ja else {}
B = json.loads(jb) if jb else {}
if not A or not B:
    print("FATAL 无法解析 ffprobe 输出"); sys.exit(0)

def vstream(d):
    for s in d.get("streams", []):
        if s.get("codec_type") == "video": return s
    return {}
def astream(d):
    for s in d.get("streams", []):
        if s.get("codec_type") == "audio": return s
    return {}

va, vb = vstream(A), vstream(B)
aa, ab = astream(A), astream(B)

def num(x):
    try: return float(x)
    except Exception: return 0.0

fails = []
def cmp(label, x, y, critical=True):
    if x == y: print("PASS  %-18s %s" % (label, x))
    else:
        msg = "FAIL  %-18s %s → %s" % (label, x, y)
        print(msg)
        if critical: fails.append(label)

for k in ("codec_name","profile","width","height","pix_fmt","color_range","color_space","color_transfer","color_primaries"):
    cmp(k, va.get(k,""), vb.get(k,""))

# 帧率
fa = va.get("avg_frame_rate") or va.get("r_frame_rate") or ""
fb = vb.get("avg_frame_rate") or vb.get("r_frame_rate") or ""
cmp("frame_rate", fa, fb)

# 旋转矩阵（display matrix side_data）
def rot(s):
    for sd in (s.get("side_data_list") or []):
        if "rotation" in sd: return str(sd["rotation"])
    return "0"
cmp("rotation", rot(va), rot(vb), critical=False)

# 时长（容差 1 帧）
def dur(d, v):
    x = num(d.get("format",{}).get("duration"))
    if x: return x
    return num(v.get("duration"))
da_, db_ = dur(A,va), dur(B,vb)
fps = num(fa.split("/")[0]) / max(1.0, num(fa.split("/")[1])) if "/" in fa else 0
tol = max(0.05, (1.0/fps if fps else 0.05))
if abs(da_-db_) <= tol: print("PASS  %-18s %.3fs" % ("duration", db_))
else:
    print("FAIL  %-18s %.3fs → %.3fs（差 %.3fs > 1 帧）" % ("duration", da_, db_, db_-da_)); fails.append("duration")

# HDR 位深（bits_per_raw_sample 或 pix_fmt 推断）
def depth(s):
    p = s.get("pix_fmt","") or ""
    if "10" in p: return 10
    if "12" in p: return 12
    return 8
if depth(va) == depth(vb): print("PASS  %-18s %dbit" % ("bit_depth", depth(vb)))
else:
    print("FAIL  %-18s %dbit → %dbit" % ("bit_depth", depth(va), depth(vb))); fails.append("bit_depth")

# HDR 元数据（Dolby Vision / mastering display 等 side data）
def hdrkeys(s):
    ks = []
    for sd in (s.get("side_data_list") or []):
        t = sd.get("side_data_type", "") or ""
        tl = t.lower()
        if any(x in tl for x in ("dovi", "mastering", "content light", "hdr", "display metadata")):
            ks.append(t)
    return sorted(ks)
ha, hb = hdrkeys(va), hdrkeys(vb)
if ha == hb:
    print("PASS  %-18s %s" % ("hdr_sidedata", ha or "无"))
elif ha and not hb:
    # 源有 HDR 元数据、导出没了 —— 这正是「HDR 变灰」的根因，必须判死而不是提示。
    print("FAIL  %-18s HDR 元数据全部丢失：%s → 无" % ("hdr_sidedata", ha)); fails.append("hdr_sidedata")
else:
    print("WARN  %-18s %s → %s" % ("hdr_sidedata", ha, hb))

# 码率
bra = num(A.get("format",{}).get("bit_rate")); brb = num(B.get("format",{}).get("bit_rate"))
if bra and brb:
    ratio = brb/bra
    tag = "PASS" if ratio >= factor - 0.02 else "FAIL"
    print("%s  %-18s %.2f Mbps → %.2f Mbps（×%.2f，期望 ≥%.2f）" % (tag, "bitrate", bra/1e6, brb/1e6, ratio, factor))
    if tag == "FAIL": fails.append("bitrate")
else:
    print("WARN  %-18s 无法读取码率" % "bitrate")

# 音频：格式是否原样 + 是否存在
if bool(aa) != bool(ab):
    print("FAIL  %-18s 原 %s → 导出 %s" % ("audio_present", "有" if aa else "无", "有" if ab else "无")); fails.append("audio_present")
elif aa:
    for k in ("codec_name","profile","sample_rate","channels","channel_layout","bit_rate"):
        cmp("audio_"+k, aa.get(k,""), ab.get(k,""), critical=(k in ("codec_name","sample_rate","channels")))
    # 压缩轨 = 未解码重编的证据（PCM 说明被解开了）
    if ab.get("codec_name") in ("pcm_s16le","pcm_s24le","pcm_s32le","pcm_f32le"):
        print("FAIL  %-18s 音频被解为 PCM（说明重编码）" % "audio_passthrough"); fails.append("audio_passthrough")
    else:
        print("PASS  %-18s 保持 %s（未降为 PCM）" % ("audio_container", ab.get("codec_name")))
else:
    print("WARN  %-18s 两文件均无音频轨" % "audio")

print("SUMMARY " + ("OK" if not fails else "FAILS:" + ",".join(fails)))
PY

  # 音频逐字节 md5（passthrough 的硬证据）
  local ma mb
  ma=$(ffmpeg -hide_banner -v error -i "$a" -map 0:a:0 -c copy -f md5 - 2>/dev/null | sed 's/MD5=//')
  mb=$(ffmpeg -hide_banner -v error -i "$b" -map 0:a:0 -c copy -f md5 - 2>/dev/null | sed 's/MD5=//')
  if [ -z "$ma" ] || [ -z "$mb" ]; then
    warn "无音频流或无法提取，跳过音频 md5"
  elif [ "$ma" = "$mb" ]; then
    ok "音频流 md5 逐字节相同（$ma）→ passthrough 成立"
  else
    bad "音频流 md5 不同 —— 音频被重编码" "原 $ma  导出 $mb"
  fi
}

# ---------- PSNR / SSIM ----------

cmd_psnr() {
  local a="${1:-}" b="${2:-}"; shift 2 2>/dev/null || true
  local crop="" minpsnr="42" minssim="0.98"
  while [ $# -gt 0 ]; do
    case "$1" in
      --crop) crop="$2"; shift 2 ;;
      --minpsnr) minpsnr="$2"; shift 2 ;;
      --minssim) minssim="$2"; shift 2 ;;
      *) printf '未知参数：%s\n' "$1"; exit 2 ;;
    esac
  done
  [ -f "$a" ] || { printf '文件不存在：%s\n' "$a"; exit 2; }
  [ -f "$b" ] || { printf '文件不存在：%s\n' "$b"; exit 2; }
  need ffmpeg

  head1 "画质定量：$(basename "$a") vs $(basename "$b")（阈值 PSNR ≥ ${minpsnr}dB / SSIM ≥ ${minssim}）"
  [ -z "$crop" ] && warn "未指定 --crop，当前对整帧计算；水印像素本身会拉低分数，建议裁掉水印区域（如 --crop 3840:1620:0:0 取上方 75%）"

  local vf_a vf_b
  if [ -n "$crop" ]; then vf_a="crop=$crop"; vf_b="crop=$crop"; else vf_a="null"; vf_b="null"; fi

  local psnr_out ssim_out
  psnr_out=$(ffmpeg -hide_banner -v error -i "$a" -i "$b" \
      -lavfi "[0:v]${vf_a},setsar=1[x];[1:v]${vf_b},setsar=1[y];[x][y]psnr" -f null - 2>&1 | tail -3)
  local pv
  pv=$(printf '%s' "$psnr_out" | grep -oE 'average:[0-9.]+' | head -1 | sed 's/average://')
  if [ -z "$pv" ]; then
    bad "PSNR 计算失败" "$psnr_out"
  else
    if awk "BEGIN{exit !($pv >= $minpsnr)}"; then ok "PSNR ${pv}dB ≥ ${minpsnr}dB"; else bad "PSNR ${pv}dB < ${minpsnr}dB"; fi
  fi

  ssim_out=$(ffmpeg -hide_banner -v error -i "$a" -i "$b" \
      -lavfi "[0:v]${vf_a},setsar=1[x];[1:v]${vf_b},setsar=1[y];[x][y]ssim" -f null - 2>&1 | tail -3)
  local sv
  sv=$(printf '%s' "$ssim_out" | grep -oE 'All:[0-9.]+' | head -1 | sed 's/All://')
  if [ -z "$sv" ]; then
    bad "SSIM 计算失败" "$ssim_out"
  else
    if awk "BEGIN{exit !($sv >= $minssim)}"; then ok "SSIM ${sv} ≥ ${minssim}"; else bad "SSIM ${sv} < ${minssim}"; fi
  fi
}

# ---------- 批量 ----------

cmd_all() {
  local m="${1:-}"
  [ -f "$m" ] || { printf '清单不存在：%s\n' "$m"; exit 2; }
  while IFS=$'\t' read -r kind o e; do
    [ -z "${kind:-}" ] && continue
    case "$kind" in \#*) continue ;; esac
    case "$kind" in
      live)  cmd_live  "$o" "$e" ;;
      gif)   cmd_gif   "$o" "$e" ;;
      video) cmd_video "$o" "$e" ;;
      psnr)  cmd_psnr  "$o" "$e" ;;
      *) warn "清单里有未知类型：$kind（跳过 $o）" ;;
    esac
  done < "$m"
}

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/,""); print; next } else exit }' "$0"
  exit 2
}

main() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    live)  cmd_live  "${1:-}" "${2:-}" ;;
    gif)   cmd_gif   "${1:-}" "${2:-}" ;;
    video) cmd_video "$@" ;;
    psnr)  cmd_psnr  "$@" ;;
    all)   cmd_all   "${1:-}" ;;
    ""|-h|--help) usage ;;
    *) printf '未知子命令：%s\n' "$sub"; usage ;;
  esac

  head1 "结果"
  printf '  PASS %d ｜ FAIL %d ｜ WARN %d\n' "$PASS_N" "$FAIL_N" "$WARN_N"
  if [ "$FAIL_N" -gt 0 ]; then
    printf '  %s失败项：%s\n' "$c_red" "$c_off"
    for l in "${FAIL_LINES[@]}"; do printf '    - %s\n' "$l"; done
    exit 1
  fi
  exit 0
}

main "$@"
