#Requires -Version 5.1
<#
Tests for HostDeck for Windows: the file format, the model rules and the network code.
The network tests use only this PC (127.0.0.1). They start small fake RDP and VNC servers.

Usage: powershell -NoProfile -ExecutionPolicy Bypass -File windows\Test-HostDeck.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HostDeck.ps1') -NoGui

$script:Failures = 0
$script:Count = 0
function Assert([string]$name, [bool]$condition) {
    $script:Count++
    if ($condition) { Write-Host "  ok    $name" } else { $script:Failures++; Write-Host "  FAIL  $name" -ForegroundColor Red }
}
function Assert-Throws([string]$name, [scriptblock]$block, [string]$like) {
    try { & $block; Assert $name $false } catch { Assert "$name ($($_.Exception.Message))" ($_.Exception.Message -like $like) }
}

Write-Host 'File format'
$v1 = @'
{
  "app" : "HostDeck",
  "exported" : "2026-10-05T14:30:55Z",
  "hosts" : [
    {
      "address" : "192.168.1.20",
      "id" : "8d1c7c51-2b7e-4d51-9c51-0f2a1e3b4c5d",
      "mac" : "00:11:22:33:44:55",
      "name" : "studio",
      "os" : "macos",
      "sshEnabled" : true,
      "sshKey" : "~/.ssh/id_ed25519",
      "user" : "ed",
      "vncEnabled" : false,
      "wakeEnabled" : true,
      "futureKey" : "ignored"
    },
    { "id" : "C10C8A0E-416A-4DFC-93AA-1DE87EC6C0D1", "name" : "router", "mac" : "", "os" : "network" },
    { "id" : "D10C8A0E-416A-4DFC-93AA-1DE87EC6C0D1", "name" : "old", "mac" : "001122334455" },
    { "id" : "E10C8A0E-416A-4DFC-93AA-1DE87EC6C0D1", "name" : "pc", "mac" : "", "os" : "windows", "port" : 3390, "vncPort" : null },
    { "id" : "F10C8A0E-416A-4DFC-93AA-1DE87EC6C0D1", "name" : "odd", "mac" : "", "os" : "beos", "wakeEnabled" : null }
  ],
  "settings" : { "broadcast" : "192.168.1.255", "port" : 7, "timeout" : 60 },
  "version" : 1
}
'@
$d = Read-HDFile $v1
Assert 'reads five hosts' ($d.Hosts.Count -eq 5)
$studio = $d.Hosts[0]
Assert 'upper-cases the id' ($studio.id -ceq '8D1C7C51-2B7E-4D51-9C51-0F2A1E3B4C5D')
Assert 'reads macos' ($studio.os -eq 'macos' -and $studio.user -eq 'ed' -and -not $studio.vncEnabled)
Assert 'missing port is null' ($null -eq $studio.port)
Assert '"network" reads as other' ($d.Hosts[1].os -eq 'other')
Assert 'other has Wake-on-LAN off by default' ($d.Hosts[1].wakeEnabled -eq $false)
Assert 'missing os reads as linux' ($d.Hosts[2].os -eq 'linux' -and $d.Hosts[2].wakeEnabled)
Assert 'unknown os reads as linux' ($d.Hosts[4].os -eq 'linux')
Assert 'null bool takes the default' ($d.Hosts[4].wakeEnabled -eq $true)
Assert 'reads the port' ($d.Hosts[3].port -eq 3390 -and $null -eq $d.Hosts[3].vncPort)
Assert 'reads the settings' ($d.Settings.broadcast -eq '192.168.1.255' -and $d.Settings.port -eq 7 -and $d.Settings.timeout -eq 60)

