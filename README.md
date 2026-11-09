# 朋友圈 AI 助手 · 自建后端 pyq-server

Node 18+，**零第三方依赖**，一个进程做三件事：

1. **AI 代理**：智谱密钥只留在服务器，App / 网页端不接触真实 Key；
2. **账号 + 云同步**：手机号/邮箱 + 密码登录，资料、文案、素材、历史、生成记录整包存服务器；
3. **每日 0 点学习**：读取用户资料和文案样本，生成「人物画像摘要 + 写作风格规则」，
   并把用户数据同步到飞书云盘（未配置飞书则只用本地磁盘）。

## 本地开发

```bash
ZHIPU_API_KEY=你的智谱Key AUTH_SECRET=随机十六进制 PORT=8787 node server.js
curl http://127.0.0.1:8787/health
```

## 一键 Docker 部署（有持久磁盘的服务器）

```bash
export ZHIPU_API_KEY=你的智谱Key
export AUTH_SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
# 可选：export FEISHU_APP_ID=... FEISHU_APP_SECRET=... FEISHU_FOLDER_TOKEN=...
bash deploy.sh
```

数据通过 Docker 卷 `pyq-data` 持久化，重新构建镜像不会丢账号和资料。

---

## Koyeb 免费版部署（免信用卡优先选择）

Koyeb 提供 1 个永久免费 Web 服务：**512MB 内存 / 0.1 vCPU / 2GB 临时磁盘**，
仅 Frankfurt、Washington D.C. 两个区域。

### 免费版的三个限制（方案已针对处理）

| 限制 | 影响 | 本方案的处理 |
|---|---|---|
| 无持久卷，实例重建后磁盘清空 | 账号和资料会丢 | **飞书云盘作为持久存储**：每次保存防抖 3 秒上传，启动时自动恢复 |
| 1 小时无流量自动休眠（scale-to-zero） | 0 点定时任务不会触发 | 外部定时服务每天 00:00 访问 `/health` 唤醒，启动后自动补跑当日学习 |
| 0.1 vCPU / 512MB | 并发能力有限 | 服务本身很轻；图片过大时前端已做体积保护 |

> 注册时 Koyeb 可能要求信用卡验证（部分账号用 GitHub / Google 登录可跳过）。
> 如果被要求绑卡且你不想绑，见文末「不需要任何信用卡的备选」。

### 第 1 步：准备飞书持久存储（必做）

