# Codex Desktop on Windows: Recovering from `os error 10061`

> A redacted, evidence-led case study of a Windows Codex Desktop reconnect loop caused by an effective proxy configuration that still contained a dead localhost endpoint.

[![Windows](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white)](https://github.com/openai/codex)
[![Evidence](https://img.shields.io/badge/evidence-redacted%20%26%20auditable-2ea44f)](evidence/)
[![Related issue](https://img.shields.io/badge/openai%2Fcodex-%2338402-blue?logo=github)](https://github.com/openai/codex/issues/38402)

**Contributor:** [Satoru-1006](https://github.com/Satoru-1006)

[简体中文](README.zh-CN.md) | English

## TL;DR

In this incident, the Codex process repeatedly attempted a stale localhost proxy endpoint on port `8890`, while a different local mixed proxy was listening on port `7892`. The before-fix environment snapshot showed `HTTP_PROXY` and `HTTPS_PROXY` pointing at `7892` but `ALL_PROXY` pointing at `8890`. More importantly, the before-fix `%USERPROFILE%\.codex\.env` snapshot contained `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` values pointing at `8890`.

The supplied process-level TCP timeline recorded `codex.exe` making repeated `SYN_SENT` attempts to `127.0.0.1:8890`. That dead local hop is the deterministic explanation for Windows `os error 10061` and the visible WebSocket reconnect loop in this case.

The recovery session rebuilt `.codex/.env` with the live `7892` HTTP proxy, removed the stale `ALL_PROXY` entry, restarted Codex, and completed a real `codex exec` test with the response `CODEX_REVIVED_OK`.

This is a case study, not a universal fix. **Do not blindly delete `ALL_PROXY`.** Inspect every effective proxy source and change only an endpoint that is stale, incorrect, or no longer listening.

## Symptoms

- Codex Desktop displayed `Reconnecting /5` and `Reconnecting... waiting for network`.
- Requests reported connection refusal as `os error 10061`.
- Browser ChatGPT continued to work through the local system proxy.
- A direct HTTPS probe through the live proxy reached the ChatGPT endpoint and returned `405 Method Not Allowed`, which was expected for a GET sent to a POST-only endpoint.
- After recovery, the real model request completed, although the captured `codex doctor` run still showed intermittent TLS and optional CDN problems.

## Root cause in this case

The root cause was not established as a universal `ALL_PROXY` precedence rule. The evidence supports a narrower and more useful statement:

> The effective proxy environment used by the failing Codex process contained a dead localhost endpoint, and process-level observation showed that `codex.exe` actually attempted to use `127.0.0.1:8890`.

The configuration layers disagreed:

| Layer | Before-fix observation |
| --- | --- |
| Windows/system proxy | Local proxy on `127.0.0.1:7892` was available |
| User/machine/process environment snapshot | `HTTP_PROXY`/`HTTPS_PROXY` → `7892`; `ALL_PROXY` → `8890` |
| `%USERPROFILE%\.codex\.env` | `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` → `8890` |
| Process-level TCP timeline | `codex.exe` repeatedly targeted `127.0.0.1:8890` |

That is why a browser test was not sufficient: a browser and a Codex child process can inherit or resolve proxy configuration through different paths.

## Diagnosis

The shortest safe diagnostic sequence is:

```powershell
Get-ChildItem Env: | Where-Object { $_.Name -match 'proxy' }

[Environment]::GetEnvironmentVariable("HTTP_PROXY", "User")
[Environment]::GetEnvironmentVariable("HTTPS_PROXY", "User")
[Environment]::GetEnvironmentVariable("ALL_PROXY", "User")

Get-Content "$env:USERPROFILE\.codex\.env"

Test-NetConnection 127.0.0.1 -Port <proxy-port>
Get-NetTCPConnection -LocalPort <proxy-port> -ErrorAction SilentlyContinue
```

A port value is not evidence that a proxy is alive. Confirm that a listener exists and that the listener is the proxy you intend to use.

For process-level confirmation, identify the fresh Codex child process and observe its TCP destinations for at least 60 seconds:

```powershell
$codexPid = <fresh-codex.exe-pid>
Get-NetTCPConnection -OwningProcess $codexPid -ErrorAction SilentlyContinue |
  Sort-Object RemoteAddress, RemotePort |
  Format-Table State, LocalAddress, LocalPort, RemoteAddress, RemotePort
```

The decisive observation in this case was not a generic curl result. It was the repeated `codex.exe → 127.0.0.1:8890` pattern in the supplied timeline.

## Fix

Use the following only after checking which endpoints are valid in your own environment:

1. Fully quit Codex Desktop and its child `codex.exe` processes.
2. Back up the proxy-related environment and `.codex/.env` locally.
3. Verify every proxy port that appears in the effective configuration.
4. Remove or correct only stale entries. In this incident, the stale `8890` route was removed.
5. Normalize `HTTP_PROXY` and `HTTPS_PROXY` to the live HTTP proxy and omit unused global/WebSocket variables.
6. Restart Codex so the new process receives the new environment.
7. Re-check the fresh process's TCP destinations, then run `codex doctor` and a small real request.

Example from this incident:

```text
HTTP_PROXY=http://127.0.0.1:7892
HTTPS_PROXY=http://127.0.0.1:7892
NO_PROXY=localhost,127.0.0.1,::1
```

The example is not a recommendation to use port `7892` on another machine. Substitute the listener that is actually present in your setup.

## Verification

The strongest supplied post-fix artifact is the real request output:

```text
codex
CODEX_REVIVED_OK
tokens used
5,988
```

The same capture also recorded one transient `tls handshake eof` before the successful response. This is consistent with the investigation's separate observation of proxy-node latency and does not recreate the deterministic localhost refusal.

The supplied `codex doctor` capture after the fix reported:

- readable network-related environment;
- `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` present;
- no `ALL_PROXY` in the displayed proxy variable list;
- WebSocket failure due to `tls handshake eof` in that particular run;
- optional desktop CDN reachability timeout.

The original long report states that another doctor run returned HTTP `101` and that a post-fix 60-second trace saw zero attempts to `8890`. Those specific results are not preserved in the supplied evidence files, so this repository does not present them as directly auditable facts.

## Why browser ChatGPT still worked

The browser success only proved that one browser route was healthy. In this case, the browser used the live Windows/system proxy at `127.0.0.1:7892`, while the Codex process was observed targeting a different localhost port. The Codex source also makes clear that `.codex/.env` is loaded into the process environment before the runtime is created, so a file under the Codex home can silently change what child processes see.

Current upstream source references, checked against `openai/codex` commit [`5f49aba`](https://github.com/openai/codex/commit/5f49aba876922d6f2f55caa153bbb0ed1b46feba):

- [`arg0/src/lib.rs`](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/arg0/src/lib.rs#L297-L321) loads `.codex/.env` before creating threads and injects non-`CODEX_` variables.
- [`websocket-client/src/dialer.rs`](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/websocket-client/src/dialer.rs#L44-L68) documents that the transport-default WebSocket dialer can resolve `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY`.
- [`http-client/src/outbound_proxy.rs`](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/http-client/src/outbound_proxy.rs#L352-L373) shows a separate explicit route resolver with protocol-specific fallback order.

These source references explain why proxy resolution must be described as route- and version-dependent. They do not prove which internal route the historical Desktop build selected; the process-level observation is the evidence for this case.

## What was not the root cause

- The live `7892` proxy was not completely down: the before-fix snapshot showed a listener and HTTPS through it reached the remote endpoint.
- TUN/Fake-IP was present, but the evidence showed traffic flowing through the local proxy; TUN was suspected and not established as the deterministic cause.
- The proxy node had independent latency and TLS jitter. That explains slowness and intermittent EOFs, not a local `connection refused` to an unlistening port.
- `config.toml` was inspected and did not show a proxy entry. It is intentionally not published because the raw file contains machine-specific paths and a local fingerprint-like value.
- A browser success was not a complete end-to-end test of the Codex process path.

## Troubleshooting checklist

- [ ] Check the Windows system proxy.
- [ ] Check `HTTP_PROXY`.
- [ ] Check `HTTPS_PROXY`.
- [ ] Check `ALL_PROXY`.
- [ ] Check lowercase proxy variants; Windows environment names are case-insensitive.
- [ ] Check `%USERPROFILE%\.codex\.env`.
- [ ] Verify that every localhost proxy port has a listener.
- [ ] Test HTTPS independently.
- [ ] Run `codex doctor --json` when available.
- [ ] Observe actual `codex.exe` TCP destinations.
- [ ] Fully restart Codex after changing environment variables.
- [ ] Separate a deterministic connection refusal from later proxy-node latency.

## Environment

Only non-secret, incident-relevant details are retained:

| Item | Redacted public description |
| --- | --- |
| OS | Windows 11 x64, build `10.0.26200` |
| Codex core | `0.150.0-alpha.8` |
| Desktop package | `26.820.9563.0` |
| Local proxy | Mihomo-family mixed HTTP/SOCKS listener on `127.0.0.1:7892` |
| TUN | Enabled; Fake-IP/DNS hijack observations retained only at the behavior level |
| Stale endpoint | `127.0.0.1:8890`, no intended listener in the incident record |

No account identifiers, authentication tokens, API keys, subscription URLs, raw databases, or full local configuration dumps are included.

## Full report

Read the complete reconstruction in [`docs/full-investigation-report.md`](docs/full-investigation-report.md).

The minimal evidence set is in [`evidence/`](evidence/). The original 1.1 MB TCP timeline was reduced to a redacted, auditable summary; raw local backups remain outside this repository.

## Related Codex issues

| Issue | Relevance |
| --- | --- |
| [#38402](https://github.com/openai/codex/issues/38402) | Closest match: Windows, TUN, WebSocket/HTTPS fallback, and `os error 10061`. This case adds process-level evidence for a stale `.codex/.env` endpoint. |
| [#38885](https://github.com/openai/codex/issues/38885) | Cross-platform analogue with a file-level reproduction of a stale `$CODEX_HOME/.env` proxy. |
| [#20844](https://github.com/openai/codex/issues/20844) | Adjacent Windows proxy report focused on SOCKS5 versus explicit HTTP proxy behavior. |
| [#29958](https://github.com/openai/codex/issues/29958) | Adjacent Windows WebSocket/system-proxy route report. |

This repository is prepared as a case-study companion to a high-signal comment on #38402. It does not submit a pull request to `openai/codex`.

## Disclaimer

This write-up describes one machine, one incident window, one Codex build, and one local proxy setup. It does not establish a universal explanation for every Windows `10061`, WebSocket reconnect loop, TUN failure, TLS EOF, or slow fallback. Change proxy variables only after verifying the actual endpoint and preserve a backup before editing local configuration.

The upstream Codex contribution guide welcomes detailed issue reports, root-cause analysis, reproduction steps, and sanitized logs, and states that external code contributions and pull requests are not accepted. See [`docs/contributing.md` in openai/codex](https://github.com/openai/codex/blob/main/docs/contributing.md).
