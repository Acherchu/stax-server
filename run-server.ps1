# STAX SERVER - runs the Stax game servers on this PC, like a tiny Roblox data centre.
#
#   1. starts the server (Godot, no window) on port 24700 of this computer
#   2. starts a Cloudflare "quick tunnel" (cloudflared, no account needed), which gives it a public
#      https address like https://some-words.trycloudflare.com that friends anywhere can reach
#   3. writes that address into the Stax website's server.json and pushes it, so every Stax game
#      finds the server (a new address each time the TUNNEL starts)
#   4. keeps watching: if either one stops - OR the tunnel stops working while still running -
#      it starts that one again and publishes the new address
#
# The server and the tunnel are looked after separately on purpose. The tunnel is the flaky half
# (Cloudflare hands out quick tunnels for free and sometimes says no), and when it failed the old
# version of this script killed the server too and tried again immediately - a hot loop that kept
# Stax offline and made Cloudflare turn it down even harder. Now a tunnel that won't start is
# retried on its own, waiting twice as long each time (15s ... 5 min), while the server carries on
# running; and a server restart keeps the same tunnel address, so nothing has to be republished.
#
# A RUNNING TUNNEL IS NOT A WORKING TUNNEL (2026-10-11). Cloudflare revoked the quick tunnel and
# cloudflared sat there retrying for two days - "Unauthorized: Tunnel not found", over and over -
# without ever exiting. The watchdog only looked at whether the process had exited, so it thought
# everything was fine while the published address answered nobody. Now the tunnel is health
# checked as well (Test-Tunnel below), and a tunnel that is up but not working is replaced.
#
# Started at Windows sign-in by the "Stax Server" shortcut in the Startup folder (hidden window).
# To stop it: Task Manager -> end "powershell" running this, "cloudflared" and "Godot".
# Logs: C:\Users\arche\StaxServer\logs  (stax-server.log is the story of what happened)

$ErrorActionPreference = 'Continue'
# Spelled out, not worked out from $PSScriptRoot: started hidden at sign-in that can come back
# empty, and then cloudflared was launched with no path at all and died on the spot - which is
# what had everybody seeing "can't reach the Stax server" (2026-09-20).
$Here = 'C:\Users\arche\StaxServer'
if (-not (Test-Path $Here)) { $Here = $PSScriptRoot }
$Godot = 'C:\Users\arche\dev-tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe'
$Pack = Join-Path $Here 'stax-server.pck'
# The server runs from a COPY. Re-exporting stax-server.pck while a server is live changes the
# bytes under its open handle, and every resource it hasn't loaded yet then fails - rooms open
# but no game ever starts ("Cannot open file res://games/.../x.tscn"). That is exactly what took
# multiplayer down on 2026-10-11. The copy is made fresh at every start, so a re-export only ever
# takes effect on the next restart, which is what you want anyway.
$RunPack = Join-Path $Here 'stax-server-running.pck'
# NEVER call this $tunnel: the loop keeps the running tunnel in $tunnel, and PowerShell treats the
# two as ONE variable (names ignore case) - that wiped the path and cloudflared could never start
# again after the first restart. That was the "can't reach the Stax server" outage.
$TunnelExe = Join-Path $Here 'cloudflared.exe'
$Site = 'C:\Users\arche\StaxRelease\site'
$Port = 24700
$Logs = Join-Path $Here 'logs'
New-Item -ItemType Directory -Force $Logs | Out-Null

function Log($text) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $text
    Add-Content -Path (Join-Path $Logs 'stax-server.log') -Value $line
}

# Only one copy of this runner at a time.
$mutex = New-Object System.Threading.Mutex($false, 'Global\StaxServerRunner')
if (-not $mutex.WaitOne(0)) { exit }