$frac = $v1 -replace '2026-10-05T14:30:55Z', '2026-10-05T14:30:55.1234567Z'
Assert 'accepts fractional seconds' ((Read-HDFile $frac).Hosts.Count -eq 5)
$offset = $v1 -replace '2026-10-05T14:30:55Z', '2026-10-05T15:30:55+01:00'
Assert 'accepts a time zone offset' ((Read-HDFile $offset).Hosts.Count -eq 5)
Assert-Throws 'rejects version 2' { Read-HDFile ($v1 -replace '"version" : 1', '"version" : 2') } '*format version 2*'
Assert-Throws 'rejects another app' { Read-HDFile ($v1 -replace '"app" : "HostDeck"', '"app" : "Other"') } '*not a HostDeck export*'
Assert-Throws 'rejects a bad date' { Read-HDFile ($v1 -replace '2026-10-05T14:30:55Z', 'yesterday') } '*export date*'
Assert-Throws 'rejects bad JSON' { Read-HDFile '{ "app": ' } '*not valid JSON*'
Assert-Throws 'rejects a host with no id' { Read-HDFile '[{ "name": "x", "mac": "" }]' } '*no valid id*'
$unsafe = $v1 -replace '"192.168.1.20"', '"-oProxyCommand=calc"'
Assert-Throws 'rejects an address that starts with -' { Read-HDFile $unsafe } '*studio*'
Assert-Throws 'rejects a user that starts with -' { Read-HDFile ($v1 -replace '"user" : "ed"', '"user" : "-x"') } '*studio*'
Assert 'reads an unsafe host from its own file' ((Read-HDFile $unsafe -AllowUnsafe).Hosts.Count -eq 5)

$bare = Read-HDFile '[{ "id": "8D1C7C51-2B7E-4D51-9C51-0F2A1E3B4C5D", "name": "one", "mac": "" }]'
Assert 'reads a bare array with one host' ($bare.Hosts.Count -eq 1 -and $bare.Hosts[0].name -eq 'one')
Assert 'reads an empty bare array' ((Read-HDFile '[]').Hosts.Count -eq 0)
$emptyExport = '{ "app": "HostDeck", "version": 1, "exported": "2026-10-05T14:30:55Z", "hosts": [] }'
Assert 'reads an export with no hosts' ((Read-HDFile $emptyExport).Hosts.Count -eq 0)

$text = New-HDFileText $d.Hosts @{ broadcast = '255.255.255.255'; port = 9; timeout = 180 }
$back = Read-HDFile $text
Assert 'round trip keeps the hosts' ($back.Hosts.Count -eq 5 -and $back.Hosts[3].port -eq 3390 -and $back.Hosts[1].os -eq 'other')
Assert 'round trip keeps the settings' ($back.Settings.port -eq 9 -and $back.Settings.timeout -eq 180)
Assert 'writer leaves out a null port' ($text -notmatch '"vncPort"' -and ([regex]::Matches($text, '"port":')).Count -eq 2)
Assert 'writer writes no null' ($text -notmatch 'null')
Assert 'writer writes a whole-second UTC date' ($text -match '"exported":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"')
$single = New-HDFileText @($d.Hosts[0]) @{ broadcast = '255.255.255.255'; port = 9; timeout = 180 }
Assert 'one host is still an array' ((ConvertFrom-Json $single).hosts -is [array])

$m = Merge-HDHosts @($d.Hosts[0], $d.Hosts[1]) @($bare.Hosts[0], (New-HDHost 'new'))
Assert 'merge replaces by id and adds the rest' ($m.Added -eq 1 -and $m.Replaced -eq 1 -and $m.List.Count -eq 3 -and $m.List[0].name -eq 'one')


