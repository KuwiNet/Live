#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#======================= 功能配置 =======================
RTMP_URL=""                # 推流地址
VIDEO_DIR=""               # 视频目录路径
WATERMARK_IMG=""           # 水印图片路径
CRF=23                     # 视频质量(18-28)
PRESET="fast"              # 编码速度预设
AUDIO_BITRATE="128k"       # 音频比特率
SCREEN_NAME="FFmpegStream" # 进程名称

#======================= 颜色定义 =======================
RED='\033[31m'    GREEN='\033[1;32m'
YELLOW='\033[33m' RESET='\033[0m'

#======================= 功能函数 =======================
install_ffmpeg() {
    if command -v ffmpeg &>/dev/null; then
        echo -e "${GREEN}检测到已安装FFmpeg: $(ffmpeg -version | head -n1)${RESET}"
        return 0
    fi

    echo -e "${YELLOW}正在安装FFmpeg...${RESET}"
    if grep -Eq "ubuntu|debian" /etc/os-release; then
        sudo apt update && sudo apt install -y ffmpeg
    elif grep -q "centos" /etc/os-release; then
        sudo yum install -y epel-release
        sudo yum install -y ffmpeg ffmpeg-devel
    else
        echo -e "${RED}不支持的Linux发行版，请手动安装FFmpeg${RESET}"
        return 1
    fi

    if ! command -v ffmpeg &>/dev/null; then
        echo -e "${RED}FFmpeg安装失败，请手动安装后重试${RESET}"
        return 1
    fi
}

validate_input() {
    [[ "$RTMP_URL" =~ ^rtmp:// ]] || { echo -e "${RED}推流地址必须以rtmp://开头${RESET}"; return 1; }
    [ -d "$VIDEO_DIR" ] || { echo -e "${RED}视频目录不存在或不可访问${RESET}"; return 1; }
    find "$VIDEO_DIR" -maxdepth 1 -name '*.mp4' | grep -q . || { echo -e "${RED}视频目录中未找到MP4文件${RESET}"; return 1; }
    [ -z "$WATERMARK_IMG" ] || [ -f "$WATERMARK_IMG" ] || { echo -e "${RED}水印图片文件不存在${RESET}"; return 1; }
}

generate_filter() {
    local filter=""
    [ -n "$WATERMARK_IMG" ] && filter="[1]format=rgba,colorchannelmixer=aa=0.5[wm];[0][wm]overlay=W-w-20:20"
    echo "$filter"
}

start_stream() {
    local filter_complex=$(generate_filter)
    local ffmpeg_cmd=(
        ffmpeg -loglevel warning -stats_period 60
        -re -f concat -safe 0 -i <(find "$VIDEO_DIR" -name '*.mp4' -printf "file '%p'\n" | shuf)
        -i "$WATERMARK_IMG"
        -filter_complex "$filter_complex"
        -c:v libx264 -crf "$CRF" -preset "$PRESET" -g 60
        -c:a aac -b:a "$AUDIO_BITRATE" -ar 44100
        -f flv "$RTMP_URL"
    )

    screen -dmS "$SCREEN_NAME" bash -c \
        "while true; do
            ${ffmpeg_cmd[@]} || { echo '推流中断，60秒后重试...'; sleep 60; }
         done"
}

stop_stream() {
    screen -ls | grep -q "\.$SCREEN_NAME\s" && {
        screen -S "$SCREEN_NAME" -X quit
        echo -e "${GREEN}已停止推流进程${RESET}"
    } || echo -e "${YELLOW}未找到运行中的推流进程${RESET}"
}

#======================= 主菜单 =======================
main_menu() {
    echo -e "${GREEN}
    ███████╗███████╗███╗   ███╗██████╗ ███████╗ ██████╗ 
    ██╔════╝██╔════╝████╗ ████║██╔══██╗██╔════╝██╔════╝ 
    █████╗  █████╗  ██╔████╔██║██████╔╝█████╗  ██║      
    ██╔══╝  ██╔══╝  ██║╚██╔╝██║██╔═══╝ ██╔══╝  ██║      
    ██║     ███████╗██║ ╚═╝ ██║██║     ███████╗╚██████╗ 
    ╚═╝     ╚══════╝╚═╝     ╚═╝╚═╝     ╚══════╝ ╚═════╝ 
    ${RESET}"

    PS3="请选择操作 (1-5): "
    options=("启动推流" "停止推流" "安装FFmpeg" "查看进程" "退出")
    
    select opt in "${options[@]}"; do
        case $opt in
            "启动推流")
                read -p "输入推流地址 (rtmp://): " RTMP_URL
                read -p "输入视频目录路径: " VIDEO_DIR
                read -p "输入水印图片路径 (留空跳过): " WATERMARK_IMG
                if validate_input; then
                    start_stream
                    echo -e "${GREEN}推流已启动，使用 screen -r ${SCREEN_NAME} 查看运行状态${RESET}"
                fi
                ;;
            "停止推流") stop_stream ;;
            "安装FFmpeg") install_ffmpeg ;;
            "查看进程") screen -ls | grep --color=always "$SCREEN_NAME" || echo "无运行进程" ;;
            "退出") exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}" ;;
        esac
    done
}

#======================= 脚本入口 =======================
[ "$UID" -eq 0 ] && echo -e "${YELLOW}警告：不建议使用root用户运行${RESET}"
main_menu
