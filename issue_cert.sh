#!/bin/bash

# ==============================================================================
# 脚本名称: CF 泛域名证书全自动签发与安装脚本
# 描述: 使用 acme.sh 和 Cloudflare DNS API 自动申请并部署 SSL 证书
# ==============================================================================

# 颜色定义，让输出更直观
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 1. 权限检查：确保持有 root 权限以写入 /etc/ssl 目录
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[错误] 请使用 root 用户或 sudo 执行此脚本。${RESET}"
  exit 1
fi

echo -e "${GREEN}=== Cloudflare 泛域名证书自动化脚本 ===${RESET}"

# 2. 检查并安装基础环境依赖 (适用于 Debian/Ubuntu)
echo -e "${YELLOW}[信息] 检查系统必要依赖 (curl, cron, socat)...${RESET}"

# 标记是否需要安装软件
NEED_INSTALL=0

if ! command -v curl &> /dev/null; then echo "缺 curl"; NEED_INSTALL=1; fi
if ! command -v crontab &> /dev/null; then echo "缺 cron"; NEED_INSTALL=1; fi
if ! command -v socat &> /dev/null; then echo "缺 socat"; NEED_INSTALL=1; fi

if [ $NEED_INSTALL -eq 1 ]; then
    echo -e "${YELLOW}[信息] 正在自动补全缺失的依赖...${RESET}"
    # 这里的包管理器可以根据需要扩展，目前以 apt 为例
    if command -v apt-get &> /dev/null; then
        apt-get update -y
        apt-get install -y curl cron socat
        systemctl enable cron && systemctl start cron
    else
        echo -e "${RED}[错误] 暂不支持自动安装当前系统的依赖，请手动安装 curl, cron 和 socat。${RESET}"
        exit 1
    fi
    echo -e "${GREEN}[成功] 依赖安装完成！${RESET}"
fi

# 3. 收集用户输入
read -p "请输入主域名 (例如 example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[错误] 域名不能为空！${RESET}"
    exit 1
fi

read -p "请输入接收证书通知的邮箱: " EMAIL
read -p "请输入 Cloudflare API Token: " CF_TOKEN
# Account ID 非必填，直接按回车跳过
read -p "请输入 Cloudflare Account ID (留空按回车自动获取): " CF_ACCOUNT_ID

# 4. 安装或更新 acme.sh
if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
    echo -e "${YELLOW}[信息] 未检测到 acme.sh，正在自动安装...${RESET}"
    curl https://get.acme.sh | sh -s email="$EMAIL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}[错误] acme.sh 安装失败，请检查网络连接。${RESET}"
        exit 1
    fi
else
    echo -e "${GREEN}[信息] acme.sh 已安装，尝试升级到最新版...${RESET}"
    ~/.acme.sh/acme.sh --upgrade
fi

# 6. 配置 Cloudflare API 凭证
export CF_Token="$CF_TOKEN"
if [ -n "$CF_ACCOUNT_ID" ]; then
    export CF_Account_ID="$CF_ACCOUNT_ID"
fi

# 7. 签发证书 (包含主域名和泛域名)
echo -e "${YELLOW}[信息] 正在向 Let's Encrypt / ZeroSSL 申请证书...${RESET}"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -d "*.$DOMAIN"

if [ $? -ne 0 ]; then
    echo -e "${RED}[错误] 证书申请失败！请检查 API Token 权限或域名解析。${RESET}"
    exit 1
fi

# 8. 安装证书到系统标准目录
CERT_DIR="/etc/ssl/certs/$DOMAIN"
echo -e "${YELLOW}[信息] 正在将证书安装到 $CERT_DIR ...${RESET}"

mkdir -p "$CERT_DIR"

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
--key-file       "$CERT_DIR/key.pem"  \
--fullchain-file "$CERT_DIR/cert.pem" \

# 9. 安全收尾：收紧私钥权限
chmod 600 "$CERT_DIR/key.pem"
echo -e "${GREEN}[信息] 私钥权限已设置为 600，保障系统安全。${RESET}"

echo -e "${GREEN}================================================================${RESET}"
echo -e "${GREEN}恭喜！证书申请与部署已全部完成。${RESET}"
echo -e "证书存放路径: ${YELLOW}$CERT_DIR/cert.pem${RESET}"
echo -e "私钥存放路径: ${YELLOW}$CERT_DIR/key.pem${RESET}"
echo -e "acme.sh 已设置自动定时续期任务。${RESET}"
echo -e "${GREEN}================================================================${RESET}"
