#!/bin/bash

# ==========================================
# 1. 预先收集用户输入信息
# ==========================================
clear
echo "=== 3x-ui 自动化安全部署脚本 (全随机免交互版) ==="
read -p "请输入主域名 (如 example.com，将自动申请泛域名): " MY_DOMAIN
read -p "请输入 Cloudflare API Token (CF_Token): " CF_TOKEN
read -p "请输入 Cloudflare 账户 ID (CF_Account_ID): " CF_ACCOUNT_ID

echo -e "\n--- 面板基础配置 ---"
read -p "请输入面板监听端口 (如 20742): " PANEL_PORT
read -p "请输入面板安全访问路径 (如 /secret/，直接回车则默认为 /): " PANEL_PATH

# 自动生成高强度账号与密码 (替代手动输入)
PANEL_USER="admin_$(openssl rand -hex 3)"
PANEL_PASS="$(openssl rand -base64 12)"

# 规范化路径格式 (确保以 / 开头和结尾)
if [[ -z "$PANEL_PATH" ]]; then
    PANEL_PATH="/"
else
    [[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"
    [[ "$PANEL_PATH" != */ ]] && PANEL_PATH="$PANEL_PATH/"
fi

# REALITY 伪装目标设置
REALITY_DEST="www.icloud.com:443"
REALITY_SNI="www.icloud.com"

# 定义证书存放的标准路径
CERT_DIR="/etc/ssl/certs"

# ==========================================
# 2. 安装基础依赖
# ==========================================
echo -e "\n---> [1/6] 安装基础依赖..."
apt-get update -y
apt-get install -y curl socat openssl

# ==========================================
# 3. 安装 Acme.sh 并申请泛域名证书
# ==========================================
echo -e "\n---> [2/6] 安装 Acme.sh 并申请证书..."
curl -s https://get.acme.sh | sh
ACME_BIN=~/.acme.sh/acme.sh
$ACME_BIN --set-default-ca --server letsencrypt

export CF_Token="$CF_TOKEN"
export CF_Account_ID="$CF_ACCOUNT_ID"

$ACME_BIN --issue --dns dns_cf -d "${MY_DOMAIN}" -d "*.${MY_DOMAIN}"

mkdir -p "$CERT_DIR"
echo -e "\n---> [3/6] 将证书部署至系统标准目录 ${CERT_DIR}..."
$ACME_BIN --install-cert -d "${MY_DOMAIN}" \
    --key-file       "${CERT_DIR}/${MY_DOMAIN}.key"  \
    --fullchain-file "${CERT_DIR}/${MY_DOMAIN}.crt" \
    --reloadcmd      "x-ui restart"

# ==========================================
# 4. 无人值守安装 3x-ui (n 拒绝自定义，0 跳过 SSL)
# ==========================================
echo -e "\n---> [4/6] 正在纯净安装 3x-ui 面板..."
# n: 使用官方默认的随机配置跳过向导
# 0: 在 prompt_and_setup_ssl 环节输入 0，触发兜底退出逻辑，跳过证书申请
printf "n\n0\n" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# ==========================================
# 5. 调用内置 CLI 覆盖所有安全配置
# ==========================================
echo -e "\n---> [5/6] 正在通过 x-ui CLI 注入安全配置与 HTTPS..."

# 覆盖官方生成的随机参数，换成我们自己生成的参数和路径
x-ui setting \
    -username "${PANEL_USER}" \
    -password "${PANEL_PASS}" \
    -port "${PANEL_PORT}" \
    -webBasePath "${PANEL_PATH}"

# 绑定标准目录下的证书
x-ui cert \
    -webCert "${CERT_DIR}/${MY_DOMAIN}.crt" \
    -webCertKey "${CERT_DIR}/${MY_DOMAIN}.key"

# 重启面板以加载 HTTPS 与新凭证
x-ui restart
sleep 4

# ==========================================
# 6. 配置 VLESS + REALITY 入站
# ==========================================
echo -e "\n---> [6/6] 正在生成 REALITY 密钥并注入节点..."

XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
KEYS=$($XRAY_BIN x25519)
PRI_KEY=$(echo "$KEYS" | sed -nE 's/.*Private[ Kk]ey:[[:space:]]*([^[:space:]]+).*/\1/p')
PUB_KEY=$(echo "$KEYS" | sed -nE 's/.*(Public key:|Password:)[[:space:]]*([^[:space:]]+).*/\2/p')
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

BASE_URL="https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"

# 登录面板获取 Cookie (-k 忽略本地自签名证书验证)
curl -k -s -c cookie.txt -d "username=${PANEL_USER}&password=${PANEL_PASS}" -X POST "${BASE_URL}login" > /dev/null

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

curl -k -s -b cookie.txt -H "Accept: application/json" -H "Content-Type: application/json" -X POST "${BASE_URL}panel/api/inbounds/add" -d "$API_PAYLOAD" > /dev/null

rm -f cookie.txt
x-ui restart

echo -e "\n=========================================="
echo -e "部署完成！极简与极致安全已生效 🎉"
echo -e "面板地址: https://${MY_DOMAIN}:${PANEL_PORT}${PANEL_PATH}"
echo -e "=========================================="
echo -e "面板账号: ${PANEL_USER}"
echo -e "面板密码: ${PANEL_PASS}"
echo -e "⚠️ 请务必妥善保存上述随机生成的账号密码！"
echo -e "=========================================="
echo -e "已自动创建 VLESS+REALITY 节点，伪装目标为 iCloud。"
echo -e "REALITY Public Key: ${PUB_KEY}"
echo -e "=========================================="
