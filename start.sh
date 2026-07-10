#!/bin/bash

echo "正在安装 ttyd、Filebrowser 和 Cloudflared..."

# 安装 ttyd
sudo apt update -y
sudo apt install snapd -y
sudo snap install ttyd --classic

# 安装 Cloudflared
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-arm64 -O cloudflared
else
    wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-amd64 -O cloudflared
fi
chmod +x cloudflared
sudo mv cloudflared /usr/local/bin/

# 安装 Filebrowser
FILEBROWSER_VERSION="v2.63.18"
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    wget -q https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-arm64-filebrowser.tar.gz -O filebrowser.tar.gz
else
    wget -q https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz -O filebrowser.tar.gz
fi
tar -xzf filebrowser.tar.gz
sudo mv filebrowser /usr/local/bin/
rm filebrowser.tar.gz

# 初始化 Filebrowser 数据库（管理当前工作目录）
FB_ROOT="${FB_ROOT:-$PWD}"
FB_DEFAULT_USER="admin"
FB_DEFAULT_PASS="admin1234567"
filebrowser config init -r "$FB_ROOT" -d /home/runner/filebrowser.db
# 设置默认账号 admin/admin（可在 Web UI 中修改）
filebrowser users add $FB_DEFAULT_USER $FB_DEFAULT_PASS --perm.admin -d /home/runner/filebrowser.db || true

# 停止可能存在的进程
pkill -f ttyd 2>/dev/null || true
pkill -f cloudflared 2>/dev/null || true
pkill -f filebrowser 2>/dev/null || true

# 启动 ttyd（关键：-W 允许写入，直接运行 bash）
echo "启动 ttyd..."
ttyd -p 7681 -W bash &
TTYD_PID=$!

# 等待启动
sleep 3

# 检查 ttyd 是否运行
if ps -p $TTYD_PID > /dev/null; then
    echo "✓ ttyd 启动成功 (PID: $TTYD_PID)"
else
    echo "✗ ttyd 启动失败，尝试重新启动..."
    ttyd -p 7681 -W bash &
    TTYD_PID=$!
    sleep 2
fi

# 检查端口
if netstat -tuln | grep -q ":7681"; then
    echo "✓ ttyd 正在监听端口 7681"
else
    echo "✗ ttyd 未监听端口 7681"
    exit 1
fi

# 启动 Filebrowser（监听 8080）
echo "启动 Filebrowser..."
nohup filebrowser -d /home/runner/filebrowser.db -p 8080 -a 0.0.0.0 > filebrowser.log 2>&1 &
FILEBROWSER_PID=$!
sleep 2

if netstat -tuln | grep -q ":8080"; then
    echo "✓ Filebrowser 正在监听端口 8080 (PID: $FILEBROWSER_PID)"
else
    echo "✗ Filebrowser 未监听端口 8080"
    cat filebrowser.log
fi

# 启动 Cloudflared 隧道（暴露 ttyd 端口 7681）
echo "启动 Cloudflared 隧道（ttyd）..."
nohup cloudflared tunnel --url http://localhost:7681 > cloudflared_ttyd.log 2>&1 &
CLOUDFLARED_TTYD_PID=$!

# 启动 Cloudflared 隧道（暴露 filebrowser 端口 8080）
echo "启动 Cloudflared 隧道（filebrowser）..."
nohup cloudflared tunnel --url http://localhost:8080 > cloudflared_fb.log 2>&1 &
CLOUDFLARED_FB_PID=$!

# 等待隧道建立
echo "等待隧道建立..."
sleep 10

# 获取公共 URL
get_public_url() {
    local logfile="$1"
    local url=""
    for i in {1..10}; do
        if [ -f "$logfile" ]; then
            url=$(grep -o "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" "$logfile" | head -1)
            if [ -n "$url" ]; then
                echo "$url"
                return 0
            fi
        fi
        sleep 2
    done
    echo ""
}

PUBLIC_URL_TTYD=$(get_public_url cloudflared_ttyd.log)
PUBLIC_URL_FB=$(get_public_url cloudflared_fb.log)

# 显示访问信息
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "=================================================="
echo "安装完成！"
echo "=================================================="
echo ""
echo "--- ttyd 网页终端 ---"
echo "本地访问: http://$IP:7681"
if [ -n "$PUBLIC_URL_TTYD" ]; then
    echo "外网访问: $PUBLIC_URL_TTYD"
else
    echo "外网访问: 正在生成... (查看: cat cloudflared_ttyd.log)"
fi
echo ""
echo "--- Filebrowser 文件管理器 ---"
echo "本地访问: http://$IP:8080"
if [ -n "$PUBLIC_URL_FB" ]; then
    echo "外网访问: $PUBLIC_URL_FB"
else
    echo "外网访问: 正在生成... (查看: cat cloudflared_fb.log)"
fi
echo "默认账号: $FB_DEFAULT_USER / $FB_DEFAULT_PASS"
echo "根目录: $FB_ROOT"
echo ""
echo "=================================================="

# 保存进程信息
echo $TTYD_PID > ttyd.pid
echo $FILEBROWSER_PID > filebrowser.pid
echo $CLOUDFLARED_TTYD_PID > cloudflared_ttyd.pid
echo $CLOUDFLARED_FB_PID > cloudflared_fb.pid