Write-Host 'Save'
# Save twice: the second save replaces the file. Each later save of the app does this.
$saveDir = Join-Path ([IO.Path]::GetTempPath()) "hostdeck-save-$([guid]::NewGuid())"
[void](New-Item -ItemType Directory -Path $saveDir)
$saveFile = Join-Path $saveDir 'hostdeck.json'
Write-HDTextFile $saveFile (New-HDFileText @($d.Hosts[0]) @{ broadcast = '255.255.255.255'; port = 9; timeout = 180 })
Write-HDTextFile $saveFile (New-HDFileText $d.Hosts @{ broadcast = '255.255.255.255'; port = 9; timeout = 180 })
Assert 'a second save replaces the file' ((Read-HDFile ([IO.File]::ReadAllText($saveFile))).Hosts.Count -eq 5)
Assert 'a save leaves no temporary file' (-not (Test-Path "$saveFile.tmp"))
Assert 'a save writes no byte order mark' ([IO.File]::ReadAllBytes($saveFile)[0] -eq [byte][char]'{')
Remove-Item -LiteralPath $saveDir -Recurse
Write-Host 'Model'
$h = New-HDHost 'test'
Assert 'new host id is upper case' ($h.id -ceq $h.id.ToUpperInvariant())
Assert 'linux has ssh' ((@(Get-HDServices $h) -join ',') -eq 'ssh' -and (Get-HDPort $h 'ssh') -eq 22)
$h.os = 'windows'
Assert 'windows has rdp on 3389' ((@(Get-HDServices $h) -join ',') -eq 'rdp' -and (Get-HDServicePort $h) -eq 3389 -and (Get-HDConnectService $h) -eq 'rdp')
Assert 'windows can always wake' (Test-HDCanWake (@{ os = 'windows'; wakeEnabled = $false }))
$h.os = 'macos'
Assert 'macos has ssh and vnc' ((@(Get-HDServices $h) -join ',') -eq 'ssh,vnc' -and (Get-HDPort $h 'vnc') -eq 5900)
$h.sshEnabled = $false; $h.vncEnabled = $false
Assert 'macos with both off has ssh' ((@(Get-HDServices $h) -join ',') -eq 'ssh')
$h.sshEnabled = $false; $h.vncEnabled = $true; $h.vncPort = 5901
Assert 'macos with vnc only cannot Wake and Connect' ($null -eq (Get-HDConnectService $h) -and (Get-HDPort $h 'vnc') -eq 5901)
Assert 'MAC with any separator' ((Test-HDMacValid '00-11-22-33-44-55') -and (Test-HDMacValid '0011.2233.4455') -and -not (Test-HDMacValid '00:11:22'))
Assert 'ssh target' ((Get-HDSshTarget @{ user = 'ed'; address = 'host' }) -eq 'ed@host' -and (Get-HDSshTarget @{ user = ''; address = 'host' }) -eq 'host')
Assert 'expands ~ in the key path' ((Get-HDKeyPath @{ sshKey = '~/.ssh/id_ed25519' }) -eq (Join-Path $HOME '.ssh\id_ed25519'))
Assert 'missing key' (Test-HDKeyMissing @{ sshKey = '/Users/nobody/.ssh/id_ed25519' })
Assert 'unsafe address and user' ((Test-HDUnsafe @{ address = '-oX'; user = '' }) -and (Test-HDUnsafe @{ address = 'h'; user = '-l' }) -and -not (Test-HDUnsafe @{ address = 'h-1'; user = 'a-b' }))
Assert 'IPv4 check' ((Test-HDIPv4 '192.168.1.255') -and -not (Test-HDIPv4 '1') -and -not (Test-HDIPv4 '300.1.1.1') -and -not (Test-HDIPv4 'host'))

