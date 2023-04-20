#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
#=================================================================#
#   System Required: CentOS/Debian/Ubuntu/Fedora (32bit/64bit)    #
#   Description: FFmpeg Stream Media Server                       #
#   Author: LALA          Mender：KuwiNet                         #
#   Website: https://www.lala.im                                  #
#            https://kuwi.net                                     #
#=================================================================#

# 颜色选择
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
font="\033[0m"

ffmpeg_install(){
# 安装FFMPEG
read -p "你的机器内是否已经安装过FFmpeg4.x?安装FFmpeg才能正常推流,是否现在安装FFmpeg?(yes[y]/no[n]):" Choose
if [ $Choose = "y" ];then
	wget --no-check-certificate https://www.johnvansickle.com/ffmpeg/old-releases/ffmpeg-4.0.3-64bit-static.tar.xz
	tar -xJf ffmpeg-4.0.3-64bit-static.tar.xz
	cd ffmpeg-4.0.3-64bit-static
	mv ffmpeg /usr/bin && mv ffprobe /usr/bin && mv qt-faststart /usr/bin && mv ffmpeg-10bit /usr/bin
fi
if [ $Choose = "n" ]
then
    echo -e "${yellow} 你选择不安装FFmpeg,请确定你的机器内已经自行安装过FFmpeg,否则程序无法正常工作! ${font}"
    sleep 2
fi
	}

stream_start(){
# 定义推流地址和推流码
read -p "输入你的推流地址和推流码(rtmp协议):" rtmp

# 判断用户输入的地址是否合法
if [[ $rtmp =~ "rtmp://" ]];then
	echo -e "${green} 推流地址输入正确,程序将进行下一步操作. ${font}"
  	sleep 2
	else  
  	echo -e "${red} 你输入的地址不合法,请重新运行程序并输入! ${font}"
  	exit 1
fi 

# 定义视频存放目录
read -p "输入你的视频存放目录 (格式仅支持mp4,并且要绝对路径,例如/opt/video):" folder

# 判断是否需要添加水印
read -p "是否需要为视频添加水印?水印位置默认在右上方,需要较好CPU支持(yes[y]/no[n]):" watermark
if [ $watermark = "y" ];then
	read -p "输入你的水印图片存放绝对路径,例如/opt/image/watermark.jpg (格式支持jpg/png/bmp):" image
	echo -e "${yellow} 添加水印完成,程序将开始推流. ${font}"
	# 循环
	while true
	do
		cd $folder
		video=$(find ./ -type f | shuf -n 1)
		ffmpeg -re -i "$video" -i "$image" -filter_complex overlay=W-w-5:5 -c:v 3000k -c:a aac -b:a 92k -strict -2 -f flv ${rtmp}
	done
fi
if [ $watermark = "n" ]
then
    echo -e "${yellow} 你选择不添加水印,程序将开始推流. ${font}"
    # 循环
	while true
	do
		cd $folder
		video=$(find ./ -type f | shuf -n 1)
  ffmpeg -re -i "$video" -preset ultrafast -vcodec libx264 -g 60 -b:v 3000k -c:a aac -b:a 92k -strict -2 -f flv ${rtmp}
 done
fi
 }

#查看推流进程
stream_ls(){
	screen -ls
	}

# 停止推流
stream_stop(){
	screen -S live -X quit
	killall ffmpeg
	}

# 开始菜单设置
echo -e "${yellow} 7×24 全天候不间断无人值守循环直播推流 ${font}"
echo -e "${yellow} 适用于CentOS/Debian/Ubuntu/Fedora (32bit/64bit) ${font}"
echo -e "${yellow} LALA 编写    KuwiNet 修改 ${font}"
echo -e "${red} 请确定此脚本目前是在screen窗口内运行的! ${font}"
echo -e "${green} 1.安装FFmpeg (机器要安装FFmpeg才能正常推流) ${font}"
echo -e "${green} 2.开始无人值守循环推流 ${font}"
echo -e "${green} 3.查看推流进程 ${font}"
echo -e "${green} 4.停止推流 ${font}"
start_menu(){
    read -p "请输入数字(1-4),选择你要进行的操作:" num
    case "$num" in
        1)
        ffmpeg_install
        ;;
        2)
        stream_start
        ;;
	3)
        stream_ls
        ;;
        4)
        stream_stop
        ;;
        *)
        echo -e "${red} 请输入正确的数字 (1-3) ${font}"
        ;;
    esac
	}

# 运行开始菜单
start_menu