function Publish-Address($url) {
    $wss = $url -replace '^https://', 'wss://'
    $json = '{ "url": "' + $wss + '" }' + "`n"
    $file = Join-Path $Site 'server.json'
    if ((Test-Path $file) -and ((Get-Content $file -Raw) -eq $json)) { return }
    Push-Location $Site
    try {
        git pull --rebase --quiet 2>&1 | Out-Null
        [IO.File]::WriteAllText($file, $json)
        git add server.json 2>&1 | Out-Null
        git commit --quiet -m "Stax server address: $wss" 2>&1 | Out-Null
        git push --quiet 2>&1 | Out-Null
        Log "published $wss"
    } finally { Pop-Location }
}

function Start-Server {
    # Anything left over from a previous run still owns port 24700, and the new one then says
    # "Already in use" and serves nobody (the tunnel answers 502). Clear them out first.
    Get-CimInstance Win32_Process -Filter "Name='Godot_v4.7.2-stable_win64_console.exe'" |
        Where-Object { $_.CommandLine -like '*stax-server.pck*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    try {
        Copy-Item -LiteralPath $Pack -Destination $RunPack -Force -ErrorAction Stop
    } catch {
        Log "WARNING: couldn't copy the pack ($($_.Exception.Message)) - running the original"
        $RunPack = $Pack
    }
    $p = Start-Process -FilePath $Godot -WindowStyle Hidden -PassThru `
        -ArgumentList @('--headless', '--main-pack', "`"$RunPack`"", '--', '--server', "--port=$Port", '--bind=127.0.0.1') `
        -RedirectStandardOutput (Join-Path $Logs 'server-out.txt') `
        -RedirectStandardError (Join-Path $Logs 'server-err.txt')
    Start-Sleep -Seconds 3
    $out = Join-Path $Logs 'server-out.txt'
    if ((Test-Path $out) -and ((Get-Content $out -Raw) -like '*Already in use*')) {
        Log "WARNING: port $Port was still taken - the server did not start properly"
    } else {
        Log "started the game server (pid $($p.Id)) on port $Port"
    }
    return $p
}

# Starts cloudflared and waits for the address it prints (on stderr). Returns the process and the
# address, or the process and $null if it never said one - the caller then waits a while and
# tries again rather than thrashing.
function Start-Tunnel {
    # By name as well as by path: a stuck cloudflared had left a second copy of itself behind,
    # and leaving one running means two tunnels fighting over the same port.
    Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $log = Join-Path $Logs 'tunnel.txt'
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    $p = $null
    try {
        $p = Start-Process -FilePath $TunnelExe -WindowStyle Hidden -PassThru -ErrorAction Stop `
            -ArgumentList @('tunnel', '--no-autoupdate', '--url', "http://127.0.0.1:$Port") `
            -RedirectStandardError $log -RedirectStandardOutput (Join-Path $Logs 'tunnel-out.txt')
    } catch {
        Log "  cloudflared would not start: $($_.Exception.GetType().Name): $($_.Exception.Message)"
        return @{ Process = $null; Url = $null }
    }
    $url = $null
    for ($i = 0; $i -lt 45 -and -not $url; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $log) {
            $m = Select-String -Path $log -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
            if ($m) { $url = $m.Matches[0].Value }
        }
        if ($p.HasExited -and -not $url) { break }
    }
    return @{ Process = $p; Url = $url }
}

# Is the published address actually reachable? The game server speaks WebSocket and refuses a
# plain HTTP request, so a WORKING tunnel answers with 502 - that counts as healthy, and so does
# any other real answer from the origin. A tunnel Cloudflare has thrown away gives no answer at
# all, or one of Cloudflare's own 530 / 1033 pages.
function Test-Tunnel($url) {
    if (-not $url) { return $false }
    $code = 0
    try {
        $r = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        $code = [int]$r.StatusCode
    } catch {
        $resp = $_.Exception.Response
        if ($resp -eq $null) { return $false }   # no answer: DNS gone, refused, timed out
        try { $code = [int]$resp.StatusCode } catch { $code = 0 }
    }
    if ($code -eq 0) { return $false }
    if ($code -eq 530 -or $code -eq 1033) { return $false }  # Cloudflare: origin/tunnel is gone
    return $true
}

# cloudflared saying this means the tunnel is dead no matter how alive the process looks.
function Test-TunnelRevoked {
    $log = Join-Path $Logs 'tunnel.txt'
    if (-not (Test-Path $log)) { return $false }
    $tail = Get-Content $log -Tail 25 -ErrorAction SilentlyContinue
    if (-not $tail) { return $false }
    return (($tail -join "`n") -match 'Unauthorized: Tunnel not found')
}

