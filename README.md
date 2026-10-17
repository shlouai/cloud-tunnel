# cloud-tunnel

在**已经开好的** EC2 实例上，通过 SSH 一键部署和管理 **Xray VLESS + REALITY**。

脚本在本机运行，不在 AWS 侧创建任何资源：机器、密钥对、安全组都由你自己管理。

## 前置条件

**本机（Windows / Git Bash）**

- `ssh`、`curl`、`bash`（Git Bash 自带）
- 一把能登录实例的私钥（`.pem`）

**远端实例**

- Ubuntu / Amazon Linux 等带 `systemd` 的发行版
- 该 SSH 用户有**免密 sudo** 权限
- 能访问 GitHub（下载 Xray 二进制）
- 已安装 `curl`（`unzip` 缺失时脚本会自动装）

**AWS 安全组**

必须放行入站 **22（SSH）** 和 **443（如果你没改 `XRAY_PORT`）**。
脚本只能检测端口通不通，改不了安全组。

## 快速开始

Windows / Git Bash 下统一用 `bash ssctl.sh ...` 调用（不依赖文件的执行位）：

```bash
cp ssctl.conf.example ssctl.conf
# 编辑 ssctl.conf：填 SERVER_HOST、SSH_USER、SSH_KEY
bash ssctl.sh deploy
```

`deploy` 会依次完成：

1. 本地预检（配置、私钥权限、SSH 连通性）
2. 远端预检（架构、sudo、systemd、curl、unzip、443 是否被占用）
3. 下载并安装对应架构的 Xray（自动识别 x86_64 / arm64）
4. 生成 UUID、x25519 密钥对、shortId
5. 写入 `/usr/local/etc/xray/config.json` 和 `xray.service`
6. 开启 BBR（已是 bbr 则跳过）
7. 启动服务并设为开机自启
8. 打印客户端配置

部署完终端会输出两段内容：`vless://` 链接和 Clash Verge Rev（mihomo）的 `proxies` 配置。

## 命令

| 命令 | 说明 |
|---|---|
| `bash ssctl.sh deploy` | 安装、配置、开机自启并启动 |
| `bash ssctl.sh start` | 启动远端服务 |
| `bash ssctl.sh stop` | 停止远端服务 |
| `bash ssctl.sh restart` | 重启远端服务 |
| `bash ssctl.sh status` | 服务状态、端口监听、本机连通性 |
| `bash ssctl.sh config` | 重新打印客户端配置（不需要 SSH） |
| `bash ssctl.sh logs` | 查看最近 50 行日志 |
| `bash ssctl.sh uninstall` | 停止并卸载 Xray（需输入 `yes`） |

全局参数：

- `--dry-run`：只打印将在远端执行的命令，不实际执行
- `--force`：`deploy` 时强制重装二进制、重新生成密钥

```bash
bash ssctl.sh deploy --dry-run     # 先看看会做什么
bash ssctl.sh deploy --force       # 换一套 UUID / 密钥
```

## Clash Verge Rev 配置

**不要把 `vless://` 链接粘进「订阅」框**——Clash Verge Rev 的订阅输入框只接受 `http://` / `https://` 地址，粘链接会报「无效的订阅链接」。

`deploy` / `config` 会在当前目录生成一份完整的本地配置：

```
clash-<PROFILE_NAME>.yaml
```

导入方式：

1. 打开 Clash Verge Rev → **配置 / Profiles**
2. 点 **+ → 新建（New）**
3. 类型选 **Local（本地）**，名称随便填
4. 选择生成的 `clash-ec2-reality.yaml`（或把文件拖进配置页）
5. 启用该配置，模式选 **规则（Rule）**

这份配置包含：

- `proxies`：VLESS + REALITY 节点
- `proxy-groups`：一个可切换的 `PROXY` 组（节点 / DIRECT）
- `rules`：国内 IP 直连，其余走代理

如果已经有自己的配置，只需要把 `proxies` 里的节点合并进去，并在自己的 `proxy-groups` 里引用它。

## 状态与凭据

部署后，生成的 UUID / 密钥 / shortId 会存到本机：

```
~/.ec2ss/<SERVER_HOST>.state     # 权限 600
```

因此 `config`、`start`、`stop` 都不需要重新生成。私钥只存在这个文件里，**不会打印到终端**。

重新 `deploy` 默认复用已有凭据；加 `--force` 才会重新生成（客户端配置也会随之变化）。

## 常见问题

**SSH 报 `Permission denied` 或 `UNPROTECTED PRIVATE KEY FILE`**

脚本会自动把私钥权限收紧到 `600`。如果仍失败，检查：
- `SSH_USER` 是否匹配 AMI（Ubuntu 是 `ubuntu`，Amazon Linux 是 `ec2-user`）
- 安全组是否放行你的公网 IP 访问 22 端口

**`port 443 is already in use`**

实例上已有 nginx/apache 之类占用 443。先停掉它，或者在 `ssctl.conf` 里把 `XRAY_PORT` 改成别的端口（同时记得放行安全组）。

**部署成功但客户端连不上**

先跑 `bash ssctl.sh status`：
- 如果显示端口 **NOT reachable**，几乎一定是 **安全组没放行 443**
- 如果端口可达但仍连不上，检查客户端的 `uuid`、`public-key`、`short-id`、`servername` 是否与 `config` 输出一致

**换伪装目标站点**

改 `ssctl.conf` 里的 `REALITY_DEST` 和 `REALITY_SERVER_NAME`，然后重新 `deploy`。
目标站点必须支持 **TLS 1.3 + HTTP/2**，且 `REALITY_SERVER_NAME` 必须出现在该站点证书里。

默认用 `www.bing.com:443`。实测在 Xray v26 的 Chrome 指纹下，`www.bing.com`、`www.cloudflare.com`、`dl.google.com`、`www.apple.com` 都能完成握手，而 `www.microsoft.com` 会握手失败。另外 Xray 在 Apple/iCloud 目标上会提示 `may get your IP blocked by the GFW`，所以没有选 Apple。

`deploy` 结束前会自动在服务器本机走一遍完整代理链路（不依赖 AWS 安全组）。如果看到 `REALITY self-test failed`，换一个 `REALITY_DEST` 再部署即可。

**服务起不来**

```bash
bash ssctl.sh logs
```

常见原因是配置文件写错，或者 443 被占用。

## 安全说明

- `ssctl.conf` 和 `~/.ec2ss/*.state` 已在 `.gitignore` 中，不要提交。
- 服务以 `nobody` 运行（若系统无该用户则退回 `root`），且只保留绑定特权端口所需的能力。
- 本脚本不做多用户、流量统计、订阅服务，也不修改 AWS 安全组。
