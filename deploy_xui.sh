#!/bin/bash

# ==========================================
# 1. 预先收集用户输入信息
# ==========================================
clear
echo "=== 3x-ui 自动部署与配置脚本 (All-in-One 终极版) ==="
read -p "请输入您的专属域名 (需托管在 Cloudflare): " MY_DOMAIN
read -p "请输入 Cloudflare API Token (CF_Token): " CF_TOKEN
read -p "请输入 Cloudflare 账户 ID (CF_Account_ID): " CF_ACCOUNT_ID
read -p "请输入 3x-ui 面板登录账号: " PANEL_USER
read -p "请输入 3x-ui 面板登录密码: " PANEL_PASS
PANEL_PORT=20742

# REALITY 伪装目标设置 (固定为 iCloud)
REALITY_DEST="www.icloud.com:443"
REALITY_SNI="www.icloud.com\",\"icloud.com"

# ==========================================
# 2. 安装基础依赖
# ==========================================
echo -e "\n---> [1/6] 正在安装基础依赖 (curl, socat, sqlite3)..."
apt-get update -y
apt-get install -y curl socat sqlite3 openssl

# ==========================================
# 3. 无人值守安装 3x-ui
# ==========================================
echo -e "\n---> [2/6] 开始安装 3x-ui 面板..."
# 通过 printf 预填安装参数，跳过交互式暂停
printf "y\n${PANEL_PORT}\n${PANEL_USER}\n${PANEL_PASS}\n" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# ==========================================
# 4. 安装 Acme.sh 并申请证书
# ==========================================
echo -e "\n---> [3/6] 开始安装 Acme.sh 并通过 DNS API 申请证书..."
# 安装 Acme.sh
curl https://get.acme.sh | sh
ACME_BIN=~/.acme.sh/acme.sh

# 设置默认 CA 为 Let's Encrypt (相对稳定)
$ACME_BIN --set-default-ca --server letsencrypt

# 注入 Cloudflare 凭证
export CF_Token="$CF_TOKEN"
export CF_Account_ID="$CF_ACCOUNT_ID"

# 申请证书
$ACME_BIN --issue --dns dns_cf -d "${MY_DOMAIN}" -d "*.${MY_DOMAIN}"

# 创建 x-ui 专属证书存放目录
mkdir -p /etc/x-ui/cert

# 安装证书，并强制绑定 x-ui 的续期重启钩子
echo -e "\n---> [4/6] 部署证书并配置自动续期重启钩子..."
$ACME_BIN --install-cert -d "${MY_DOMAIN}" \
    --key-file       /etc/x-ui/cert/server.key  \
    --fullchain-file /etc/x-ui/cert/server.crt \
    --reloadcmd      "x-ui restart"

# ==========================================
# 5. 修改面板数据库，开启 HTTPS
# ==========================================
echo -e "\n---> [5/6] 正在将面板切换为 HTTPS 访问..."
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '/etc/x-ui/cert/server.crt' WHERE key = 'webCertFile';"
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '/etc/x-ui/cert/server.key' WHERE key = 'webKeyFile';"

# ==========================================
# 6. 配置 VLESS + REALITY 入站 (通过 API)
# ==========================================
echo -e "\n---> [6/6] 正在生成 REALITY 密钥并注入 VLESS 节点..."

XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
KEYS=$($XRAY_BIN x25519)
PRI_KEY=$(echo "$KEYS" | sed -nE 's/.*Private[ Kk]ey:[[:space:]]*([^[:space:]]+).*/\1/p')
PUB_KEY=$(echo "$KEYS" | sed -nE 's/.*(Public key:|Password:)[[:space:]]*([^[:space:]]+).*/\2/p')
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

# 重启面板以加载新的 HTTPS 证书，并确保 API 服务正常
x-ui restart
sleep 4 # 等待面板完全启动

# 1. 登录本地面板获取 Cookie (现在本地调用依然走 127.0.0.1 的 HTTP)
curl -s -c cookie.txt -d "username=${PANEL_USER}&password=${PANEL_PASS}" -X POST http://127.0.0.1:${PANEL_PORT}/login > /dev/null

# 2. 构造 VLESS + REALITY (iCloud) 的 JSON Payload
API_PAYLOAD=$(cat <<EOF
{
  "up": 0,
  "down": 0,
  "total": 0,
  "remark": "VLESS-Reality-iCloud",
  "enable": true,
  "expiryTime": 0,
  "listen": "",
  "port": 443,
  "protocol": "vless",
  "settings": "{\\"clients\\":[{\\"id\\":\\"${UUID}\\",\\"flow\\":\\"xtls-rprx-vision\\"}],\\"decryption\\":\\"none\\",\\"fallbacks\\":[]}",
  "streamSettings": "{\\"network\\":\\"tcp\\",\\"security\\":\\"reality\\",\\"realitySettings\\":{\\"show\\":false,\\"xver\\":0,\\"dest\\":\\"${REALITY_DEST}\\",\\"serverNames\\":[\\"${REALITY_SNI}\\"],\\"privateKey\\":\\"${PRI_KEY}\\",\\"minClientVer\\":\\"\\",\\"maxClientVer\\":\\"\\",\\"maxTimeDiff\\":0,\\"shortIds\\":[\\"${SHORT_ID}\\"]},\\"tcpSettings\\":{\\"acceptProxyProtocol\\":false,\\"header\\":{\\"type\\":\\"none\\"}}}",
  "sniffing": "{\\"enabled\\":true,\\"destOverride\\":[\\"http\\",\\"tls\\",\\"quic\\"],\\"routeOnly\\":false}",
  "allocate": "{\\"strategy\\":\\"always\\",\\"refresh\\":5,\\"concurrency\\":3}"
}
EOF
)

# 3. 调用 API 添加入站
curl -s -b cookie.txt -H "Accept: application/json" -H "Content-Type: application/json" -X POST http://127.0.0.1:${PANEL_PORT}/panel/api/inbounds/add -d "$API_PAYLOAD" > /dev/null

# 收尾工作
rm -f cookie.txt
x-ui restart

echo -e "\n=========================================="
echo -e "部署完成！🎉"
echo -e "面板地址: https://${MY_DOMAIN}:${PANEL_PORT}"
echo -e "面板账号: ${PANEL_USER}"
echo -e "面板密码: ${PANEL_PASS}"
echo -e "=========================================="
echo -e "已自动创建 VLESS+REALITY 节点，伪装目标为 iCloud。"
echo -e "REALITY Public Key: ${PUB_KEY}"
echo -e "=========================================="

