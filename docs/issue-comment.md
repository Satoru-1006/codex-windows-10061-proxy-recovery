I hit a very similar Windows `os error 10061` / reconnect symptom and was able to isolate a local configuration path that may be useful for comparison.

### Environment and symptoms

- Windows 11 x64, build `10.0.26200`
- Codex core `0.150.0-alpha.8`
- Mihomo-family local proxy with a live mixed listener on `127.0.0.1:7892`
- TUN/Fake-IP enabled
- Codex Desktop repeatedly showed `Reconnecting /5` and `waiting for network`
- Browser ChatGPT continued to work

### Decisive finding

The user/machine/process proxy snapshot showed:

```text
HTTP_PROXY / HTTPS_PROXY -> http://127.0.0.1:7892
ALL_PROXY                 -> http://127.0.0.1:8890
```

The Codex-home `.env` was more important: its `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` values all pointed at `127.0.0.1:8890`. A supplied process-level TCP timeline then recorded the failing `codex.exe` making 54 `SYN_SENT` observations to `127.0.0.1:8890` across 36 sample timestamps in a 240-sample window. The before-fix snapshot showed a listener on `7892`; the stale `8890` endpoint was the local hop associated with the refusal.

This does not prove that every Windows `10061` report has the same root cause, and it does not establish a universal `ALL_PROXY` precedence rule. The strongest case-specific conclusion is that the effective proxy state contained a dead localhost endpoint and the process trace showed Codex actually targeting it.

### Recovery and verification

1. Backed up the local proxy configuration.
2. Removed the stale `8890` route from the Codex-home environment.
3. Normalized `HTTP_PROXY` / `HTTPS_PROXY` to the live listener.
4. Fully restarted Codex so the new process inherited the repaired environment.
5. Ran a real request that returned `CODEX_REVIVED_OK`.

The captured post-fix `codex doctor` run still showed a transient `tls handshake eof` and an optional CDN timeout, so proxy-node quality remained a separate performance issue.

Full redacted evidence and the source-level proxy-resolution comparison:

https://github.com/Satoru-1006/codex-windows-10061-proxy-recovery

The main diagnostic lesson for this symptom is to inspect `%USERPROFILE%\.codex\.env` and observe the actual `codex.exe` TCP destination before changing TUN, DNS, or proxy software settings.
