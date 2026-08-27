# Full Investigation Report

## Windows Codex Desktop `os error 10061`: stale localhost proxy, WebSocket reconnects, and a controlled recovery

**Case-study date:** 2026-08-27 (UTC+8)
**Contributor:** [Satoru-1006](https://github.com/Satoru-1006)
**Public repository:** `codex-windows-10061-proxy-recovery`
**Scope:** one Windows host, one Codex Desktop installation, one local Mihomo-family proxy setup, and one incident window

> This report is a redacted reconstruction of a real recovery session. It distinguishes directly preserved evidence from derived observations, contributor-reported facts, and hypotheses. It intentionally does not publish raw databases, full local configuration, authentication material, subscription data, or unredacted backups.

## 1. Executive summary

On 2026-08-27, Codex Desktop on Windows entered a repeated connection/reconnect state. The user-visible symptoms included:

```text
Reconnecting /5
Reconnecting... waiting for network
stream disconnected before completion: ... os error 10061
Connection failed: error sending request
```

The browser version of ChatGPT continued to work. A local proxy on `127.0.0.1:7892` was listening and could reach ChatGPT over HTTPS. This initially made the failure look like a WebSocket-specific Codex problem or a TUN/Fake-IP problem.

The most decisive artifact was a process-level TCP timeline. During 240 samples over approximately eight minutes, the failing Codex process repeatedly attempted `127.0.0.1:8890` in `SYN_SENT`; the reduction contains 54 observations across 36 sample timestamps. The before-fix TCP snapshot also showed a live listener on `127.0.0.1:7892`.

The proxy environment had multiple disagreeing layers:

| Layer | Before-fix value or observation |
| --- | --- |
| User/Machine/Process proxy snapshot | `HTTP_PROXY` and `HTTPS_PROXY` → `127.0.0.1:7892`; `ALL_PROXY` → `127.0.0.1:8890` |
| Codex-home dotenv file | `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` → `127.0.0.1:8890` |
| Local proxy service | `127.0.0.1:7892` was listening |
| Failing process | Repeated TCP attempts to `127.0.0.1:8890` |

The public conclusion is therefore deliberately narrower than “Codex always prefers `ALL_PROXY`”:

> In this incident, the effective proxy state used by the failing Codex process contained a dead localhost endpoint, and process-level observation proved that `codex.exe` actually attempted that endpoint.

Recovery rebuilt the Codex-home dotenv file with the live `7892` HTTP proxy, removed the stale global proxy entry, restarted Codex, and ran a real request. The preserved execution output contains `CODEX_REVIVED_OK`. The captured `codex doctor` run after the fix still showed an intermittent TLS EOF and an optional CDN timeout, so restoring the deterministic route did not make the proxy node perfect.

## 2. Evidence policy and confidence levels

This repository uses four evidence levels:

| Label | Meaning |
| --- | --- |
| **VERIFIED** | Directly present in a supplied artifact, or reproduced by a deterministic local calculation over a supplied artifact. |
| **DERIVED** | Computed from a supplied artifact, with the transformation described. |
| **USER-REPORTED** | Stated in the original investigation report or recovery notes but not independently preserved in the selected public artifact. |
| **UNCONFIRMED** | Plausible, but the supplied material does not establish it. |

The distinction matters here because the symptom, the effective endpoint, and the internal proxy-selection rule are different claims. The first two can be established by the case material; the last one requires code-path and version-specific evidence that was not fully captured for the historical Desktop build.

## 3. Incident profile

### 3.1 Symptoms

The incident report and UI observations describe:

- a persistent WebSocket reconnect loop;
- Windows connection-refused error `10061`;
- occasional very slow responses through fallback behavior;
- normal browser ChatGPT access through the local proxy;
- a local TUN/Fake-IP proxy stack active at the same time.

The user-visible error names the remote ChatGPT URL, but a connection-refused error can occur at an earlier local hop. In this case, the process-level trace identified that hidden hop as `127.0.0.1:8890`.

### 3.2 Environment retained for publication

Only incident-relevant, non-secret details are retained:

| Item | Public description |
| --- | --- |
| Operating system | Windows 11 x64, build `10.0.26200` |
| Codex core | `0.150.0-alpha.8` |
| Desktop package | `26.820.9563.0` |
| Local proxy | Mihomo-family proxy with a mixed listener on `127.0.0.1:7892` |
| TUN | Enabled during the incident; Fake-IP/DNS-hijack behavior was observed |
| Stale endpoint | `127.0.0.1:8890` |
| Authentication | ChatGPT login mode; no credentials are published |

The original report contained additional local paths, process IDs, runtime fingerprints, and proxy-client details. Those are either normalized, removed, or summarized because they do not improve reproduction and could identify the contributor's machine.

## 4. Fact table

| Claim | Confidence | Basis | Public treatment |
| --- | --- | --- | --- |
| `127.0.0.1:7892` had a listener in the before-fix snapshot | **VERIFIED** | `tcp-before.txt` contains a `Listen` row for port `7892` | Kept, with process ID removed |
| The listener was associated with `farmerCore.exe` | **USER-REPORTED** | Process/config investigation notes, not the redacted TCP row itself | Mentioned as a Mihomo-family local proxy; no machine path |
| User/machine/process proxy snapshot contained `HTTP(S)_PROXY=7892` and `ALL_PROXY=8890` | **VERIFIED** | `proxy-env-before.txt` | Kept |
| `%USERPROFILE%\.codex\.env` contained all three proxy variables pointing to `8890` | **VERIFIED** | `codex-dotenv-before-redacted.txt` | Kept, credential line removed |
| Historical `8890` listener check returned no listener | **USER-REPORTED** | Stated in the original report; raw command output was not preserved | Expressed with this limitation |
| `codex.exe` repeatedly targeted `127.0.0.1:8890` | **DERIVED / VERIFIED** | 240-sample timeline; 54 `SynSent` observations across 36 timestamps | Kept as the decisive process-level evidence |
| HTTPS through `7892` reached ChatGPT and returned `405` for a GET | **USER-REPORTED** | Described in the original report; raw curl transcript not selected | Described as reported, not as a preserved artifact |
| `codex doctor` after fix had no `10061` in the captured output | **VERIFIED** | `codex-doctor-after-fix.txt` | Kept |
| The captured doctor run produced WebSocket `HTTP 101` | **UNCONFIRMED** | The original report says a second run did; the supplied doctor file contains TLS EOF instead | Explicitly not claimed |
| A real request returned `CODEX_REVIVED_OK` | **VERIFIED** | `codex-exec-test.txt` | Kept |
| A post-fix 60-second trace had zero attempts to `8890` | **USER-REPORTED** | Stated in the original report; no post-fix trace file supplied | Explicitly not claimed as audited |

## 5. Investigation timeline

All times below are local time (UTC+8). “Exact timestamp unavailable” means the ordering came from the report/evidence chain rather than a preserved event timestamp.

| Time | Event | Evidence level | Interpretation |
| --- | --- | --- | --- |
| Around 19:16 | Codex Desktop began showing reconnects and `10061` | USER-REPORTED | The failure was first noticed in the Desktop UI |
| Unknown | Local port and HTTPS checks were performed | USER-REPORTED | The live proxy appeared reachable, but this did not identify the route used by `codex.exe` |
| Unknown | Proxy variables were inspected | VERIFIED | The public before-fix snapshot records a disagreement between `7892` and `8890` |
| 19:55:39–20:10:28 | TCP timeline captured 240 samples | DERIVED | Repeated `codex.exe → 8890` `SynSent` attempts coexisted with traffic involving `7892` |
| 19:43:08 | Proxy GUI application hang was recorded in the report | USER-REPORTED | The report places it after the incident began; the core was still described as serving `7892` |
| Around 20:09–20:11 | Proxy variables and `.codex/.env` were normalized | USER-REPORTED | The after-fix dotenv artifact preserves the resulting three-line state |
| 20:11–20:13 | Fresh Codex processes were started and observed | USER-REPORTED | The original report states that the fresh process no longer touched `8890`; the raw post-fix trace is not included |
| Around 20:14 | `codex doctor` was run | VERIFIED | The preserved run shows TLS EOF/CDN timeout, but no `10061` |
| 20:14:55 | Real model request completed | VERIFIED | `CODEX_REVIVED_OK` is present in the execution artifact |

The supplied first timeline is mostly sample headers without connection rows. It is retained only through the investigation notes, not as a primary public proof. The larger second timeline was reduced to the minimal endpoint/state table in [`evidence/tcp-timeline-before-fix.txt`](../evidence/tcp-timeline-before-fix.txt).

## 6. The decisive network observation

The raw second timeline has 17,331 lines and 240 sample headers. A deterministic parser was used only to:

1. detect sample headers;
2. split connection rows into whitespace-separated fields;
3. retain rows where the local or remote port was `8890` or `7892`;
4. count the `8890` rows by timestamp and state;
5. remove ephemeral ports, public IP addresses, and process IDs from the published reduction.

The resulting `8890` summary is:

```text
samples_total=240
codex_to_127.0.0.1:8890_observations=54
codex_to_127.0.0.1:8890_sample_timestamps=36
state_for_8890_observations=SynSent
```

Every retained `8890` observation is a connection attempt in `SYN_SENT`, not an established session. The same timeline repeatedly contains local-proxy activity involving `127.0.0.1:7892`. This is stronger than a generic “curl works” test because it identifies the actual destination selected by the failing process.

The timeline contains public remote IP addresses and many unrelated connections. Publishing them would add noise and expose more of the contributor's network context without improving the causal argument, so they were intentionally excluded.

## 7. Layered network model

The incident involved several layers that must be kept separate:

```text
Windows / proxy-client configuration
        ├── system proxy → 127.0.0.1:7892 (live in the capture)
        ├── user environment → 7892 for HTTP(S), 8890 for ALL
        └── %USERPROFILE%\.codex\.env → 8890 for HTTP(S) and ALL

Browser ChatGPT
        → system/browser route
        → 127.0.0.1:7892
        → proxy node
        → chatgpt.com

Failing Codex process
        → effective process proxy state
        → 127.0.0.1:8890
        → no intended listener
        → connection refused
        → os error 10061
        → reconnect loop
```

This model explains the apparently contradictory observations without requiring the claim that TUN itself was broken. A live system proxy and a stale Codex-home dotenv value can coexist.

## 8. Independent source review

The current `openai/codex` `main` branch was checked at commit [`5f49aba`](https://github.com/openai/codex/commit/5f49aba876922d6f2f55caa153bbb0ed1b46feba) on 2026-08-28.

### 8.1 Codex-home dotenv injection is real

The current [`codex-rs/arg0/src/lib.rs`](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/arg0/src/lib.rs#L297-L321) implementation:

- locates the Codex home directory;
- reads `.env` before creating the runtime threads;
- injects non-`CODEX_` variables into the process environment.

This supports the general mechanism: a stale proxy value in `%USERPROFILE%\.codex\.env` can be invisible in a shell-level inspection while still affecting a newly launched Codex process. It does not by itself prove which historical Desktop component selected `8890`.

### 8.2 WebSocket proxy resolution is route-dependent

The current [`codex-rs/websocket-client/src/dialer.rs`](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/websocket-client/src/dialer.rs#L44-L68) source states that the transport-default path delegates proxy resolution to the WebSocket transport's environment-aware dialer, which resolves `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY`.

The same file also contains explicit route handling for direct and selected proxy URLs. This means a public report should not collapse all versions and all feature paths into a statement such as “WebSocket always prefers `ALL_PROXY`.”

### 8.3 Explicit HTTP client route selection has its own order

The current [`codex-rs/http-client/src/outbound_proxy.rs`](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/http-client/src/outbound_proxy.rs#L352-L373) source shows protocol-specific environment fallback. For secure WebSocket resolution in the explicit route resolver, the order is `HTTPS_PROXY`, then `HTTP_PROXY`, then `ALL_PROXY`. The HTTPS route uses `HTTPS_PROXY` before `ALL_PROXY`.

That source review changes the wording of the case study in an important way:

```text
Observed:
  codex.exe repeatedly connected toward 127.0.0.1:8890.

Configuration:
  multiple proxy sources disagreed, and .codex/.env contained stale 8890 values.

Inference:
  the effective route used by that process resolved to the stale endpoint.

Not established:
  a universal ALL_PROXY precedence rule for every Codex version and route.
```

## 9. Root-cause analysis

### 9.1 Deterministic local cause

The deterministic local cause in this case was a dead localhost proxy endpoint present in the effective Codex process configuration:

```text
effective proxy state
        ↓
127.0.0.1:8890
        ↓
no successful listener / repeated SYN_SENT
        ↓
Windows connection refused
        ↓
os error 10061
        ↓
WebSocket reconnect loop
```

The most specific defensible statement is not “the remote endpoint rejected the connection.” It is “the failing process repeatedly attempted a local proxy endpoint that could not complete a TCP connection.”

### 9.2 Why the configuration was easy to miss

The user/machine/process snapshot and the Codex-home dotenv file did not agree. A shell-level command could show a valid `HTTP_PROXY`/`HTTPS_PROXY` pair on `7892` while the Codex startup path subsequently loaded `.codex/.env` and supplied stale `8890` values to the child process.

The stale value was also not visible from `config.toml`: the configuration summary was inspected and did not show a proxy entry. The raw config is deliberately not published because it contains local paths, project names, runtime locations, and a fingerprint-like value unrelated to this diagnosis.

### 9.3 Secondary performance factor

The proxy node itself showed poor performance in the original investigation: variable TLS handshake time, intermittent EOF, and an optional CDN timeout. The captured post-fix doctor run also shows a TLS EOF and CDN timeout. Those observations explain why a healthy route can still feel slow.

They are a separate layer from `10061`:

| Failure | Layer | Typical symptom |
| --- | --- | --- |
| Dead `127.0.0.1:8890` | Local route selection/listener | Immediate refusal, `10061`, repeated reconnects |
| Slow or unstable proxy node | Upstream route quality | TLS delay, EOF, timeout, slow fallback |
| TUN/Fake-IP behavior | Local interception/routing | Depends on rules, adapter state, and DNS path |

The recovery should fix the deterministic local route first and then evaluate node quality independently.

## 10. Why browser ChatGPT worked

The browser result proved only that the browser's route was healthy. In this case:

1. Windows/system proxy state pointed at the live `7892` listener.
2. The browser used that route successfully.
3. The Codex child process was observed targeting `8890`.

Therefore “browser works” and “Codex works” were not equivalent tests. The two clients did not necessarily inherit the same effective proxy configuration or use the same transport implementation.

The current upstream source reinforces this distinction: Codex loads `.codex/.env` before runtime initialization, and different client paths can either delegate environment resolution to a transport or use an explicit route resolver. The historical process trace is still needed to establish what happened on this specific machine.

## 11. Recovery procedure

This section is intentionally conditional. It is not a script that blindly removes proxy variables.

### Step 1: stop using the old process

Fully quit Codex Desktop and confirm that its Codex child process is gone. An already-running process retains its inherited environment even after a registry or file change.

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -in @("ChatGPT.exe", "codex.exe") } |
  Select-Object ProcessId, Name, ExecutablePath
```

Terminate only the Codex process tree you intentionally want to restart. Do not use a broad process-kill command.

### Step 2: inventory every proxy source

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
```

Do not paste a complete dotenv file into an issue or chat. Proxy URLs can contain credentials or private query strings.

### Step 3: verify each endpoint

```powershell
Test-NetConnection 127.0.0.1 -Port <proxy-port>
Get-NetTCPConnection -LocalPort <proxy-port> -ErrorAction SilentlyContinue
```

A proxy value is not a listener. Only repair a variable when the endpoint is demonstrably stale, incorrect, or no longer provided by the proxy client.

### Step 4: back up before editing

Keep a local backup outside the repository. The backup should be protected from accidental upload and should not be copied into a staging directory.

### Step 5: repair only the stale values

In this incident, the desired minimal state after verification was:

```text
HTTP_PROXY=http://127.0.0.1:7892
HTTPS_PROXY=http://127.0.0.1:7892
NO_PROXY=localhost,127.0.0.1,::1
```

`ALL_PROXY`, `WS_PROXY`, and `WSS_PROXY` were omitted because they were not needed for the tested HTTP-proxy path. On another machine, the correct result may be different. Do not copy the port number from this case without checking your own listener.

### Step 6: restart and verify the fresh process

After restarting Codex, identify the fresh `codex.exe` PID and observe its TCP destinations for at least 60 seconds:

```powershell
$codexPid = <fresh-codex.exe-pid>
Get-NetTCPConnection -OwningProcess $codexPid -ErrorAction SilentlyContinue |
  Sort-Object RemoteAddress, RemotePort |
  Format-Table State, LocalAddress, LocalPort, RemoteAddress, RemotePort
```

In the same case, the critical success condition would be no new attempts to the stale endpoint and normal activity through the verified live endpoint. The supplied public evidence contains the before-fix trace, not a raw post-fix trace, so this repository does not claim to independently audit that condition.

### Step 7: run layered verification

```powershell
codex doctor --json

codex exec --skip-git-repo-check "Reply with exactly: CODEX_RECOVERY_TEST"
```

Interpret the results by layer:

- `10061` to localhost: still a local endpoint/configuration problem;
- TLS EOF or timeout after reaching the proxy: likely route/node quality or policy;
- successful real request: end-to-end recovery for that run;
- browser success alone: insufficient to prove Codex process recovery.

## 12. Before-versus-after state

| Item | Before | After recovery session |
| --- | --- | --- |
| `HTTP_PROXY` in user snapshot | `127.0.0.1:7892` | `127.0.0.1:7892` |
| `HTTPS_PROXY` in user snapshot | `127.0.0.1:7892` | `127.0.0.1:7892` |
| `ALL_PROXY` in user snapshot | `127.0.0.1:8890` | removed from the minimal repaired state |
| `.codex/.env` | all three proxy routes pointed to `8890` | HTTP/HTTPS normalized to `7892`; global route omitted |
| Process trace | repeated attempts to `8890` | post-fix trace not preserved in this repository |
| `codex doctor` capture | not the same run | no `10061`; TLS EOF/CDN timeout remained |
| Real request | reconnect/fallback incident | `CODEX_REVIVED_OK` present |

The table intentionally avoids claiming that every post-fix transport probe passed. Recovery means the deterministic failure was removed and a real request completed; proxy-node performance remained a separate concern.

## 13. What did not prove or fix the root cause

### 13.1 A healthy browser session

It tested a different client path and did not identify the endpoint used by `codex.exe`.

### 13.2 A live `7892` listener

It proved that one candidate proxy was alive. It did not prove that all Codex routes selected that candidate.

### 13.3 A successful curl request

It proved that a manually selected HTTPS route could reach the remote service. It did not prove that the failing process used the same route.

### 13.4 TUN/Fake-IP suspicion

TUN was present and therefore a reasonable hypothesis. The evidence showed traffic flowing through the proxy stack, so TUN was not established as the deterministic cause in this case.

### 13.5 `config.toml` inspection

The config summary did not contain the stale proxy entry. The relevant state lived in environment sources, including `.codex/.env`.

### 13.6 Editing a file without restarting Codex

An existing process keeps its inherited environment. A file change without a full restart is not a valid recovery test.

## 14. Minimal reproduction model

This is a theoretical model for diagnosis, not a recommendation to disrupt a working machine:

```text
Windows host
  ├─ live local HTTP proxy on 127.0.0.1:<live-port>
  ├─ stale proxy variable on 127.0.0.1:<dead-port>
  ├─ Codex-home dotenv file that can inject proxy values
  └─ Codex process started after the stale value is effective

Result to look for:
  codex.exe → 127.0.0.1:<dead-port>
  → connection refused
  → os error 10061
  → reconnect loop
```

Do not intentionally create the dead route in a production setup. The public case is already supported by the captured timeline and does not require a fresh failure.

## 15. Product-improvement suggestions

These are suggestions, not claims that a particular implementation change is required:

1. `codex doctor` could show the effective proxy route class and a privacy-safe endpoint summary for HTTP and WebSocket separately.
2. A refused loopback proxy connection could identify the local proxy hop, not only the final remote URL.
3. Startup diagnostics could warn when an effective proxy URL points to a non-listening loopback port.
4. The reconnect UI could distinguish connection refusal, TLS EOF, timeout, proxy authentication, and remote HTTP errors.
5. A route-resolution trace could state whether the route came from `.codex/.env`, process environment, system proxy, managed policy, or a direct decision without exposing credentials.
6. After environment changes, the UI could remind users that a full process restart is required.
7. A short-lived diagnostic mode could report the endpoint class used by WebSocket and HTTPS fallback, making “browser works, Codex fails” easier to explain.

## 16. Related issue analysis

The issue tracker was searched on 2026-08-28. The current upstream contribution guide says that community contributions should be made through the issue tracker and that detailed bug reports, root-cause analyses, reproduction steps, and sanitized logs are useful; it also says external code contributions and pull requests are not accepted.

### 16.1 Candidate comparison

| Issue | Status at review | Similarity | Difference | Action |
| --- | --- | --- | --- | --- |
| [#38402](https://github.com/openai/codex/issues/38402) | Open | Windows, TUN, `10061`, WebSocket/HTTPS fallback | Existing discussion emphasizes system-proxy resolution; this case adds a Codex-home dotenv/process-level stale endpoint | **Primary comment target** |
| [#38885](https://github.com/openai/codex/issues/38885) | Open | Direct stale `$CODEX_HOME/.env` mechanism and misleading local refusal | macOS rather than Windows; its file-level reproduction is stronger than this supplied Windows artifact | Cross-reference only |
| [#20844](https://github.com/openai/codex/issues/20844) | Open | Windows, proxy environment, WebSocket/HTTPS asymmetry | Main focus is SOCKS5 versus explicit HTTP proxy behavior; not the same deterministic stale-endpoint case | Do not duplicate a long comment |
| [#29958](https://github.com/openai/codex/issues/29958) | Open | Windows WebSocket path differs from HTTPS/system proxy behavior | System-proxy route issue, not the primary evidence pattern here | Related reading |
| [#34312](https://github.com/openai/codex/issues/34312) | Closed | Same broad `10061`/fallback symptom | Closed and less specific than the open Windows report | No comment |

### 16.2 Why #38402 is the best primary target

The symptom and platform overlap are strongest there. A useful comment should not say that every `10061` report is caused by `ALL_PROXY`, nor should it paste the full case study. It should add one focused diagnostic lesson:

> When browser HTTPS works but Codex reconnects with `10061`, inspect `%USERPROFILE%\.codex\.env` and observe the actual `codex.exe` TCP destination before changing TUN/DNS settings.

The comment draft is intentionally short and includes the evidence limitation around the historical source route.

## 17. Security and redaction review

The public staging tree was built from selected artifacts rather than copied wholesale.

Removed or excluded:

- raw `.env` backups;
- API-key-bearing lines, including unrelated third-party credentials;
- ChatGPT auth files and account material;
- session identifiers and process IDs where not needed;
- complete `config.toml` with local paths and fingerprint-like values;
- the raw 1.1 MB timeline with unrelated public IP addresses;
- SQLite databases, logs, subscription/profile files, and full user-directory dumps;
- private local paths and the Windows account name.

The evidence files use placeholders such as `<REDACTED>`, `[ephemeral]`, and `PID redacted` where the exact value is not needed to audit the route. The raw local source material remains outside the staging directory.

## 18. Reproducibility notes

An independent reader can reproduce the diagnostic reasoning without access to the original machine:

1. Compare the proxy snapshot with the Codex-home dotenv snapshot.
2. Confirm that the two sources disagree.
3. Read the timeline summary and see repeated `SynSent` attempts to the stale endpoint.
4. Read the current upstream source links and verify that dotenv injection and route-specific proxy resolution are real concepts.
5. Read the after-fix dotenv and execution artifacts.
6. Re-run the safe checklist on a separate Windows machine without intentionally creating a failure.

What cannot be reproduced from this repository alone:

- the original proxy-node quality;
- the exact historical Desktop launcher environment;
- the missing raw post-fix process trace;
- the report-only HTTP `101` run;
- any account-specific or network-specific timing.

## 19. Final conclusion

This incident looked like a remote WebSocket or TUN failure because the browser still worked and the visible error named the ChatGPT endpoint. The decisive evidence came from following the process rather than trusting a generic connectivity test.

The strongest conclusion supported by the material is:

```text
Codex Desktop's failing process repeatedly targeted a stale localhost
proxy endpoint at 127.0.0.1:8890. The endpoint was present in the
effective proxy configuration while the intended local proxy was alive
on 127.0.0.1:7892. The refused local hop produced os error 10061 and
the reconnect loop. Rebuilding the Codex-home proxy environment,
restarting Codex, and issuing a real request restored operation for the
tested session.
```

The report does not claim a universal `ALL_PROXY` precedence rule, a universal TUN bug, or a universal fix. It documents a measurable configuration conflict and a process-level method for proving which route a failing Codex process actually used.

## Appendix A: selected evidence map

| Public file | Purpose |
| --- | --- |
| [`proxy-env-before.txt`](../evidence/proxy-env-before.txt) | User/Machine/Process proxy snapshot with the `7892`/`8890` disagreement |
| [`codex-dotenv-before-redacted.txt`](../evidence/codex-dotenv-before-redacted.txt) | Codex-home dotenv values before recovery, with credential line removed |
| [`codex-dotenv-after.txt`](../evidence/codex-dotenv-after.txt) | Minimal repaired dotenv state |
| [`tcp-before.txt`](../evidence/tcp-before.txt) | Redacted live-listener snapshot |
| [`tcp-timeline-before-fix.txt`](../evidence/tcp-timeline-before-fix.txt) | Derived 240-sample endpoint/state reduction |
| [`codex-doctor-after-fix.txt`](../evidence/codex-doctor-after-fix.txt) | Relevant after-fix doctor output, including its remaining TLS/CDN warnings |
| [`codex-exec-test.txt`](../evidence/codex-exec-test.txt) | Real request response proving a successful recovery run |
| [`websocket-probe.ps1`](../evidence/websocket-probe.ps1) | Credential-less CONNECT → TLS → WebSocket-upgrade diagnostic |

## Appendix B: upstream references

- [`openai/codex` contribution guide](https://github.com/openai/codex/blob/main/docs/contributing.md)
- [`arg0` dotenv loader](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/arg0/src/lib.rs#L297-L321)
- [`websocket-client` dialer](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/websocket-client/src/dialer.rs#L44-L68)
- [`http-client` outbound proxy resolver](https://github.com/openai/codex/blob/5f49aba876922d6f2f55caa153bbb0ed1b46feba/codex-rs/http-client/src/outbound_proxy.rs#L352-L373)
- [Primary related issue: #38402](https://github.com/openai/codex/issues/38402)
- [Cross-platform stale dotenv issue: #38885](https://github.com/openai/codex/issues/38885)