$server = $null
$tunnel = $null
$address = $null
$wait = 15  # how long to wait before trying the tunnel again, doubling up to 5 minutes
# Each health check is a plain HTTP request the game server rightly refuses, which puts one
# harmless "Invalid method or HTTP version" line in server-err.txt - so while all is well they
# are kept three minutes apart. The moment one FAILS the next comes 20 s later ($checkSoon), so
# a tunnel that has died is still spotted inside a minute.
$checkEvery = 180  # seconds between health checks while the address is answering
$checkSoon = 20    # seconds to the next one after a check has failed
$nextCheck = (Get-Date).AddSeconds($checkEvery)
$sick = 0          # health checks failed in a row; 3 (or one revoked message) and it is replaced

while ($true) {
    if ($server -eq $null -or $server.HasExited) {
        if ($server -ne $null) { Log 'the game server stopped - starting it again (the address stays the same)' }
        $server = Start-Server
        Start-Sleep -Seconds 3
    }

    if ($tunnel -eq $null -or $tunnel.HasExited) {
        if ($tunnel -ne $null) { Log 'the tunnel dropped - getting a new address' }
        $got = Start-Tunnel
        $tunnel = $got.Process
        if ($got.Url) {
            $address = $got.Url
            $wait = 15
            $sick = 0
            $nextCheck = (Get-Date).AddSeconds($checkEvery)
            Log "tunnel up: $address"
            Publish-Address $address
        } else {
            $why = ''
            if (Test-Path (Join-Path $Logs 'tunnel.txt')) {
                $why = (Get-Content (Join-Path $Logs 'tunnel.txt') -Tail 2) -join ' | '
            }
            Log "the tunnel wouldn't start (trying again in $wait s). Last thing it said: $why"
            if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force }
            $tunnel = $null
            Start-Sleep -Seconds $wait
            if ($wait -lt 300) { $wait = [Math]::Min($wait * 2, 300) }
            continue  # the game server is left running throughout
        }
    }

    # A tunnel that is RUNNING but not WORKING is the thing that kept Stax offline for two days.
    # One failure can be a blip, so it takes three in a row (about three minutes) - unless
    # cloudflared has said outright that the tunnel is gone, which is believed immediately.
    if ($tunnel -ne $null -and (Get-Date) -ge $nextCheck) {
        $nextCheck = (Get-Date).AddSeconds($checkEvery)
        if (Test-TunnelRevoked) {
            Log 'cloudflared says the tunnel was revoked ("Unauthorized: Tunnel not found")'
            $sick = 3
        } elseif (Test-Tunnel $address) {
            if ($sick -gt 0) { Log "the address is answering again after $sick failed check(s)" }
            $sick = 0
        } else {
            $sick++
            $nextCheck = (Get-Date).AddSeconds($checkSoon)  # confirm it quickly, don't wait 3 min
            Log "the published address did not answer (check $sick of 3): $address"
        }
        if ($sick -ge 3) {
            Log 'replacing the tunnel and publishing a new address'
            if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
            Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $tunnel = $null
            $address = $null
            $sick = 0
            continue  # the top of the loop starts a new one and publishes it
        }
    }

    Start-Sleep -Seconds 5
}
