#!/usr/bin/env bash
# =================================================================
#  live.sh — 7×24 无人值守循环直播推流（v2 重构版）
#
#  原始来源: lala.im 的 FFmpeg 循环推流脚本 / KuwiNet 修改版
#  v2 目标: 修复健壮性与安全问题，支持配置文件 + systemd 托管
#
#  用法:
#    ./live.sh              交互菜单
#    ./live.sh config       生成配置文件（交互向导）
#    ./live.sh setup        安装 / 更新 FFmpeg
#    ./live.sh start        前台开始推流（交给 systemd 或 screen 使用）
#    ./live.sh stop         停止推流
#    ./live.sh status       查看运行状态
#    ./live.sh service      安装并启用 systemd 服务
#    ./live.sh help         帮助
#
#  配置文件查找顺序: $LIVE_CONF → 脚本同目录 live.conf → /etc/live.conf → ~/.live.conf
# =================================================================

set -uo pipefail

SCRIPT_PATH=$(cd -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0")
SCRIPT_DIR=$(dirname -- "$SCRIPT_PATH")
SCRIPT_NAME=$(basename -- "$SCRIPT_PATH")

# ------------------------- 默认配置（可被 live.conf 覆盖） -------------------------
STREAM_URL=""                 # rtmp://... rtmps://... srt://... udp://...
VIDEO_DIR=""                  # 视频目录（绝对路径）
WATERMARK_IMAGE=""            # 水印图片绝对路径，留空=不加
WATERMARK_MARGIN=8            # 水印边距(px)
VIDEO_BITRATE="6000k"         # 视频码率，如 6000k / 8M
AUDIO_BITRATE="192k"
PRESET="veryfast"             # ultrafast/superfast/veryfast/faster
TUNE="zerolatency"
X264_PROFILE="high"
HEIGHT=0                      # 统一输出高度（如 720），0=保持源分辨率
FPS=0                         # 统一输出帧率（如 30），0=跟随源
GOP=0                         # 关键帧间隔，0=自动(FPS*2 或 60)
ORDER="random"                # random=每轮随机打乱 / name=按文件名顺序
MEDIA_DEPTH=1                 # 视频目录递归深度
SLEEP_ON_ERROR=5              # ffmpeg 异常退出后等待秒数
LOGLEVEL="warning"            # quiet/error/warning/info
LOG_FILE=""                   # 日志文件，留空=输出到终端(systemd journal)
CONF_FILE=""

# ------------------------- 输出与日志 -------------------------
if [[ -t 1 ]]; then
	C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_RST=$'\033[0m'
else
	C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
fi

log() {
	local lvl=$1; shift
	local line color
	line="[$(date '+%F %T')][$lvl] $*"
	case $lvl in
		ERR)  color=$C_RED ;;
		WARN) color=$C_YEL ;;
		*)    color=$C_GRN ;;
	esac
	printf '%s%s%s\n' "$color" "$line" "$C_RST" >&2
	if [[ -n ${LOG_FILE:-} ]]; then
		printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
	fi
}

die() { log ERR "$*"; exit 1; }

# ------------------------- 配置加载与校验 -------------------------
load_config() {
	local f
	local -a cands=()
	[[ -n ${LIVE_CONF:-} ]] && cands+=("$LIVE_CONF")
	cands+=("$SCRIPT_DIR/live.conf" "/etc/live.conf" "$HOME/.live.conf")
	for f in "${cands[@]}"; do
		if [[ -f $f ]]; then
			# shellcheck disable=SC1090
			. "$f" || die "配置文件解析失败: $f"
			CONF_FILE=$f
			return 0
		fi
	done
	CONF_FILE=""
	return 1
}

# 掩码推流地址，避免日志/截图泄露推流码
mask_url() {
	local u=$1 base
	case $u in
		*'?'*) base=${u%%\?*} ;;
		*)     base=$u ;;
	esac
	printf '%s' "$base" | awk -F'/' '{ if (NF >= 4) printf "%s//%s/%s/****", $1, $3, $4; else print $0 }'
}

is_valid_url() {
	case ${1:-} in
		rtmp://?*|rtmps://?*|srt://?*|udp://?*) return 0 ;;
		*) return 1 ;;
	esac
}

is_valid_bitrate() { [[ ${1:-} =~ ^[0-9]+[kKmM]?$ ]]; }

