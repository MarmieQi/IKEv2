#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

generated=0
if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  generated=1
fi
if [ ! -f config/users.txt ]; then
  cp config/users.example config/users.txt
  chmod 600 config/users.txt
  generated=1
fi
if [ "$generated" -eq 1 ]; then
  echo "已生成缺少的配置模板，请填写 .env 及 config/users.txt 后重新运行。"
  exit 1
fi

source scripts/lib/runtime-config.sh
source scripts/lib/users.sh
source scripts/lib/network-config.sh
runtime_config_load .env
users_validate config/users.txt
network_config_resolve

VPN_CERT_FILE="${VPN_CERT_FILE:-server.crt}"
VPN_KEY_FILE="${VPN_KEY_FILE:-server.key}"

if [ ! -f "ssl/$VPN_CERT_FILE" ]; then
  echo "错误：找不到证书 ssl/$VPN_CERT_FILE"
  echo "请把完整证书链放到 ssl/ 目录，并在 .env 中设置 VPN_CERT_FILE。"
  exit 1
fi

if [ ! -f "ssl/$VPN_KEY_FILE" ]; then
  echo "错误：找不到私钥 ssl/$VPN_KEY_FILE"
  echo "请把私钥放到 ssl/ 目录，并在 .env 中设置 VPN_KEY_FILE。"
  exit 1
fi

chmod 600 "ssl/$VPN_KEY_FILE" || true
chmod 600 .env
chmod 600 config/users.txt

echo "加载宿主机 IPsec/XFRM 模块..."
modprobe xfrm_user || true
modprobe xfrm_interface || true
modprobe esp4 || true
modprobe esp6 || true
modprobe xfrm_algo || true

if ! ip xfrm state >/dev/null 2>&1; then
  echo "错误：宿主机 ip xfrm state 不可用。请先确认内核 XFRM/IPsec 模块可用。"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "错误：找不到 docker 命令。"
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "错误：找不到 docker compose。"
  exit 1
fi

echo "拉取并启动 IKEv2/IPSec MSCHAPv2 容器..."
docker compose pull
docker compose up -d

echo ""
echo "部署完成。"
echo ""
echo "查看日志："
echo "  docker logs -f ikev2-mschapv2"
echo ""
echo "查看连接："
echo "  docker exec -it ikev2-mschapv2 swanctl --list-sas"
echo ""
echo "安卓填写："
echo "  类型：IKEv2/IPSec MSCHAPv2"
echo "  服务器地址：.env 里的 VPN_DOMAIN"
echo "  IPSec 标识符：.env 里的 VPN_DOMAIN"
echo "  用户名：config/users.txt 中填写的用户名"
echo "  密码：最初填写的明文密码（不是文件内的 NT 哈希）"
