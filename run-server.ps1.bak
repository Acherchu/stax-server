# STAX SERVER - runs the Stax game servers on this PC, like a tiny Roblox data centre.
#
#   1. starts the server (Godot, no window) on port 24700 of this computer
#   2. starts a Cloudflare "quick tunnel" (cloudflared, no account needed), which gives it a public
#      https address like https://some-words.trycloudflare.com that friends anywhere can reach
#   3. writes that address into the Stax website's server.json and pushes it, so every Stax game
#      finds the server (a new address each time the TUNNEL starts)
#   4. keeps watching: if either one stops, it starts that one again
#
# The server and the tunnel are looked after separately on purpose. The tunnel is the flaky half
# (Cloudflare hands out quick tunnels for free and sometimes says no), and when it failed the old
# version of this script killed the server too and tried again immediately - a hot loop that kept
# Stax offline and made Cloudflare turn it down even harder. Now a tunnel that won't start is
# retried on its own, waiting twice as long each time (15s ... 5 min), while the server carries on
# running; and a server restart keeps the same tunnel address, so nothing has to be republished.
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
    $p = Start-Process -FilePath $Godot -WindowStyle Hidden -PassThru `
        -ArgumentList @('--headless', '--main-pack', "`"$Pack`"", '--', '--server', "--port=$Port", '--bind=127.0.0.1') `
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
    Get-Process cloudflared -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $TunnelExe } | Stop-Process -Force
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

$server = $null
$tunnel = $null
$address = $null
$wait = 15  # how long to wait before trying the tunnel again, doubling up to 5 minutes

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

    Start-Sleep -Seconds 5
}