check_config() {
	local ok=1
	if ! command -v ffmpeg >/dev/null 2>&1; then
		log ERR "未找到 ffmpeg，请先执行: $SCRIPT_NAME setup"
		ok=0
	fi
	if ! is_valid_url "$STREAM_URL"; then
		log ERR "STREAM_URL 不合法(需 rtmp:// rtmps:// srt:// udp:// 开头): ${STREAM_URL:-<空>}"
		ok=0
	fi
	if [[ -z ${VIDEO_DIR:-} || ! -d $VIDEO_DIR ]]; then
		log ERR "VIDEO_DIR 不存在或未设置: ${VIDEO_DIR:-<空>}"
		ok=0
	fi
	if [[ -n ${WATERMARK_IMAGE:-} && ! -f $WATERMARK_IMAGE ]]; then
		log ERR "水印文件不存在: $WATERMARK_IMAGE"
		ok=0
	fi
	is_valid_bitrate "$VIDEO_BITRATE" || { log ERR "VIDEO_BITRATE 格式错误: $VIDEO_BITRATE"; ok=0; }
	is_valid_bitrate "$AUDIO_BITRATE" || { log ERR "AUDIO_BITRATE 格式错误: $AUDIO_BITRATE"; ok=0; }
	[[ $ORDER == random || $ORDER == name ]] || { log ERR "ORDER 只能是 random 或 name"; ok=0; }
	[[ $MEDIA_DEPTH =~ ^[0-9]+$ ]] || { log ERR "MEDIA_DEPTH 必须是数字"; ok=0; }
	[[ $HEIGHT =~ ^[0-9]+$ ]] || { log ERR "HEIGHT 必须是 0 或正整数"; ok=0; }
	[[ $FPS =~ ^[0-9]+$ ]] || { log ERR "FPS 必须是 0 或正整数"; ok=0; }
	[[ $GOP =~ ^[0-9]+$ ]] || { log ERR "GOP 必须是 0 或正整数"; ok=0; }
	[[ $ok == 1 ]]
}

# ------------------------- 视频清单 -------------------------
FILES=()

