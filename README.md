# 二十四小时不间断直播推流
在荒岛博客《<a href="https://lala.im/4816.html" target="_blank">FFmpeg循环推流脚本</a>》的代码基础上结合<a href="https://www.youtube.com/@AkilaZhang" target="_blank">电丸科技AK</a>的视频（https://www.youtube.com/watch?v=Ko20sPb93fo ）修改而成，方便个人使用而已。
## 使用方法
1、新建视频文件夹，并上传你想直播的视频（FTP或其他方法，我用的<a href="http://www.hostbuf.com/t/988.html" target="_blank">FinalShell</a>很好用。）自己动手使用Rclone挂载GoogleDrive或OneDrive也可以：
```
mkdir /home/Videos
```
2、安装依赖应用
CentOS
```
yum -y install screen wget
```
Ubuntu/Debian
```
apt-get -y install screen wget
```
2、下载live.sh并赋权，以下需要root权限使用，具体可输入su并输入密码即可：
```
wget -N https://raw.githubusercontent.com/KuwiNet/Live/main/live.sh
chmod 755 /root/live.sh
```
3、运行live.sh安装FFmpeg，选择1安装FFmpeg。
```
./live.sh
```
4、新建窗口，准备直播推流，再次运行live.sh，选择2，按提示操作就好，<b>每次推流使用下方代码</b>。
```
screen -S live
./live.sh
```
### 注意事项
a. 修改推流码率，live.sh第59(加水印)或70(不加水印)行里的3000k和92k两处，3000k是视频码率，92k是音频码率，根据自己的服务器情况修改即可。</br>
b. 解放本地电脑，新建ssh连接(必须)，使用FinalShell可随时关闭窗口，不会中断推流：
```screen -ls```
查看推流窗口</br>
脱离的窗口，2843.live表示要脱离的窗口，根据上述查看结果写
```
screen -d 2843.live
```
c. 关闭推流进程，可运行live.sh，也可下方代码
```
screen -X -S 2843.live quit
```
