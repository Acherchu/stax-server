# STAX SERVER - runs the Stax game servers on this PC, like a tiny Roblox data centre.
#
#   1. starts the server (Godot, no window) on port 24700 of this computer
#   2. starts a Cloudflare "quick tunnel" (cloudflared, no account needed), which gives it a public
#      https address like https://some-words.trycloudflare.com that friends anywhere can reach
#   3. writes that address into the Stax website's server.json and pushes it, so every Stax game
#      finds the server (a new address each time the tunnel starts)
#   4. keeps watching: if either one stops, starts both again
#
# Started at Windows sign-in by the "Stax Server" shortcut in the Startup folder (hidden window).
# To stop it: Task Manager -> end "powershell" running this, "cloudflared" and "Godot".
# Logs: C:\Users\arche\StaxServer\logs

$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
$Godot = 'C:\Users\arche\dev-tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe'
$Pack = Join-Path $Here 'stax-server.pck'
$Tunnel = Join-Path $Here 'cloudflared.exe'
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

while ($true) {
    Get-Process cloudflared -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Tunnel } | Stop-Process -Force
    $serverLog = Join-Path $Logs 'server-out.txt'
    $server = Start-Process -FilePath $Godot -WindowStyle Hidden -PassThru `
        -ArgumentList @('--headless', '--main-pack', "`"$Pack`"", '--', '--server', "--port=$Port", '--bind=127.0.0.1') `
        -RedirectStandardOutput $serverLog -RedirectStandardError (Join-Path $Logs 'server-err.txt')
    Start-Sleep -Seconds 3
    $tunnelLog = Join-Path $Logs 'tunnel.txt'
    Remove-Item -LiteralPath $tunnelLog -ErrorAction SilentlyContinue
    $tunnel = Start-Process -FilePath $Tunnel -WindowStyle Hidden -PassThru `
        -ArgumentList @('tunnel', '--no-autoupdate', '--url', "http://127.0.0.1:$Port") `
        -RedirectStandardError $tunnelLog -RedirectStandardOutput (Join-Path $Logs 'tunnel-out.txt')
    Log "started server (pid $($server.Id)) and tunnel (pid $($tunnel.Id))"

    # The tunnel prints its public address after a few seconds.
    $url = $null
    for ($i = 0; $i -lt 60 -and -not $url; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $tunnelLog) {
            $m = Select-String -Path $tunnelLog -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
            if ($m) { $url = $m.Matches[0].Value }
        }
    }
    if ($url) { Publish-Address $url } else { Log 'tunnel gave no address' }

    while (-not $server.HasExited -and -not $tunnel.HasExited) { Start-Sleep -Seconds 5 }
    Log "stopped (server exited: $($server.HasExited), tunnel exited: $($tunnel.HasExited)) - restarting"
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force }
    Start-Sleep -Seconds 5
}