collect_files() {
	FILES=()
	local f found=0
	while IFS= read -r -d '' f; do
		FILES+=("$f")
	done < <(
		find "$VIDEO_DIR" -maxdepth "$MEDIA_DEPTH" -type f \
			\( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' \
			   -o -iname '*.flv' -o -iname '*.ts' -o -iname '*.webm' \
			   -o -iname '*.m4v' \) -print0 2>/dev/null
	)
	if [[ $ORDER == name && ${#FILES[@]} -gt 0 ]]; then
		FILES=()
		while IFS= read -r -d '' f; do
			FILES+=("$f")
		done < <(
			find "$VIDEO_DIR" -maxdepth "$MEDIA_DEPTH" -type f \
				\( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' \
				   -o -iname '*.flv' -o -iname '*.ts' -o -iname '*.webm' \
				   -o -iname '*.m4v' \) -print0 2>/dev/null | sort -z
		)
	fi
	return 0
}

shuffle_files() {
	local n=${#FILES[@]} i j tmp
	(( n < 2 )) && return 0
	for (( i = n - 1; i > 0; i-- )); do
		j=$(( RANDOM % (i + 1) ))
		tmp=${FILES[i]}
		FILES[i]=${FILES[j]}
		FILES[j]=$tmp
	done
}

# ------------------------- 构造 ffmpeg 参数 -------------------------
FF=()

build_ffmpeg_args() {
	local file=$1 vf="" filters="" gop=$GOP
	local has_wm=0 unit bnum bufsize

	FF=(ffmpeg -hide_banner -nostdin -loglevel "$LOGLEVEL" -re -i "$file")

	if [[ -n ${WATERMARK_IMAGE:-} ]]; then
		FF+=(-i "$WATERMARK_IMAGE")
		has_wm=1
	fi

	[[ $HEIGHT -gt 0 ]] && vf="scale=-2:${HEIGHT}:flags=bicubic"
	[[ $FPS -gt 0 ]] && FF+=(-r "$FPS")
	(( gop == 0 )) && { if (( FPS > 0 )); then gop=$(( FPS * 2 )); else gop=60; fi; }

	if (( has_wm == 1 )); then
		local base="[0:v]"
		if [[ -n $vf ]]; then
			filters="[0:v]${vf}[bgv];"
			base="[bgv]"
		fi
		filters+="${base}[1:v]overlay=W-w-${WATERMARK_MARGIN}:${WATERMARK_MARGIN}:eof_action=repeat[vout]"
		FF+=(-filter_complex "$filters" -map "[vout]" -map 0:a:0?)
	elif [[ -n $vf ]]; then
		FF+=(-vf "$vf" -map 0:v:0 -map 0:a:0?)
	else
		FF+=(-map 0:v:0 -map 0:a:0?)
	fi

	unit=${VIDEO_BITRATE//[0-9]/}
	bnum=${VIDEO_BITRATE//[^0-9]/}
	bufsize="$(( bnum * 2 ))${unit}"

	FF+=(
		-c:v libx264 -preset "$PRESET" -tune "$TUNE" -profile:v "$X264_PROFILE"
		-pix_fmt yuv420p -g "$gop" -keyint_min "$gop" -sc_threshold 0
		-b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize "$bufsize"
		-c:a aac -b:a "$AUDIO_BITRATE" -ar 44100 -ac 2
		-flush_packets 1
	)

	case $STREAM_URL in
		srt://*|udp://*) FF+=(-f mpegts) ;;
		*)               FF+=(-f flv) ;;
	esac
	FF+=("$STREAM_URL")
}

# ------------------------- 运行 / 停止 -------------------------
PID_FILE=""
FF_PID=0
running=1

resolve_pid_file() {
	if [[ $EUID -eq 0 ]]; then
		PID_FILE="/run/live.pid"
	else
		PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/live-$(id -u).pid"
	fi
}

already_running() {
	[[ -f $PID_FILE ]] || return 1
	local pid
	pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
	[[ $pid =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null
}

rotate_log() {
	[[ -n ${LOG_FILE:-} && -f $LOG_FILE ]] || return 0
	local size
	size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
	if (( size > 104857600 )); then
		mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
		log INFO "日志已轮转: $LOG_FILE -> $LOG_FILE.1"
	fi
}

stop_ffmpeg() {
	(( FF_PID == 0 )) && return 0
	kill -0 "$FF_PID" 2>/dev/null || { FF_PID=0; return 0; }
	kill "$FF_PID" 2>/dev/null || true
	local i
	for i in 1 2 3 4 5; do
		kill -0 "$FF_PID" 2>/dev/null || break
		sleep 1
	done
	kill -0 "$FF_PID" 2>/dev/null && kill -9 "$FF_PID" 2>/dev/null || true
	FF_PID=0
	return 0
}

on_signal() {
	running=0
	log WARN "收到退出信号，正在停止推流..."
	stop_ffmpeg
	[[ -n $PID_FILE ]] && rm -f "$PID_FILE"
	exit 0
}

run_one() {
	local rc
	if [[ -n ${LOG_FILE:-} ]]; then
		"${FF[@]}" </dev/null >>"$LOG_FILE" 2>&1 &
	else
		"${FF[@]}" </dev/null &
	fi
	FF_PID=$!
	wait "$FF_PID"
	rc=$?
	FF_PID=0
	return $rc
}

cmd_start() {
	load_config
	check_config || die "配置校验未通过，请修正后重试"
	resolve_pid_file
	already_running && die "已有实例在运行 (pid $(cat "$PID_FILE"))，先执行 $SCRIPT_NAME stop"

	mkdir -p "$(dirname -- "$PID_FILE")" 2>/dev/null || true
	printf '%s\n' $$ >"$PID_FILE"
	trap on_signal INT TERM
	rotate_log

	log INFO "推流目标: $(mask_url "$STREAM_URL")"
	log INFO "视频目录: $VIDEO_DIR (深度 $MEDIA_DEPTH, 顺序 $ORDER)"
	[[ -n ${WATERMARK_IMAGE:-} ]] && log INFO "水印: $WATERMARK_IMAGE"

	local f rc
	while (( running == 1 )); do
		collect_files
		if (( ${#FILES[@]} == 0 )); then
			log ERR "目录内没有可推送的视频文件，${SLEEP_ON_ERROR}s 后重试"
			sleep "$SLEEP_ON_ERROR"
			continue
		fi
		[[ $ORDER == random ]] && shuffle_files

		for f in "${FILES[@]}"; do
			(( running == 1 )) || break
			[[ -f $f ]] || continue
			log INFO "▶ $(basename -- "$f")"
			build_ffmpeg_args "$f"
			if run_one; then
				:
			else
				rc=$?
				log WARN "ffmpeg 退出码 $rc，${SLEEP_ON_ERROR}s 后继续下一个"
				sleep "$SLEEP_ON_ERROR"
			fi
		done
	done

	rm -f "$PID_FILE"
	return 0
}

cmd_stop() {
	load_config >/dev/null 2>&1 || true
	resolve_pid_file
	if ! already_running; then
		log WARN "没有正在运行的实例"
		[[ -f $PID_FILE ]] && rm -f "$PID_FILE"
		return 0
	fi
	local pid
	pid=$(cat "$PID_FILE")
	log INFO "停止进程 $pid"
	kill "$pid" 2>/dev/null || true
	local i
	for i in 1 2 3 4 5; do
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
	done
	if kill -0 "$pid" 2>/dev/null; then
		log WARN "进程未响应 TERM，强制结束"
		kill -9 "$pid" 2>/dev/null || true
	fi
	rm -f "$PID_FILE"
	log INFO "已停止"
}

cmd_status() {
	load_config >/dev/null 2>&1 || true
	resolve_pid_file
	[[ -n ${CONF_FILE:-} ]] && log INFO "配置文件: $CONF_FILE"
	if already_running; then
		local pid
		pid=$(cat "$PID_FILE")
		log INFO "运行中 (pid $pid)"
		ps -p "$pid" -o pid=,etime=,args= 2>/dev/null || true
		command -v pgrep >/dev/null 2>&1 && pgrep -P "$pid" -a 2>/dev/null || true
	else
		log WARN "未运行"
	fi
	command -v screen >/dev/null 2>&1 && screen -ls 2>/dev/null | sed -n '/live/p'
	if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/live.service ]]; then
		systemctl is-active live >/dev/null 2>&1 && log INFO "systemd: active" || log INFO "systemd: $(systemctl is-active live 2>/dev/null)"
	fi
}

# ------------------------- 后台 / systemd -------------------------
cmd_daemon() {
	load_config >/dev/null 2>&1 || true
	resolve_pid_file
	already_running && die "已有实例在运行 (pid $(cat "$PID_FILE"))"
	command -v screen >/dev/null 2>&1 || die "未安装 screen：apt-get install -y screen 或直接使用 $SCRIPT_NAME service"
	screen -dmS live "$SCRIPT_PATH" start
	sleep 2
	if screen -ls 2>/dev/null | grep -q '\.live'; then
		log INFO "已在 screen 会话 live 中启动；查看: screen -r live ，脱离: Ctrl-A D"
	else
		die "screen 启动失败，请检查日志"
	fi
}

cmd_service() {
	[[ $EUID -eq 0 ]] || die "安装 systemd 服务需要 root 权限"
	command -v systemctl >/dev/null 2>&1 || die "本机没有 systemd"
	local unit=/etc/systemd/system/live.service
	local exec_path
	exec_path=$SCRIPT_PATH
	if [[ $SCRIPT_DIR != /usr/local/bin && ! -x /usr/local/bin/live.sh ]]; then
		install -m 755 "$SCRIPT_PATH" /usr/local/bin/live.sh
		exec_path=/usr/local/bin/live.sh
		log INFO "已安装脚本到 /usr/local/bin/live.sh"
	fi
	cat >"$unit" <<EOF
[Unit]
Description=Live 7x24 FFmpeg loop streaming
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="$exec_path" start
ExecStop="$exec_path" stop
Restart=always
RestartSec=10
KillMode=mixed
TimeoutStopSec=15
Nice=-5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable live >/dev/null 2>&1 || true
	log INFO "服务已写入 $unit，启动: systemctl start live ；查看: journalctl -u live -f"
}

# ------------------------- FFmpeg 安装 -------------------------
install_static_ffmpeg() {
	local arch url tmp
	arch=$(uname -m)
	case $arch in
		x86_64|amd64)  url="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" ;;
		aarch64|arm64) url="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz" ;;
		*) die "静态包不支持该架构 ($arch)，请用系统包管理器安装 ffmpeg" ;;
	esac
	tmp=$(mktemp -d) || die "无法创建临时目录"
	log INFO "下载静态 FFmpeg ($arch)..."
	if ! (cd "$tmp" && curl -fL --connect-timeout 20 -o ffmpeg.tar.xz "$url"); then
		rm -rf "$tmp"
		die "下载失败，请检查网络后重试"
	fi
	if ! tar -xJf "$tmp/ffmpeg.tar.xz" -C "$tmp"; then
		rm -rf "$tmp"
		die "解压失败"
	fi
	local d
	d=$(find "$tmp" -maxdepth 1 -type d -name 'ffmpeg-*-static' | head -n1)
	[[ -n $d ]] || { rm -rf "$tmp"; die "未找到解压目录"; }
	install -m 755 "$d/ffmpeg" "$d/ffprobe" /usr/local/bin/ 2>/dev/null \
		|| die "安装到 /usr/local/bin 失败（需要 root）"
	rm -rf "$tmp"
	hash -r 2>/dev/null || true
	ffmpeg -version 2>/dev/null | head -n1 || die "安装后 ffmpeg 仍不可用"
}

# 比较版本号：ver_ge 1.2.3 1.0 → 真表示 1.2.3 >= 1.0
ver_ge() {
	local first
	first=$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)
	[[ $first == "$2" ]]
}

# BtbN/FFmpeg-Builds 静态包：每日构建，linux64/linuxarm64，gpl 变体含 x264 + libsrt + nvenc
# 分支参数：9.0（默认，稳定分支）/ 8.1 / master（每夜构建）
install_btbn_ffmpeg() {
	local branch=${1:-9.0} arch asset url tmp finddir glibc_ver
	[[ $EUID -eq 0 ]] || die "安装到 /usr/local/bin 需要 root 权限"
	command -v curl >/dev/null 2>&1 || die "需要 curl：apt-get install -y curl"

	arch=$(uname -m)
	case $arch in
		x86_64|amd64)  arch=linux64 ;;
		aarch64|arm64) arch=linuxarm64 ;;
		*) die "BtbN 静态包只提供 linux64 / linuxarm64，当前架构 $arch 请用系统包管理器安装" ;;
	esac

	glibc_ver=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
	if [[ -n $glibc_ver ]] && ! ver_ge "$glibc_ver" 2.28; then
		log WARN "当前 glibc $glibc_ver 低于 2.28，BtbN 包可能无法运行（CentOS 7/8 老系统请用 setup 走包管理器或 johnvansickle 静态包）"
	fi

	if [[ $branch == master ]]; then
		asset="ffmpeg-master-latest-${arch}-gpl.tar.xz"
	else
		asset="ffmpeg-n${branch}-latest-${arch}-gpl-${branch}.tar.xz"
	fi
	url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/${asset}"

	tmp=$(mktemp -d) || die "无法创建临时目录"
	log INFO "下载 FFmpeg ${branch} 静态包（约 150MB）: $asset"
	if ! curl -fL --connect-timeout 20 --retry 2 -o "$tmp/ffmpeg.tar.xz" "$url"; then
		rm -rf "$tmp"
		die "下载失败，请检查网络: $url"
	fi
	if ! tar -xJf "$tmp/ffmpeg.tar.xz" -C "$tmp"; then
		rm -rf "$tmp"
		die "解压失败"
	fi

	finddir=$(dirname -- "$(find "$tmp" -maxdepth 3 -type f -name ffmpeg | head -n1)")
	[[ -d $finddir ]] || { rm -rf "$tmp"; die "包内未找到 ffmpeg 可执行文件"; }

	install -d /usr/local/bin
	local b
	for b in ffmpeg ffprobe ffplay; do
		[[ -f "$finddir/$b" ]] || continue
		if [[ -x /usr/local/bin/$b ]]; then
			cp -f "/usr/local/bin/$b" "/usr/local/bin/$b.bak-$(date +%Y%m%d)" 2>/dev/null || true
		fi
		install -m 755 "$finddir/$b" "/usr/local/bin/$b" || { rm -rf "$tmp"; die "安装 $b 到 /usr/local/bin 失败"; }
	done
	rm -rf "$tmp"
	hash -r 2>/dev/null || true

	local v
	v=$(ffmpeg -version 2>/dev/null | head -n1)
	[[ -n $v ]] || die "安装后 ffmpeg 无法运行（多半是 glibc 过低）"
	log INFO "已安装: $v"
	log INFO "实际生效: $(command -v ffmpeg)"
	if command -v which >/dev/null 2>&1; then
		log INFO "系统中其他 ffmpeg: $(which -a ffmpeg | tr '\n' ' ')"
		log INFO "如仍是旧版本，请检查 PATH 中 /usr/local/bin 是否在其他 ffmpeg 目录之前"
	fi
}

cmd_setup() {
	local mode=${1:-}

	# 显式要求静态包：setup static [9.0|8.1|master]
	if [[ $mode == static || $mode == latest ]]; then
		install_btbn_ffmpeg "${2:-9.0}"
		return $?
	fi

	if command -v ffmpeg >/dev/null 2>&1; then
		log INFO "已检测到 ffmpeg: $(ffmpeg -version 2>/dev/null | head -n1)"
		read -r -p "是否重新安装/更新? [y/N]: " ans
		[[ ${ans:-n} == [yY] ]] || return 0
	fi
	[[ $EUID -eq 0 ]] || die "安装 FFmpeg 需要 root 权限"

	if command -v apt-get >/dev/null 2>&1; then
		apt-get update -y && apt-get install -y ffmpeg
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y ffmpeg || {
			log WARN "官方源无 ffmpeg，启用 RPM Fusion 后重试..."
			dnf install -y "https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %dist).noarch.rpm" \
				&& dnf install -y ffmpeg
		}
	elif command -v yum >/dev/null 2>&1; then
		yum install -y epel-release >/dev/null 2>&1 || true
		yum install -y ffmpeg || {
			log WARN "yum 源无 ffmpeg，改用静态包"
			install_static_ffmpeg
		}
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-cache ffmpeg
	elif command -v pacman >/dev/null 2>&1; then
		pacman -Sy --noconfirm ffmpeg
	else
		install_static_ffmpeg
	fi

	command -v ffmpeg >/dev/null 2>&1 || die "FFmpeg 安装失败"
	log INFO "FFmpeg 就绪: $(ffmpeg -version 2>/dev/null | head -n1)"

	# 顺带确保 screen 可用（后台模式需要）
	if ! command -v screen >/dev/null 2>&1; then
		log WARN "未安装 screen（仅 systemd 之外的备用后台方式需要）"
	fi
}

# ------------------------- 配置向导 -------------------------
cmd_config() {
	[[ $EUID -eq 0 ]] || log WARN "非 root 运行：配置将保存到 $HOME/.live.conf"
	local target
	if [[ $EUID -eq 0 ]]; then target="/etc/live.conf"; else target="$HOME/.live.conf"; fi
	printf '%s' "配置写入位置 [$target]: "
	read -r ans
	target=${ans:-$target}

	printf '%s' "推流地址(rtmp://host/app/推流码) []: "
	read -r url
	[[ -n $url ]] && STREAM_URL=$url

	printf '%s' "视频目录绝对路径 [/opt/video]: "
	read -r dir
	dir=${dir:-/opt/video}
	[[ -d $dir ]] || log WARN "目录不存在，稍后请自行创建: $dir"
	VIDEO_DIR=$dir

	printf '%s' "水印图片绝对路径(留空=不加水印) []: "
	read -r wm
	WATERMARK_IMAGE=$wm

	printf '%s' "视频码率 [$VIDEO_BITRATE]: "
	read -r vb
	VIDEO_BITRATE=${vb:-$VIDEO_BITRATE}

	printf '%s' "统一输出高度(720/1080, 0=源分辨率) [$HEIGHT]: "
	read -r h
	HEIGHT=${h:-$HEIGHT}

	printf '%s' "播放顺序 random/name [$ORDER]: "
	read -r od
	ORDER=${od:-$ORDER}

	umask 077
	{
		printf '#!/usr/bin/env bash\n'
		printf '# live.sh 配置（含推流码，权限 600，勿提交到仓库）\n'
		printf 'STREAM_URL=%q\n' "$STREAM_URL"
		printf 'VIDEO_DIR=%q\n' "$VIDEO_DIR"
		printf 'WATERMARK_IMAGE=%q\n' "$WATERMARK_IMAGE"
		printf 'WATERMARK_MARGIN=%q\n' "$WATERMARK_MARGIN"
		printf 'VIDEO_BITRATE=%q\n' "$VIDEO_BITRATE"
		printf 'AUDIO_BITRATE=%q\n' "$AUDIO_BITRATE"
		printf 'PRESET=%q\n' "$PRESET"
		printf 'TUNE=%q\n' "$TUNE"
		printf 'X264_PROFILE=%q\n' "$X264_PROFILE"
		printf 'HEIGHT=%q\n' "$HEIGHT"
		printf 'FPS=%q\n' "$FPS"
		printf 'GOP=%q\n' "$GOP"
		printf 'ORDER=%q\n' "$ORDER"
		printf 'MEDIA_DEPTH=%q\n' "$MEDIA_DEPTH"
		printf 'SLEEP_ON_ERROR=%q\n' "$SLEEP_ON_ERROR"
		printf 'LOGLEVEL=%q\n' "$LOGLEVEL"
		printf 'LOG_FILE=%q\n' "$LOG_FILE"
	} >"$target"
	chmod 600 "$target" 2>/dev/null || true
	log INFO "配置已写入 $target (权限 600)"
	log INFO "校验: $SCRIPT_NAME status"
}

usage() {
	cat <<EOF
7×24 无人值守循环直播推流 (v2)

用法: $SCRIPT_NAME [命令]

  (无参数)   交互菜单
  config     生成/覆盖配置文件（含推流码，权限 600）
  setup      安装/更新 FFmpeg（包管理器优先）
  setup static [9.0|8.1|master]
             安装 BtbN 静态包（默认 9.0 稳定分支；
             glibc 需 >= 2.28，含 x264/libsrt/nvenc）
  start      前台开始推流（供 systemd / screen 调用）
  stop       停止推流
  status     查看状态
  daemon     在 screen 会话中后台启动
  service    安装并启用 systemd 服务（需 root）
  help       显示帮助

FFmpeg 版本：系统源通常较旧（Debian 12=5.1、Ubuntu 24.04=6.1），
需要新版请用 setup static（当前 9.0 已实测兼容本脚本参数）。

配置文件: \$LIVE_CONF → $SCRIPT_DIR/live.conf → /etc/live.conf → ~/.live.conf
EOF
}

menu() {
	while true; do
		echo
		printf '%s\n' "=============================================="
		printf '%s\n' " 7×24 无人值守循环直播推流 (v2)"
		printf '%s\n' "=============================================="
		[[ -n ${CONF_FILE:-} ]] && printf '%s\n' " 配置: $CONF_FILE"
		printf '%s\n' "${C_GRN}1. 安装/更新 FFmpeg${C_RST}"
		printf '%s\n' "${C_GRN}2. 开始推流(前台, 建议 systemd 托管)${C_RST}"
		printf '%s\n' "${C_GRN}3. 后台推流(screen)${C_RST}"
		printf '%s\n' "${C_GRN}4. 停止推流${C_RST}"
		printf '%s\n' "${C_GRN}5. 查看状态${C_RST}"
		printf '%s\n' "${C_GRN}6. 安装/启用 systemd 服务${C_RST}"
		printf '%s\n' "${C_GRN}7. 生成/修改配置${C_RST}"
		printf '%s\n' "${C_GRN}8. 安装新版 FFmpeg (BtbN 静态包, glibc>=2.28)${C_RST}"
		printf '%s\n' "${C_GRN}0. 退出${C_RST}"
		printf '%s' "请输入数字 [0-8]: "
		local num
		read -r num
		case ${num:-} in
			1) cmd_setup ;;
			2) cmd_start ;;
			3) cmd_daemon ;;
			4) cmd_stop ;;
			5) cmd_status ;;
			6) cmd_service ;;
			7) cmd_config ;;
			8) install_btbn_ffmpeg 9.0 ;;
			0) exit 0 ;;
			*) printf '%s\n' "${C_RED}请输入 0-8 之间的数字${C_RST}" ;;
		esac
	done
}

# ------------------------- 入口 -------------------------
main() {
	case ${1:-} in
		"")       load_config >/dev/null 2>&1 || true; menu ;;
		config)   load_config >/dev/null 2>&1 || true; cmd_config ;;
		setup)    cmd_setup "${@:2}" ;;
		install)  cmd_setup "${@:2}" ;;
		start)    cmd_start ;;
		stop)     cmd_stop ;;
		status)   cmd_status ;;
		daemon)   cmd_daemon ;;
		service)  cmd_service ;;
		-h|--help|help) usage ;;
		*)        usage; exit 1 ;;
	esac
}

main "$@"
