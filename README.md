# 7×24 全天候不间断无人值守循环直播推流

在荒岛博客《FFmpeg 循环推流脚本》的代码基础上，结合电丸科技 AK 的视频（[https://www.youtube.com/watch?v=Ko20sPb93fo](https://www.youtube.com/watch?v=Ko20sPb93fo)）修改而成，方便个人使用。

> v2 版本已重构为「配置 + systemd 托管」模式：不再需要手动改脚本里的码率行，不再依赖 
>
> `killall`
>
>  停进程，支持 rtmps /srt 推流，异常自动重试。旧版本仍可通过 
>
> `git log`
>
>  查看。

## 一、准备



1. 上传视频到服务器目录（FTP / SFTP / FinalShell 均可），或自行用 Rclone 挂载网盘：



```
mkdir -p /opt/video
```



1. 安装基础工具：

Debian / Ubuntu



```
apt-get update && apt-get install -y wget curl screen
```

Rocky / AlmaLinux /openEuler（CentOS 7 已 EOL，不建议再用）



```
dnf install -y wget curl screen
```

## 二、下载并安装

国外服务器



```
wget -O /root/live.sh https://raw.githubusercontent.com/KuwiNet/Live/main/live.sh
chmod 755 /root/live.sh
```

国内服务器（Gitee 镜像）



```
wget -O /root/live.sh https://gitee.com/kuwinet/live/raw/main/live.sh
chmod 755 /root/live.sh
```

安装 FFmpeg（脚本会自动选包管理器，无可用包时回退到 johnvansickle 静态包）：



```
/root/live.sh setup
```

需要新版 FFmpeg 时用静态包（推荐，已经是当前最新的 9.0 稳定分支）：



```
/root/live.sh setup static          # BtbN 9.0 GPL 静态包（默认）
/root/live.sh setup static master   # 每夜构建，最激进，出问题可换回 9.0
```

各来源的版本对照：



| 来源 | 版本 | 说明 |
| --- | --- | --- |
| Debian 12 源 | 5.1 | 够用，最省事 |
| Debian 13 / Ubuntu 24.04 源 | 7.1 / 6.1 | 较新 |
| BtbN 静态包 `static` | 9.0（当前 n9.0.2） | 自带 x264、libsrt、nvenc；要求 glibc ≥ 2.28、内核 ≥ 4.18 |
| johnvansickle 静态包 | 7.0.2 | 适合 CentOS 7 等老系统（glibc 2.17），但静态链接 glibc 会丢 DNS 解析，需装 nscd |

脚本的编码参数在 5.x ~ 9.0 上均可用（已用 9.0.2 实测无缩放、缩放归一化、水印、无音轨素材四种情况）。
装完用 `which -a ffmpeg` 确认生效的是 `/usr/local/bin/ffmpeg` 还是系统旧版本；如果仍是旧版本，说明 PATH 里 `/usr/local/bin` 不在前面。

## 三、写配置（推荐方式）



```
/root/live.sh config
```

按提示填入推流地址、视频目录、码率等，脚本会把配置写到 `/etc/live.conf` 并设为 `600` 权限（内含推流码，注意别外泄、别提交到仓库）。

也可以手动复制模板：



```
cp live.conf.example /etc/live.conf
chmod 600 /etc/live.conf
vi /etc/live.conf
```

常用项说明：



| 配置项                               | 说明                                             |
| --------------------------------- | ---------------------------------------------- |
| `STREAM_URL`                      | 推流地址，支持 `rtmp://` `rtmps://` `srt://` `udp://` |
| `VIDEO_DIR`                       | 视频目录，绝对路径                                      |
| `VIDEO_BITRATE` / `AUDIO_BITRATE` | 码率，默认 `6000k` / `192k`，按上行带宽调整                 |
| `HEIGHT` / `FPS`                  | 统一输出分辨率 / 帧率，素材杂乱时建议设 `720` / `30`             |
| `ORDER`                           | `random`（每轮随机）或 `name`（按文件名顺序）                 |
| `WATERMARK_IMAGE`                 | 水印图片路径，留空不加                                    |
| `ENCODER`                         | 编码器：`libx264`（默认）/ `h264_nvenc` / `h264_qsv` / `h264_vaapi` |
| `NVENC_PRESET` / `NVENC_RC`       | NVENC 用，`p1`~`p7` / `cbr`·`vbr`                 |
| `VAAPI_DEVICE`                    | VAAPI 用，默认 `/dev/dri/renderD128`               |
| `LOG_FILE`                        | 日志路径，留空则进 systemd journal                      |

## 四、运行

### 方式 A：systemd 托管（推荐，开机自启 + 崩溃自动拉起）



```
/root/live.sh service      # 自动安装到 /usr/local/bin 并注册服务
systemctl start live
systemctl status live
journalctl -u live -f      # 实时日志
```

### 方式 B：screen 会话（临时调试）



```
/root/live.sh daemon       # 在 screen 会话 live 中后台启动
screen -r live             # 进入查看，Ctrl-A D 脱离
```

### 方式 C：前台运行（自己看着日志）



```
/root/live.sh start
```

## 五、运维命令



```
/root/live.sh status       # 运行状态、子进程、screen/systemd 情况
/root/live.sh stop         # 停止（只停自己这个实例，不会 kill 别人的 ffmpeg）
```

## 六、注意事项



* **推流码即密码**：`live.conf` 权限保持 `600`，不要截图、不要提交到仓库；日志里推流码已被掩码成 `****`。

* **码率**：`6000k` 适合 1080p 平台默认画质，上行带宽不足时下调到 `3000k` 或 `4000k`，否则必卡。

* **CPU / 硬件加速**：默认 `libx264` 软编，低配机器把 `PRESET` 调成 `ultrafast`。有独显或核显时改 `ENCODER` 即可，脚本已按编码器自动切换对应参数（不会把 `-preset veryfast`、`-tune zerolatency` 这类 x264 参数硬塞给 NVENC）：



```
# NVIDIA 独显（需驱动 + ffmpeg 含 nvenc，BtbN 静态包自带）
ENCODER="h264_nvenc"
NVENC_PRESET="p4"          # p1 最快 / p7 画质最好
NVENC_RC="cbr"

# Intel 核显
ENCODER="h264_qsv"
PRESET="veryfast"

# Linux 上 AMD/Intel 走 VAAPI（脚本会自动加 format=nv12,hwupload）
ENCODER="h264_vaapi"
VAAPI_DEVICE="/dev/dri/renderD128"
```

启动时若编码器不可用（没装驱动 / ffmpeg 未编译该编码器），配置校验会直接报出来，不会等到推流跑起来才发现。

* **素材一致性**：不同分辨率 / 帧率混播容易触发平台断流重建，建议 `HEIGHT=720`、`FPS=30` 统一输出。

* **磁盘**：长期运行建议开启 `LOG_FILE` 并配合 logrotate；脚本在日志超过 100MB 时会自动轮转一次。

* **无音轨素材**：脚本用 `-map 0:a:0?` 兼容无音轨文件，但部分平台要求必须有音轨，建议素材统一带 AAC 音轨。