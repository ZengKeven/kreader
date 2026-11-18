# Ubuntu 上部署 KReader 服务端

Ubuntu 主机只需 Git、Docker Engine 和 Compose 插件。首次构建需要能访问微软容器镜像仓库、Ubuntu 软件源和 NuGet，镜像会自行编译 .NET 10 服务端。若尚未安装 Docker，请先按 [Docker 官方 Ubuntu 安装步骤](https://docs.docker.com/engine/install/ubuntu/#install-using-the-apt-repository) 安装含 `docker-compose-plugin` 的软件包。

## 启动

```bash
sudo docker compose version
git clone https://github.com/ZengKeven/kreader.git
cd kreader
sudo docker compose up -d --build --wait
curl -fsS http://127.0.0.1:7187/health
```

已有源码的服务器可以在仓库目录执行 `git pull --ff-only` 后运行同一条 Compose 命令。健康接口返回 `{"app":"个人书房","version":2}`。用 `sudo docker compose ps` 查看健康状态，用 `sudo docker compose logs --tail=100 server` 查看启动日志。Docker 服务随系统启动时，容器将按 `unless-stopped` 策略恢复。

新书库的书源列表为空，可在客户端的「我的 → 书源管理」导入。更新时会复用已有书库中的书源。

## 连接电脑和手机

默认端口仅绑定 Ubuntu 本机，适合本机验证、SSH 隧道或接入同机的 HTTPS 反向代理。

在可信局域网直连时，先运行 `ip -br -4 addr` 找到 Ubuntu 的局域网地址。以下以 `192.168.1.20` 为例。在仓库目录的 `.env` 文件中添加或更新一行：

```dotenv
KREADER_BIND=192.168.1.20
```

保存后重新应用配置并取得个人令牌：

```bash
sudo docker compose up -d --wait
curl -fsS http://192.168.1.20:7187/health
sudo docker compose exec -T server cat /data/access-token.txt
echo
```

在同一 Wi-Fi 的设备上先用浏览器打开 `http://192.168.1.20:7187/health`。随后在阅读器的 **我的 → 连接与同步** 中填写服务地址 `http://192.168.1.20:7187` 和上一步的令牌，点击 **连接并同步**。客户端会自动添加 API 路径。

如果部署在公网云主机，请保留默认的回环绑定，从同机 HTTPS 反向代理转发到 `http://127.0.0.1:7187`，客户端填写 HTTPS 域名。也可以通过 VPN 接入内网。局域网端口被占用时，可在 `.env` 另加 `KREADER_PORT=17187`，再运行 `docker compose up -d --wait` 并相应更换客户端端口。直接发布的 Docker 端口有自己的防火墙转发规则。[Docker 端口与防火墙说明](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations)

## 迁移现有 Windows 书库

想继续读已有的书时，先退出正在使用的阅读器，停止旧 Windows 服务，然后把 Windows 服务端完整的 `data` 目录复制到 Ubuntu（例如 `~/kreader-import/data`）。应包含 `library.sqlite`、`originals/`、`access-token.txt` 及任何同名 SQLite 日志文件。在新的 Ubuntu 部署上，用以下命令替代首次启动：

```bash
sudo docker compose build
sudo docker compose run --rm --no-deps -T --user root \
  -v "$HOME/kreader-import/data:/import:ro" --entrypoint sh server -ec '
    test -s /import/library.sqlite
    test -d /import/originals
    test -z "$(ls -A /data)" || { echo "目标卷已有数据，请使用空卷"; exit 1; }
    cp -a /import/. /data/
    chown -R app:app /data
    chmod 700 /data
    if test -f /data/access-token.txt; then chmod 600 /data/access-token.txt; fi
  '
sudo docker compose up -d --wait
```

迁移后各设备使用新服务地址。复制了原令牌文件的书库沿用原令牌。

## 更新与备份

SQLite、上传的原书和令牌都在 Docker 命名卷 `kreader_library`，容器内挂载点为 `/data`。常规更新会重建容器并复用这个卷：

```bash
git pull --ff-only
sudo docker compose up -d --build --wait
```

停服备份可同时保全 SQLite 和原书。在仓库目录运行：

```bash
umask 077
sudo docker compose stop server
sudo docker compose run --rm --no-deps -T --entrypoint tar server -C /data -czf - . > "$HOME/kreader-data-$(date +%F-%H%M%S).tar.gz"
sudo docker compose up -d --wait
```

`sudo docker compose down` 会保留书库卷。添加 `-v` 会一并删除书库卷。