Write-Host 'Command line quoting'
Assert 'plain' ((ConvertTo-HDArg 'abc') -eq 'abc')
Assert 'empty' ((ConvertTo-HDArg '') -eq '""')
Assert 'space' ((ConvertTo-HDArg 'C:\My Keys\id') -eq '"C:\My Keys\id"')
Assert 'quote' ((ConvertTo-HDArg 'a"b') -eq '"a\"b"')
Assert 'trailing backslash' ((ConvertTo-HDArg 'C:\a b\') -eq '"C:\a b\\"')

Write-Host 'Wake packet'
$p = Get-HDMagicPacket '01:23:45:67:89:AB'
Assert 'packet is 102 bytes' ($p.Length -eq 102 -and $p -is [byte[]])
Assert 'packet starts with 6 x FF' (@($p[0..5] | Where-Object { $_ -eq 0xFF }).Count -eq 6)
Assert 'packet repeats the MAC 16 times' ($p[6] -eq 0x01 -and $p[11] -eq 0xAB -and $p[96] -eq 0x01 -and $p[101] -eq 0xAB)
Assert-Throws 'rejects a short MAC' { Get-HDMagicPacket '00:11' } '*Invalid MAC*'
Assert-Throws 'rejects a bad broadcast address' { Send-HDWake '00:11:22:33:44:55' 'host' 9 } '*Invalid broadcast*'
# The packet goes to the loopback address, so it does not wake anything.
$listener = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
$udpPort = $listener.Client.LocalEndPoint.Port
$listener.Client.ReceiveTimeout = 2000
$sentTo = Send-HDWake '01:23:45:67:89:AB' '127.0.0.1' $udpPort 1 -TargetOnly
$from = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
$got = $listener.Receive([ref]$from)
$listener.Close()
Assert "a packet arrives ($sentTo)" ($got.Length -eq 102 -and $got[101] -eq 0xAB)

Write-Host 'Network'
# A fake server on 127.0.0.1 that sends a reply to the first data, or a banner when the client connects.
function Start-FakeServer([byte[]]$reply, [switch]$Banner) {
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $l.Start()
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($l, $reply, $banner)
        $c = $l.AcceptTcpClient()
        $s = $c.GetStream()
        if (-not $banner) { $buf = New-Object byte[] 64; [void]$s.Read($buf, 0, 64) }
        $s.Write($reply, 0, $reply.Length)
        Start-Sleep -Milliseconds 300
        $c.Close()
        $l.Stop()
    }).AddArgument($l).AddArgument($reply).AddArgument([bool]$Banner)
    @{ Port = $l.LocalEndpoint.Port; PS = $ps; Handle = $ps.BeginInvoke() }
}
function Stop-FakeServer($f) { try { [void]$f.PS.EndInvoke($f.Handle) } catch { }; $f.PS.Dispose() }

Assert 'ping 127.0.0.1' (Test-HDPing '127.0.0.1')
Assert 'no ping reply from a TEST-NET address' (-not (Test-HDPing '192.0.2.1'))
Assert 'no ping for a name that does not resolve' (-not (Test-HDPing 'no-such-host.invalid'))

$closed = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$closed.Start(); $closedPort = $closed.LocalEndpoint.Port; $closed.Stop()
Assert 'closed port' (-not (Test-HDPort '127.0.0.1' $closedPort))
Assert 'port 0 is not valid' (-not (Test-HDPort '127.0.0.1' 0))

$f = Start-FakeServer ([byte[]](0x03, 0x00, 0x00, 0x13, 0x0E, 0xD0, 0, 0, 0x12, 0x34, 0, 0x02, 0x00, 0x08, 0x00, 0x02, 0, 0, 0))
Assert 'RDP Connection Confirm' (Test-HDRdp '127.0.0.1' $f.Port)
Stop-FakeServer $f
$f = Start-FakeServer ([Text.Encoding]::ASCII.GetBytes("SSH-2.0-OpenSSH_9.5`r`n"))
Assert 'not RDP' (-not (Test-HDRdp '127.0.0.1' $f.Port))
Stop-FakeServer $f
$f = Start-FakeServer ([Text.Encoding]::ASCII.GetBytes("RFB 003.889`n")) -Banner
Assert 'RFB banner' (Test-HDRfb '127.0.0.1' $f.Port)
Stop-FakeServer $f
$f = Start-FakeServer ([Text.Encoding]::ASCII.GetBytes("SSH-2.0-OpenSSH_9.5`r`n")) -Banner
Assert 'not RFB' (-not (Test-HDRfb '127.0.0.1' $f.Port))
Stop-FakeServer $f
$f = Start-FakeServer ([Text.Encoding]::ASCII.GetBytes("x")) -Banner
$probe = Invoke-HDProbe @{ address = '127.0.0.1'; os = 'linux'; port = $f.Port }
Assert 'probe: ready' ($probe.Status -eq 'ready' -and (@($probe.Open) -join ',') -eq 'ssh')
Stop-FakeServer $f
$probe = Invoke-HDProbe @{ address = '127.0.0.1'; os = 'linux'; port = $closedPort }
Assert 'probe: ping only' ($probe.Status -eq 'pingOnly' -and @($probe.Open).Count -eq 0)

