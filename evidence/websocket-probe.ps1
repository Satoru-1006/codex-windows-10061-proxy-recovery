param(
    [string]$ProxyHost = "127.0.0.1",
    [int]$ProxyPort = 7892,
    [string]$TargetHost = "chatgpt.com",
    [int]$TimeoutMs = 15000
)

# Credential-less diagnostic only. It does not use account cookies, API keys,
# or a ChatGPT token. A successful CONNECT/TLS path may still receive a 4xx
# response because the request intentionally lacks authenticated WebSocket data.
$ErrorActionPreference = "Stop"

function Read-Headers([System.IO.Stream]$stream, [int]$timeoutMs) {
    $stream.ReadTimeout = $timeoutMs
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 1
    $deadline = [Environment]::TickCount + $timeoutMs
    while ([Environment]::TickCount -lt $deadline) {
        $n = $stream.Read($buf, 0, 1)
        if ($n -le 0) { return $sb.ToString() }
        [void]$sb.Append([char]$buf[0])
        if ($sb.ToString().EndsWith("`r`n`r`n")) { return $sb.ToString() }
    }
    return $sb.ToString()
}

$results = @{}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$tcp = New-Object System.Net.Sockets.TcpClient

try {
    $tcp.Connect($ProxyHost, $ProxyPort)
    $results["tcp_proxy"] = [Math]::Round($sw.Elapsed.TotalSeconds, 3).ToString() + "s"
    $ns = $tcp.GetStream()
    $req = "CONNECT $TargetHost`:443 HTTP/1.1`r`nHost: $TargetHost`:443`r`nProxy-Connection: Keep-Alive`r`n`r`n"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
    $ns.Write($bytes, 0, $bytes.Length)
    $ns.Flush()
    $connResp = Read-Headers $ns 15000
    $results["connect_resp"] = ($connResp -split "`r`n")[0]
    if ($connResp -notmatch "^HTTP/1\.[01] 200") {
        $results["error"] = "CONNECT failed"
        return $results
    }

    $ssl = New-Object System.Net.Security.SslStream($ns, $false)
    $ssl.AuthenticateAsClient($TargetHost)
    $results["tls"] = [Math]::Round($sw.Elapsed.TotalSeconds, 3).ToString() + "s"

    $key = [Convert]::ToBase64String((New-Object byte[] 16))
    $wsReq = "GET / HTTP/1.1`r`nHost: $TargetHost`r`nUpgrade: websocket`r`nConnection: Upgrade`r`nSec-WebSocket-Key: $key`r`nSec-WebSocket-Version: 13`r`n`r`n"
    $wb = [System.Text.Encoding]::ASCII.GetBytes($wsReq)
    $ssl.Write($wb, 0, $wb.Length)
    $ssl.Flush()
    $wsResp = Read-Headers $ssl $TimeoutMs
    $results["ws_resp"] = ($wsResp -split "`r`n")[0]
    $results["total"] = [Math]::Round($sw.Elapsed.TotalSeconds, 3).ToString() + "s"
} catch {
    $results["error"] = $_.Exception.GetType().Name + ": " + $_.Exception.Message
} finally {
    if ($tcp) { $tcp.Close() }
}

$results.GetEnumerator() | Sort-Object Name |
    ForEach-Object { Write-Output ("{0,-14} : {1}" -f $_.Key, $_.Value) }
