#!/bin/bash

# 检查并读取 .env 文件
if [ -f ".env" ]; then
  source .env
  current_path=$CURRENT_PATH
else
  current_path=$(pwd)
fi

# 函数: 获取用户输入或使用默认值
function prompt_user_input() {
  read -p "请输入用于注册 acme.sh 的邮箱 [${EMAIL:-}]: " email
  email=${email:-$EMAIL}

  read -p "请输入当前机器域名 [${DOMAIN:-}]: " domain
  domain=${domain:-$DOMAIN}

  read -p "请确保该域名的 A 记录指向当前机器的公网 IP，并按任意键继续..."

  read -p "请输入 Cloudflare 的 CF_Token [${CF_TOKEN:-}]: " CF_Token
  CF_Token=${CF_Token:-$CF_TOKEN}

  read -p "请输入 Cloudflare 的 CF_Account_ID [${CF_ACCOUNT_ID:-}]: " CF_Account_ID
  CF_Account_ID=${CF_Account_ID:-$CF_ACCOUNT_ID}

  read -p "请输入 Cloudflare 的 CF_Zone_ID [${CF_ZONE_ID:-}]: " CF_Zone_ID
  CF_Zone_ID=${CF_Zone_ID:-$CF_ZONE_ID}

  read -p "请输入 gost 的 http 代理验证的 username (留空自动生成) [${GOST_USERNAME:-}]: " username
  username=${username:-$GOST_USERNAME}
  if [ -z "$username" ]; then
    username=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
    echo "生成的用户名: $username"
  fi

  read -p "请输入 gost 的 http 代理验证的 password (留空自动生成) [${GOST_PASSWORD:-}]: " password
  password=${password:-$GOST_PASSWORD}
  if [ -z "$password" ]; then
    password=$(tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c 16)
    echo "生成的密码: $password"
  fi

  # 将用户输入保存到 .env 文件
  cat <<EOF > .env
EMAIL=$email
DOMAIN=$domain
CF_TOKEN=$CF_Token
CF_ACCOUNT_ID=$CF_Account_ID
CF_ZONE_ID=$CF_Zone_ID
GOST_USERNAME=$username
GOST_PASSWORD=$password
CURRENT_PATH=$current_path
EOF
}

# 函数: 安装 gost
function install_gost() {
  git clone https://github.com/go-gost/gost.git
  cd gost
  sudo bash install.sh
  cd ..
}

# 函数: 安装 acme.sh
function install_acme_sh() {
  curl https://get.acme.sh | sh -s email=$email
}

# 函数: 申请证书
function issue_cert() {
  ~/.acme.sh/acme.sh --issue -d $domain -d "*.$domain" --dns dns_cf --server letsencrypt
}

# 函数: 安装证书
function install_cert() {
  cert_dir="$current_path/certs/$domain"
  if ~/.acme.sh/acme.sh --check --domain $domain | grep -q 'is not yet due for renewal'; then
    if [[ ! -f "$cert_dir/key.pem" || ! -f "$cert_dir/cert.pem" ]]; then
      echo "证书不存在，重新安装证书..."
      ~/.acme.sh/acme.sh --install-cert -d $domain --key-file $cert_dir/key.pem --fullchain-file $cert_dir/cert.pem --ecc
    fi
  else
    mkdir -p $cert_dir
    ~/.acme.sh/acme.sh --install-cert -d $domain --key-file $cert_dir/key.pem --fullchain-file $cert_dir/cert.pem --ecc
  fi
}

# 函数: 创建 gost.yaml 配置文件
function create_gost_config() {
  cat <<EOF > gost.yaml
services:
- name: service-0
  addr: ":443"
  handler:
    type: http
    auth:
      username: $username
      password: $password
    metadata:
      knock: www.google.com
      probeResistance: code:404
  listener:
    type: tls
    tls:
      certFile: "$cert_dir/cert.pem"
      keyFile: "$cert_dir/key.pem"
EOF
}

# 函数: 创建 gost 系统服务文件
function create_gost_service() {
  sudo bash -c "cat <<EOF > /etc/systemd/system/gost.service
[Unit]
Description=GO Simple Tunnel
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C $current_path/gost.yaml
Restart=always

[Install]
WantedBy=multi-user.target
EOF"
}

# 函数: 启用并启动 gost 服务
function enable_start_gost() {
  sudo systemctl enable gost
  sudo systemctl start gost

  # 检查 gost 服务状态并设置 10 秒超时
  echo "检查 gost 服务状态..."
  sudo systemctl status gost & sleep 10; kill $!

  # 打印用户名和密码
  echo "gost 代理验证的用户名: $username"
  echo "gost 代理验证的密码: $password"

  # 打印 Clash 配置
  cat <<EOF

Clash 配置示例:
- type: http
  name: https-$domain
  server: $domain
  port: 443
  username: $username
  password: $password
  tls: true

EOF
}

# 函数: 创建自动续签脚本
function create_renew_script() {
  cat <<EOF > renew_and_restart_gost.sh
#!/bin/bash

# 续签证书并重启 gost 服务
~/.acme.sh/acme.sh --install-cert -d $domain --key-file $cert_dir/key.pem --fullchain-file $cert_dir/cert.pem --ecc
sudo systemctl restart gost
EOF

  chmod +x renew_and_restart_gost.sh

  # 添加到 cron job，每月自动续签证书并重启 gost 服务
  (crontab -l 2>/dev/null; echo "0 0 1 * * $current_path/renew_and_restart_gost.sh") | crontab -
}