if (Get-HDSsh) {
    $keyFile = Join-Path ([IO.Path]::GetTempPath()) 'hostdeck-test-key'
    Set-Content -LiteralPath $keyFile -Value 'not a key'
    $r = Invoke-HDSshLogin @{ os = 'linux'; address = '127.0.0.1'; port = $closedPort; user = 'nobody'; sshKey = $keyFile }
    Assert "ssh login fails on a closed port ($($r.Message))" (-not $r.Ok -and $r.Message -match 'refused|connect')
    $r = Invoke-HDSshLogin @{ os = 'linux'; address = '-oProxyCommand=cmd /c echo pwned>%TEMP%\hostdeck-pwned.txt'; port = 22; user = ''; sshKey = $keyFile }
    Assert 'ssh does not read the target as an option' (-not $r.Ok -and -not (Test-Path (Join-Path $env:TEMP 'hostdeck-pwned.txt')))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-HDSshLogin @{ os = 'linux'; address = '192.0.2.1'; port = 22; user = ''; sshKey = $keyFile } { $sw.ElapsedMilliseconds -gt 500 }
    Assert "ssh login stops when cancelled ($($sw.ElapsedMilliseconds) ms)" ($r.Cancelled -and $sw.ElapsedMilliseconds -lt 2000)
    Remove-Item -LiteralPath $keyFile
} else {
    Write-Host '  skip  ssh.exe is not installed'
}

Write-Host 'Run'
$queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$cancel = [Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
$job = @{ Host = @{ id = 'X'; name = 'local'; os = 'linux'; address = '127.0.0.1'; port = $closedPort; mac = ''; user = ''; sshKey = '' }
          RunId = 'r1'; Wake = $false; Connect = $false; Queue = $queue; Cancel = $cancel; Timeout = 5 }
Invoke-HDRun $job
$messages = @($queue.ToArray())
$log = @($messages | Where-Object { $_.Kind -eq 'log' } | ForEach-Object { "$($_.Tag) $($_.Text)" })
Assert 'test run pings, then finds the port closed' (($log -join '|') -match 'PING Testing.*PING local responds.*SSH Port \d+ is not answering')
Assert 'test run marks ssh as failed' (@($messages | Where-Object { $_.Kind -eq 'failed' -and $_.Service -eq 'ssh' }).Count -eq 1)
$queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$job.Queue = $queue
$job.Host.address = '-oProxyCommand=x'
Invoke-HDRun $job
Assert 'run refuses an unsafe address' (@($queue.ToArray() | Where-Object { $_.Tag -eq 'ERROR' -and $_.Text -like '*starts with*' }).Count -eq 1)

Write-Host 'Icon'
$ico = Join-Path ([IO.Path]::GetTempPath()) 'hostdeck-test.ico'
Save-HDIconFile $ico
$bytes = [IO.File]::ReadAllBytes($ico)
Assert 'icon file has 6 images' ($bytes[2] -eq 1 -and $bytes[4] -eq 6 -and $bytes.Length -gt 1000)
$icon = [Drawing.Icon]::new($ico, 32, 32)
Assert 'Windows reads the icon' ($icon.Width -eq 32)
$icon.Dispose()
Remove-Item -LiteralPath $ico

Write-Host ''
if ($script:Failures) { Write-Host "$script:Failures of $script:Count tests failed." -ForegroundColor Red; exit 1 }
Write-Host "All $script:Count tests passed." -ForegroundColor Green
