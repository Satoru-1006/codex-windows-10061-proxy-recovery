# Windows Codex Desktop：`os error 10061` 代理故障恢复案例

> 一份经过脱敏、按证据分级、可复核的 Windows Codex Desktop 网络故障案例。重点记录：失效 localhost 代理、WebSocket 重连、TUN/Fake-IP 共存，以及如何用进程级 TCP 观察定位真实失败端点。

[English](README.md) | 简体中文

**贡献者：** [Satoru-1006](https://github.com/Satoru-1006)

## 一句话结论

这次故障不是“10 MB 太大”或“所有网络都坏了”，而是 Codex 进程实际尝试访问了失效的本机代理端口 `127.0.0.1:8890`；与此同时，另一个可用的本机混合代理正在 `127.0.0.1:7892` 监听。

修复过程是：核对所有代理来源 → 发现 `.codex/.env` 中存在旧端口 → 观察 `codex.exe` 的 TCP 目标 → 只修正失效配置 → 完全重启 Codex → 用真实请求验证恢复。

> 这是单机案例，不是通用修复。不要看到 `ALL_PROXY` 就盲目删除；先确认它指向的地址和端口是否真的有效。

## 现象

- Codex Desktop 反复显示 `Reconnecting /5`、`Reconnecting... waiting for network`。
- 错误包含 Windows `os error 10061`（连接被本机拒绝）。
- 浏览器版 ChatGPT 仍然可以通过系统代理使用。
- 通过可用代理做 HTTPS 检查可以到达 ChatGPT；对只接受 POST 的端点发送 GET 得到 `405` 属于预期结果。
- 修复后真实 `codex exec` 请求返回 `CODEX_REVIVED_OK`，但单次 `codex doctor` 仍记录了 TLS EOF 和可选 CDN 超时，说明代理节点质量问题与本地死端口问题是两层不同的故障。

## 关键证据

| 观察 | 结果 | 证据级别 |
| --- | --- | --- |
| `127.0.0.1:7892` | before-fix TCP 快照中存在监听行 | VERIFIED |
| 用户/机器/进程代理快照 | `HTTP(S)_PROXY → 7892`，`ALL_PROXY → 8890` | VERIFIED |
| `%USERPROFILE%\.codex\.env` | `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 均指向 `8890` | VERIFIED |
| 进程级 TCP timeline | 240 个采样中，`codex.exe → 8890` 有 54 次 `SynSent` 观察，分布在 36 个时间点 | DERIVED / VERIFIED |
| 真实请求 | 返回 `CODEX_REVIVED_OK` | VERIFIED |

这里没有把“`ALL_PROXY` 永远优先”当作结论。更严格的结论是：有效代理配置存在冲突，且进程级观察证明失败的 Codex 进程确实尝试了失效端点。

## 安全排查顺序

```powershell
Get-ChildItem Env: | Where-Object { $_.Name -match 'proxy' }

foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                    "WS_PROXY", "WSS_PROXY")) {
    [PSCustomObject]@{
        Name    = $name
        User    = [Environment]::GetEnvironmentVariable($name, "User")
        Machine = [Environment]::GetEnvironmentVariable($name, "Machine")
        Process = [Environment]::GetEnvironmentVariable($name, "Process")
    }
}

Get-Content "$env:USERPROFILE\.codex\.env" -ErrorAction SilentlyContinue
Test-NetConnection 127.0.0.1 -Port <proxy-port>
Get-NetTCPConnection -LocalPort <proxy-port> -ErrorAction SilentlyContinue
```

不要把完整 `.env` 粘贴到 issue 或聊天中，因为代理 URL 可能带有凭据或私有查询参数。

## 本案例的修复思路

1. 完全退出 Codex Desktop 和它启动的 `codex.exe`。
2. 备份本地代理环境与 `.codex/.env`，备份不要放入 Git staging 目录。
3. 检查每一个 localhost 代理端口是否有监听。
4. 只修正确认已经失效的值；本案例移除了旧的 `8890` 路径。
5. 将 `HTTP_PROXY`/`HTTPS_PROXY` 统一到确实在监听的 HTTP 代理。
6. 重建或精确修改 `.codex/.env` 后，完全重启 Codex。
7. 观察全新的 `codex.exe` TCP 目标，并运行 `codex doctor` 与一个最小真实请求。

本案例修复后的最小状态是：

```text
HTTP_PROXY=http://127.0.0.1:7892
HTTPS_PROXY=http://127.0.0.1:7892
NO_PROXY=localhost,127.0.0.1,::1
```

`7892` 只是本机案例端口，不能直接复制到其他机器。

## 为什么浏览器正常而 Codex 失败

浏览器成功只说明浏览器使用的路由正常。本案例中浏览器走了系统代理的 `7892`，而 Codex 子进程被观察到访问 `8890`。另外，当前 Codex 源码会在运行时线程创建前加载 `.codex/.env`，因此只查看终端当前环境并不能覆盖 Codex 启动时的所有有效配置。

当前源码核对结果和完整解释见 [full investigation report](docs/full-investigation-report.md)。

## 目录

```text
.
├── README.md
├── README.zh-CN.md
├── docs/
│   └── full-investigation-report.md
├── evidence/
│   ├── proxy-env-before.txt
│   ├── codex-dotenv-before-redacted.txt
│   ├── codex-dotenv-after.txt
│   ├── tcp-before.txt
│   ├── tcp-timeline-before-fix.txt
│   ├── codex-doctor-after-fix.txt
│   ├── codex-exec-test.txt
│   └── websocket-probe.ps1
└── .gitignore
```

原始桌面备份、SQLite、完整日志、完整 `config.toml`、订阅文件和未脱敏 `.env` 不在仓库内。原始 1.1 MB TCP timeline 被整理为只保留端点、状态、时间和计数的公开摘要。

## 相关 issue

- [openai/codex#38402](https://github.com/openai/codex/issues/38402)：最接近本案例，都是 Windows、TUN、WebSocket/HTTPS fallback 和 `10061`。
- [openai/codex#38885](https://github.com/openai/codex/issues/38885)：macOS 上 `.codex/.env` 失效代理的跨平台对应案例。
- [openai/codex#20844](https://github.com/openai/codex/issues/20844)：Windows SOCKS5 与显式 HTTP 代理差异，相关但不是同一个确定性根因。
- [openai/codex#29958](https://github.com/openai/codex/issues/29958)：Windows WebSocket 与系统代理路径差异，属于相邻问题。

## 完整内容

- [完整调查报告](docs/full-investigation-report.md)
- [公开 evidence](evidence/)
- [英文 issue 评论草稿](docs/issue-comment.md)

本项目只贡献复现信息、根因分析和脱敏证据，不提交 `openai/codex` PR。