# 函数: 重新安装 gost
function reinstall_gost() {
  echo "重新安装 gost..."
  install_gost
  create_gost_config
  create_gost_service
  enable_start_gost
  echo "gost 已重新安装。"
}

# 函数: 查看 gost 服务状态
function view_gost_status() {
  echo "查看 gost 服务状态..."
  sudo systemctl status gost
}

# 函数: 删除 gost
function uninstall_gost() {
  echo "停止并删除 gost 服务..."
  sudo systemctl stop gost
  sudo rm /etc/systemd/system/gost.service
  sudo systemctl daemon-reload
  echo "删除 gost.yaml..."
  rm -f $current_path/gost.yaml
  echo "gost 服务已卸载并删除。"
}

# 函数: 续签证书
function renew_cert() {
  echo "续签证书..."
  ~/.acme.sh/acme.sh --install-cert -d $domain --key-file $cert_dir/key.pem --fullchain-file $cert_dir/cert.pem --ecc
  sudo systemctl restart gost
  echo "证书已更新并且 gost 服务已重启。"
}

# 函数: 查看证书信息
function view_cert_info() {
  echo "查看证书信息..."
  cert_dir="$current_path/certs/$domain"
  openssl x509 -in $cert_dir/cert.pem -noout -text | grep -E 'Not Before|Not After'
}

# 函数: 删除证书
function delete_cert() {
  read -p "请输入要删除证书的域名: " del_domain
  cert_dir="$current_path/certs/$del_domain"
  if [ -d "$cert_dir" ]; then
    echo "删除证书目录 $cert_dir..."
    rm -rf "$cert_dir"
    echo "证书已删除。"
  else
    echo "证书目录 $cert_dir 不存在。"
  fi
}

# 函数: 卸载 acme.sh
function uninstall_acme_sh() {
  echo "停止 acme.sh 自动申请证书..."
  ~/.acme.sh/acme.sh --uninstall
  echo "acme.sh 已卸载。"
}

# 主菜单
function main_menu() {
  while true; do
    echo "请选择一个选项:"
    echo "1. 一键全自动"
    echo "2. 重新安装/查看/卸载 gost"
    echo "3. 续签/查看/删除 tls 证书"
    echo "4. 卸载并清理"
    read -p "输入选项 (1/2/3/4): " main_choice

    case $main_choice in
      1)
        # 一键全自动
        prompt_user_input
        current_path=$(pwd)
        echo "当前路径: $current_path"
        install_gost
        install_acme_sh
        issue_cert
        install_cert
        create_gost_config
        create_gost_service
        enable_start_gost
        create_renew_script
        ;;
      2)
        # 重新安装/查看/卸载 gost
        while true; do
          echo "请选择一个选项:"
          echo "1. 重新安装 gost"
          echo "2. 查看 gost.service 的状态"
          echo "3. 卸载 gost"
          echo "0. 回到首页主菜单"
          echo "-1. 回到上一级菜单"
          read -p "输入选项 (1/2/3/0/-1): " gost_choice

          case $gost_choice in
            1)
              reinstall_gost
              ;;
            2)
              view_gost_status
              ;;
            3)
              uninstall_gost
              ;;
            0)
              break
              ;;
            -1)
              break
              ;;
            *)
              echo "无效选项。"
              ;;
          esac
        done
        ;;
      3)
        # 续签/查看/删除 tls 证书
        while true; do
          echo "请选择一个选项:"
          echo "1. 续签证书"
          echo "2. 查看当前证书的存放位置以及有效截至时间"
          echo "3. 删除 tls 证书"
          echo "0. 回到首页主菜单"
          echo "-1. 回到上一级菜单"
          read -p "输入选项 (1/2/3/0/-1): " cert_choice

          case $cert_choice in
            1)
              renew_cert
              ;;
            2)
              view_cert_info
              ;;
            3)
              delete_cert
              ;;
            0)
              break
              ;;
            -1)
              break
              ;;
            *)
              echo "无效选项。"
              ;;
          esac
        done
        ;;
      4)
        # 卸载并清理
        while true; do
          echo "请选择一个选项:"
          echo "1. 停止 gost 服务，并且删除 /etc/systemd/system/gost.service"
          echo "2. 删除证书"
          echo "3. 卸载 + 删除 gost 服务"
          echo "4. 卸载 acme.sh 并且停止自动申请证书"
          echo "0. 回到首页主菜单"
          echo "-1. 回到上一级菜单"
          read -p "输入选项 (1/2/3/4/0/-1): " clean_choice

          case $clean_choice in
            1)
              sudo systemctl stop gost
              sudo rm /etc/systemd/system/gost.service
              sudo systemctl daemon-reload
              echo "gost 服务已停止并删除。"
              ;;
            2)
              delete_cert
              ;;
            3)
              uninstall_gost
              ;;
            4)
              uninstall_acme_sh
              ;;
            0)
              break
              ;;
            -1)
              break
              ;;
            *)
              echo "无效选项。"
              ;;
          esac
        done
        ;;
      *)
        echo "无效选项。"
        ;;
    esac
  done
}

# 执行主菜单
main_menu