1. 打开 [飞书开放平台](https://open.feishu.cn/app) → 创建**企业自建应用**
2. 「权限管理」开通：`drive:drive`（云空间文件上传/下载/列表）
3. 「版本管理与发布」创建版本并发布，等待企业管理员审核通过
4. 在飞书云盘新建一个文件夹，把应用**添加为该文件夹的协作者**（可编辑）
5. 从文件夹 URL 里取出文件夹 token：
   `https://xxx.feishu.cn/drive/folder/fldcnxxxxxxxx` → `fldcnxxxxxxxx`
6. 记下应用的 `App ID` 和 `App Secret`

### 第 2 步：把代码推到 GitHub

把 `pyq-proxy` 目录推到一个仓库（私有仓库也可以）。Koyeb 会读取里面的 `Dockerfile` 构建。

```bash
cd pyq-proxy
git init && git add . && git commit -m "pyq-server"
git remote add origin git@github.com:你的账号/pyq-proxy.git
git push -u origin main
```

### 第 3 步：在 Koyeb 创建服务

1. 登录 [Koyeb 控制台](https://app.koyeb.com) → **Create Service**
2. **Deploy from GitHub** → 选择仓库和分支
3. **Builder**：Dockerfile
4. **Instance**：Free（512MB）
5. **Ports**：把端口改成 **8787**，协议 HTTP，健康检查路径 `/health`
6. **Environment variables** 填入：

```
ZHIPU_API_KEY=你的智谱Key
AUTH_SECRET=一段固定的随机字符串（务必保存好，不要更换）
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=xxx
FEISHU_FOLDER_TOKEN=fldcnxxx
REMOTE_STORE=auto
ADMIN_TOKEN=随便一段运维口令
TZ=Asia/Shanghai
```

7. 点击 Deploy，等状态变成 Healthy
8. 访问 `https://你的服务名.koyeb.app/health`，确认
   `"store":"feishu"`、`"feishu":"on"`

> `AUTH_SECRET` 必须固定：它既用于登录 token 签名，也用于加密飞书里的密码哈希。
> 更换会导致所有用户需要重新登录，且旧存档里的密码无法解密。

### 第 4 步：配置每天 00:00 唤醒学习

Koyeb 免费实例空闲 1 小时后休眠，所以需要外部定时器唤醒：

1. 注册 [cron-job.org](https://cron-job.org)（免费）
2. 新建任务：
   - URL：`https://你的服务名.koyeb.app/health`
   - 执行时间：每天 **00:00**（时区选 Asia/Shanghai）
   - 其他默认
3. 保存并手动执行一次，确认返回 200

服务被唤醒后 60 秒内会自动补跑当日学习任务（`catchUpDaily`），无需额外配置。

### 第 5 步：App / 网页端填写

「我的 → 账号与云同步」填 `https://你的服务名.koyeb.app` → 注册 / 登录。

### 运维

- 日志：Koyeb 控制台 → Service → Logs
- 手动触发每日任务：
  ```bash
  curl -X POST https://你的服务名.koyeb.app/admin/daily \
    -H "X-Admin-Token: 你的ADMIN_TOKEN"
  ```
- 升级：GitHub 推送新代码，Koyeb 自动重新部署；数据在飞书，不受影响

---

## 不需要任何信用卡的备选：ClawCloud Run（推荐，可长期跑）

GitHub 账号注册满 180 天 → 每月 $5 额度**永久免费**，无需信用卡；
容器 7×24 常驻不休眠，支持持久卷，$5 足够跑一个 512MB 的服务。

### 第 1 步：推送代码并自动构建镜像

1. 把 `pyq-proxy` 目录推到 GitHub 仓库（含 `.github/workflows/docker-image.yml`）
2. 推送后 GitHub Actions 会自动构建镜像到 `ghcr.io/你的用户名/pyq-proxy:latest`
3. 构建完成后，到 GitHub → Packages → pyq-proxy → **Change visibility → Public**
   （公开镜像 ClawCloud 才能免密拉取；镜像里只有代码，密钥全在环境变量里，无安全问题）

### 第 2 步：在 ClawCloud 创建应用

1. 打开 [console.run.claw.cloud](https://console.run.claw.cloud)，用 **GitHub 登录**
2. **App Launchpad → Create App**：
   - **Image**：`ghcr.io/你的用户名/pyq-proxy:latest`
   - **Resources**：0.5 CPU / 512MB（创建页会显示预估月费，确认 ≤ $5）
   - **Network**：容器端口 **8787**，开启 **Public Access**（自动分配 HTTPS 域名）
   - **Storage**：添加持久卷挂载到 `/app/data`（1GB 足够，重启/重建不丢数据）
   - **Environment Variables**：

```
ZHIPU_API_KEY=你的智谱Key
AUTH_SECRET=一段固定的随机字符串（务必保存好，不要更换）
TZ=Asia/Shanghai
REMOTE_STORE=auto
FEISHU_APP_ID / FEISHU_APP_SECRET / FEISHU_FOLDER_TOKEN（可选，额外备份）
ADMIN_TOKEN=随便一段运维口令（可选）
```

3. Deploy，等状态变 Running
4. 访问 `https://你的域名.clawcloudrun.com/health`，确认 `"store"` 正常

### 优势

- 常驻不休眠：每日 0 点学习在容器内自动触发，**不需要 cron-job.org 唤醒**
- 持久卷 + 可选飞书双保险：数据先写本地卷，再防抖同步飞书
- 升级：git push → Actions 自动构建 → ClawCloud 里点 Redeploy 拉新镜像，数据不丢

> 注意：GitHub 账号不满 180 天只有首月 $5；该活动官方标注为限时领取，建议尽早注册锁定。

## 其他备选

1. **国内云厂商免费试用**（阿里云 / 腾讯云 / 华为云新用户，通常 1 个月，支付宝/微信即可）；
   用上面的「一键 Docker 部署」，有持久磁盘，不需要飞书也能保存数据。
2. **Oracle Cloud Always Free**：永久免费 ARM 实例，但需要 Visa/Mastercard 验证。
   见 [oracle-setup.sh](./oracle-setup.sh)。

---

## 环境变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `ZHIPU_API_KEY` | ✅ | — | 智谱开放平台 API Key（只存在服务器） |
| `AUTH_SECRET` | ⚠️ 强烈建议 | 自动生成并落盘 | token 签名密钥 + 飞书存档密码加密密钥，**必须固定** |
| `DATA_DIR` | ❌ | `./data` | 账号 / 资料 / 画像目录 |
| `PROXY_TOKEN` | ❌ | 空（开放） | 额外的代理口令；登录云账号后会自动带身份 token |
| `ALLOW_ORIGIN` | ❌ | `*` | CORS 允许来源，生产建议改成你的站点域名 |
| `PORT` | ❌ | 8787 | 监听端口（Koyeb 里要填成 8787） |
| `FEISHU_APP_ID` / `FEISHU_APP_SECRET` / `FEISHU_FOLDER_TOKEN` | Koyeb 必填 | — | 飞书自建应用与云盘文件夹 |
| `REMOTE_STORE` | ❌ | `auto` | `auto`：配置飞书即作为持久存储；`off`：只用本地磁盘 |
| `REMOTE_KEEP` | ❌ | `14` | 每个账号保留最近多少份存档 |
| `ADMIN_TOKEN` | ❌ | — | 手动触发每日任务的运维口令 |
| `ZHIPU_BASE` / `FEISHU_BASE` | ❌ | 官方地址 | 仅测试 / 私有网关时改 |

## 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/health` | 健康检查（含用户数、持久存储状态） |
| POST | `/auth/register` | 注册：`{account,password,nickname}`，返回 `token` |
| POST | `/auth/login` | 登录：`{account,password}`，返回 `token` + `persona` |
| POST | `/auth/logout` | 退出（客户端清除 token 即可） |
| GET | `/sync` | 拉取整包资料（Bearer token） |
| PUT | `/sync` | 上传整包：`{payload,baseUpdatedAt}`；云端更新时返回 409 + 云端版本 |
| GET | `/persona` | 读取人物画像摘要 |
| POST | `/persona/build` | 立即学习（`{force,payload}`，1 分钟内不重复调用） |
| POST | `/chat/completions` | 文案生成 / 润色（支持用户 token 或 PROXY_TOKEN） |
| POST | `/videos/generations` | 视频生成任务 |
| GET  | `/async-result/:id` | 视频结果轮询 |
| POST | `/images/generations` | 图片生成 |
| POST | `/moderate` | 图片云端审核，返回统一 violations |
| POST | `/admin/daily` | 运维手动触发每日学习 + 存档（需 `X-Admin-Token`） |

AI 代理同时兼容 `/xxx` 与 `/v1/xxx` 根路径。

## 每日 0 点学习逻辑

- 时区固定 `Asia/Shanghai`（UTC+8），服务启动后计算下一个 00:00 并定时执行；
- 启动时如果当天还没跑过，会补跑一次（Koyeb 冷启动唤醒后同样生效）；
- 每个用户：取资料（`user` + `profileSections`）+ 文案样本（素材库文案、草稿、最近历史），
  拼成语料并算 SHA-256；**内容没变化就跳过，不重复调用模型**；
- 有变化才调用 `glm-4-flash` 生成 ≤1200 字画像：
  事实清单 / 写作风格 / 禁止虚构 / 使用规则；
- 画像存回用户数据，并同步到飞书云盘。

## 飞书持久存储 / 备份

配置三个环境变量即可：`FEISHU_APP_ID`、`FEISHU_APP_SECRET`、`FEISHU_FOLDER_TOKEN`。

- 每次用户数据保存后，防抖 3 秒上传 `<账号>-YYYYMMDD-HHmmssSSS.json`；
- 服务启动时（含 Koyeb 重建实例）自动列出文件夹、下载每个账号最新一份并恢复；
- 存档里的密码哈希用 `AUTH_SECRET` 派生的 AES-256-GCM 密钥加密，云盘里只有密文；
- 每天任务结束后清理旧存档，每个账号保留最近 `REMOTE_KEEP`（默认 14）份；
- 上传失败重试 3 次，不阻塞用户请求；未配置飞书时自动跳过。

飞书自建应用需要开通云空间权限（`drive:drive`），并把应用加入目标文件夹的协作者。

## 前端怎么填

「我的 → 账号与云同步」填服务器根地址（如 `https://你的服务名.koyeb.app`）→ 注册 / 登录。
AI 与云同步共用这个地址：登录后生成文案会自动携带云账号 token，
服务器地址留空时也会自动回退到云同步地址。

## 反向代理（推荐 HTTPS）

见 [nginx.conf.example](./nginx.conf.example)。网页版必须 HTTPS，否则浏览器会拦截请求。
Koyeb 自带 HTTPS，无需额外配置。
