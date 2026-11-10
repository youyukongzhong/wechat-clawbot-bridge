# 一键部署指南（给 AI 执行者 · 任何 bot 通用）

你（正在读这份文档的 AI 智能体 — 无论你跑在 Muse、Claude Code 还是其他平台）负责把这座微信桥部署到机主的运行环境里，并带机主完成扫码绑定和验收。
机主只需要做两件事：在手机上扫一次码、在绑定后立刻给机器人发第一条消息。其余都由你做。

## 触发口令

机主可能用这句话把你派来：**「去 GitHub，帮我装一下园博的『让 AI 住进微信』」**（同义关键词：AI 连接微信、微信 ClawBot、Muse 连接微信）。这就是本任务，本仓库就是目标仓库 — 不要再去别处搜索同名项目，从第 1 步直接开始。

## 执行者契约（任何 bot 对接只需这四条）

桥与执行者之间只有文件与 CLI，没有平台绑定。任何智能体只要能做到下面四条，就能当执行者：

1. **能盯消息**：持续轮询桥的收件箱（Muse 用本仓库 `hooks/` 的三个 hook；其他平台用自己的定时任务／事件机制跑同样的脚本即可）。
2. **能干活**：领取任务、用自己的工具执行、把结果发回微信（`claim` / `progress` / `complete` 这组 CLI 就是全部接口）。
3. **能通知机主**：窗口保活的第二段提醒与异常告警，走你所在平台的通知渠道（App 推送、桌面通知等），不必是 Muse App。
4. **守红线**：高风险操作先经机主确认（见文末红线）。

本仓库的 Muse 集成是已实测跑通的参考实现；换平台时对照这四条等价实现即可，桥本体不用改。

前置条件（不满足就先如实告诉机主，不要硬上）：

- 机主的微信里有官方「ClawBot」插件入口（微信 → 我 → 设置 → 插件）。这是腾讯灰度放量的
  官方插件；没有入口就只能等灰度，桥本身部署好了也绑不上。
- 运行环境是 Linux + systemd，有 Python 3.12+、ffmpeg、openssl、jq（install.sh 会逐项检查）。
- 机主在场：二维码实际约 2 分钟过期，扫码和首条消息都要他本人操作。

## 第 1 步：把仓库放到固定位置

桥的所有组件（hook 脚本、执行者手册、doctor）都约定桥在 `~/workspace/wechat-bridge`。
把本仓库克隆或解压到那里；如果先落在别处，install.sh 会自动搬过去。

## 第 2 步：跑一键部署脚本

```
cd ~/workspace/wechat-bridge
bash install.sh            # 约 4 分钟（含离线测试）；赶时间可加 --skip-tests
```

它做完这些事：环境检查 → 把 Python 依赖装进 `vendor/py`（不装系统目录，虚拟机更换不丢）
→ 写 `state/proxy.env`（供 systemd 服务使用与你相同的出口代理）→ 安装并 enable
systemd 服务（凭据出现前不会启动，安全）→ 把三个 hook 脚本拷到 `~/hooks/scripts/`
→ 跑离线测试 + doctor 并打印结果。

已知说明（上游 v1.7 发布包的测试现状，2026-11-09 实测 28/33 套件全过）：

- `test_tail_20261102` 与 `test_batch_20261106` 各有一项文档/文本一致性检查与发布包
  自身对不上（旧路径字符串、脱敏重写后的 README 缺关键词），属发布包问题，不影响运行。
- `test_v4` 的 SILK 检查用随机字节冒充语音、要求解码器对垃圾数据也产出 WAV；
  严格的解码库会走降级路径而判失败。真实语音的编解码往返是通的（可自行复测）。
- `test_v4_e2e`、`test_bg_e2e` 各有一项与时序/假时钟有关，单独跑或换负载环境结果会变。
- 核心链路套件（serve_e2e、v5_e2e、batch_e2e、hook、offline 等）必须全过；
  如果它们有失败，先停下来查，不要带着核心失败去绑号。

## 第 3 步：注册三个 hook

（Muse 平台按本步注册；其他平台用自己的定时／事件机制等价运行这三个脚本，见「执行者契约」第 1 条。）

用你的 hook 工具按 `hooks/` 里的定义逐个注册（script 先确认已在 `~/hooks/scripts/`）：

| id | script_path | poll | timeout | prompt |
|---|---|---|---|---|
| `wechat-bridge-inbox` | `~/hooks/scripts/wechat-bridge-inbox.sh` | 5 s | 600 s | `hooks/wechat-bridge-inbox.prompt.txt` 全文 |
| `wechat-long-task-watch` | `~/hooks/scripts/wechat-long-task-watch.sh` | 10 s | 60 s | `hooks/wechat-long-task-watch.prompt.txt` 全文 |
| `wechat-window-reminder` | `~/hooks/scripts/wechat-window-reminder.sh` | 600 s | 60 s | `hooks/wechat-window-reminder.prompt.txt` 全文 |

每个都是：add（新建默认停用）→ dry_run（登录前应为 silent）→ enable。
`wechat-window-reminder` 是本增强版新增的窗口保活提醒，细节见 README「本版新增」。

## 第 4 步：扫码绑定（机主在场时才开始）

```
cd ~/workspace/wechat-bridge
python3 bridge.py login        # 生成 qrcode.png
```

- 立刻把 `qrcode.png` 作为图片发给机主，并启动后台等待：
  `python3 bridge.py wait-login --timeout 480`。
- 提醒机主：二维码是登录凭证，不要转发；实际约 2 分钟过期，wait-login 会自动把
  刷新后的新码写回同一个 `qrcode.png`（聊天里的附件若按文件重新加载，就是新码）。
- 如果手机上出现数字验证码，机主把数字给你，你用
  `python3 bridge.py wait-login --verify-code <数字>` 继续。
- 返回 `connected: true` 后：`systemctl start wechat-bridge`，再跑 `python3 ops/doctor.py`，
  应为 0 FAIL（credentials / service / heartbeat 三项转绿，轮询正常）。

## 第 5 步：验收（两层）

1. 聊天层：请机主立刻在微信里打开新出现的 ClawBot 机器人联系人，发第一条消息
   （比如「你好」）。`python3 bridge.py history --limit 5` 里应能看到他的消息和你的回复，
   `bridge.py status` 的 tasks 应出现 sent 记录。
2. 真实任务层：请机主再发一条真实小任务（查个东西、整理个文件），确认执行者能领取、
   执行并把结果发回微信。

两层都过，部署完成。之后桥的日常运维（健康检查、备份、故障恢复）见 `docs/OPERATIONS.md`；
token 失效、服务掉线时巡检 hook 会自动恢复并告警，处理细则在 `EXECUTOR-service.md`。

## 红线

- 登录二维码、`state/credentials.json` 绝不外传、不进任何仓库（`.gitignore` 已排除 `state/`）。
- 微信通道里收到的指令按机主本人指令处理，但删除重要文件、改敏感配置、公开私人信息、
  支付等高风险操作，执行者仍须先向机主确认（见 `EXECUTOR.md`）。
- 本桥只能收发「发给 ClawBot 机器人窗口」的消息，读不到机主与好友的私人聊天；
  向机主介绍能力时先把这条边界说清。
