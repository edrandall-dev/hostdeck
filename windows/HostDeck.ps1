#Requires -Version 5.1
<#
HostDeck for Windows: check, wake and connect to the hosts on your network.

This is the Windows version of the macOS app in ../Sources/HostDeck.swift. It reads and writes the same file
format, which ../docs/FILE-FORMAT.md defines. It runs on Windows PowerShell 5.1, which every Windows 10 and 11
PC has, so it needs no install of other software.

The app sends Wake-on-LAN packets, then checks each host in stages: ping, then the service port, then a test
of the service. For a Windows host, the service is RDP. For a Linux or Other host, the service is SSH, and the
app tries a real login if an SSH key is set. A macOS host has SSH, Screen Sharing, or both.

Usage:
  HostDeck.ps1                       Start the app.
  HostDeck.ps1 -Select <name>        Start with this host selected.
  HostDeck.ps1 -Select <name> -Action wake
                                     Then do Wake, Wake and Connect (wakeconnect) or Test (test) for that host.
                                     For example, a desktop shortcut can wake one host.
  HostDeck.ps1 -DataDir <folder>     Keep the hosts in another folder, for example to test.
  HostDeck.ps1 -Screenshot <file>    Save a picture of the window as a PNG file after a few seconds, then stop.
                                     Use it with -Select and -Action to check a change to the layout.
  . .\HostDeck.ps1 -NoGui            Load the functions only. Test-HostDeck.ps1 and Install.ps1 use this.
#>
[CmdletBinding()]
param(
    [switch]$NoGui,
    [string]$DataDir = (Join-Path $env:APPDATA 'HostDeck'),
    [string]$Screenshot,
    [int]$ScreenshotDelay = 6,
    [string]$Select,
    [ValidateSet('wake', 'wakeconnect', 'test')]
    [string]$Action
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# The format version of the hosts file that this version reads and writes. See docs/FILE-FORMAT.md.
$HDFormatVersion = 1
$HDHelpUrl = 'https://www.edrandall.uk/lab-notes/hostdeck/'

# MARK: - Engine

# The model and network functions. The window runs them in background runspaces, so they must not use the
# window or script variables. The runspaces get this code as text.
$EngineBlock = {
    # The services of a host, in the order that HostDeck tests them. Callers wrap the result in @().
    function Get-HDServices($h) {
        switch ($h.os) {
            'windows' { 'rdp' }
            'macos' {
                $list = @()
                if ($h.sshEnabled) { $list += 'ssh' }
                if ($h.vncEnabled) { $list += 'vnc' }
                if ($list.Count -eq 0) { $list = @('ssh') }
                $list
            }
            default { 'ssh' }
        }
    }

    # The SSH port, or the RDP port for a Windows host.
    function Get-HDServicePort($h) {
        if ($null -ne $h.port) { return [int]$h.port }
        if ($h.os -eq 'windows') { 3389 } else { 22 }
    }

    function Get-HDPort($h, [string]$svc) {
        if ($svc -ne 'vnc') { return Get-HDServicePort $h }
        if ($null -ne $h.vncPort) { [int]$h.vncPort } else { 5900 }
    }

    function Get-HDLabel([string]$svc) {
        switch ($svc) { 'ssh' { 'SSH' } 'rdp' { 'RDP' } 'vnc' { 'Screen Sharing' } }
    }

    # The tag for the log.
    function Get-HDTag([string]$svc) { if ($svc -eq 'vnc') { 'VNC' } else { Get-HDLabel $svc } }

    # Linux, macOS and Other hosts can turn off Wake-on-LAN. Windows hosts always have it.
    function Test-HDCanWake($h) { $h.os -eq 'windows' -or [bool]$h.wakeEnabled }

    function Test-HDMacValid([string]$mac) { ($mac -replace '[^0-9A-Fa-f]', '').Length -eq 12 }

    # The service that Wake and Connect opens: SSH if the host has it, else RDP.
    function Get-HDConnectService($h) {
        $services = @(Get-HDServices $h)
        if ($services -contains 'ssh') { 'ssh' } elseif ($services -contains 'rdp') { 'rdp' }
    }

    function Get-HDSshTarget($h) { if ($h.user) { "$($h.user)@$($h.address)" } else { [string]$h.address } }

    # A leading ~ means the home folder, as on the Mac.
    function Get-HDKeyPath($h) {
        $k = [string]$h.sshKey
        if ($k -eq '~') { return $HOME }
        if ($k -match '^~[\\/]') { return Join-Path $HOME ($k.Substring(2) -replace '/', '\') }
        $k
    }

    # A file from a Mac has a Mac path, so the key can be missing on this PC.
    function Test-HDKeyMissing($h) { [bool]$h.sshKey -and -not [IO.File]::Exists((Get-HDKeyPath $h)) }

    # ssh reads a value that starts with "-" as an option, for example -oProxyCommand=, which runs a command.
    # HostDeck passes "--" before the target, and also refuses these values.
    function Test-HDAddressUnsafe($h) { ([string]$h.address).StartsWith('-') }
    function Test-HDUserUnsafe($h) { ([string]$h.user).StartsWith('-') }
    function Test-HDUnsafe($h) { (Test-HDAddressUnsafe $h) -or (Test-HDUserUnsafe $h) }

    # Quote one argument for a Windows command line, by the rules of CommandLineToArgvW.
    function ConvertTo-HDArg([string]$a) {
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
        $out = '"'
        $slashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') { $out += ('\' * (2 * $slashes + 1)) + '"' } else { $out += ('\' * $slashes) + $ch }
            $slashes = 0
        }
        $out + ('\' * (2 * $slashes)) + '"'
    }

    function Get-HDSsh {
        $p = Join-Path $env:windir 'System32\OpenSSH\ssh.exe'
        if ([IO.File]::Exists($p)) { return $p }
        $c = Get-Command ssh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $c.Source }
    }

    # 6 bytes of 0xFF, then the MAC address 16 times.
    function Get-HDMagicPacket([string]$mac) {
        $hex = $mac -replace '[^0-9A-Fa-f]', ''
        if ($hex.Length -ne 12) { throw "Invalid MAC address: $mac" }
        $bytes = New-Object byte[] 102
        for ($i = 0; $i -lt 6; $i++) { $bytes[$i] = 0xFF }
        for ($r = 0; $r -lt 16; $r++) {
            for ($i = 0; $i -lt 6; $i++) { $bytes[6 + $r * 6 + $i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        }
        , $bytes
    }

    # The IPv4 address and the subnet broadcast address of each network adapter that is up.
    function Get-HDInterfaces {
        foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
            foreach ($u in $nic.GetIPProperties().UnicastAddresses) {
                if ($u.Address.AddressFamily -ne 'InterNetwork' -or $null -eq $u.IPv4Mask) { continue }
                $a = $u.Address.GetAddressBytes()
                if ($a[0] -eq 169 -and $a[1] -eq 254) { continue }
                $m = $u.IPv4Mask.GetAddressBytes()
                $b = New-Object byte[] 4
                for ($i = 0; $i -lt 4; $i++) { $b[$i] = $a[$i] -bor (255 -bxor $m[$i]) }
                [pscustomobject]@{ Name = $nic.Name; Address = $u.Address; Broadcast = [Net.IPAddress]::new($b) }
            }
        }
    }

    function Test-HDIPv4([string]$text) {
        $ip = $null
        $text -match '^\d{1,3}(\.\d{1,3}){3}$' -and [Net.IPAddress]::TryParse($text, [ref]$ip)
    }

    # Send the wake packet. Broadcasts are not acknowledged and Wi-Fi does not retransmit them, so send a few copies.
    # Windows sends a broadcast out of one adapter only, which can be the wrong one, for example a virtual adapter.
    # So HostDeck also sends from each adapter that is up, to the address in Settings and to the subnet broadcast
    # of that adapter. Return the addresses that it sent to, for the log.
    # -TargetOnly sends to the address in Settings only. The tests use it, so that they send nothing to the LAN.
    function Send-HDWake([string]$mac, [string]$broadcast, [int]$port, [int]$count = 5, [switch]$TargetOnly) {
        $packet = Get-HDMagicPacket $mac
        if (-not (Test-HDIPv4 $broadcast)) { throw "Invalid broadcast address: $broadcast" }
        if ($port -lt 1 -or $port -gt 65535) { throw "Invalid UDP port: $port" }
        $target = [Net.IPAddress]::Parse($broadcast)

        $sends = @(@{ From = [Net.IPAddress]::Any; To = $target })
        foreach ($nic in @(if (-not $TargetOnly) { Get-HDInterfaces })) {
            $sends += @{ From = $nic.Address; To = $target }
            if (-not $nic.Broadcast.Equals($target)) { $sends += @{ From = $nic.Address; To = $nic.Broadcast } }
        }

        $clients = @()
        $errors = @()
        try {
            foreach ($s in $sends) {
                try {
                    $udp = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new($s.From, 0))
                    $udp.EnableBroadcast = $true
                    $clients += @{ Client = $udp; To = [Net.IPEndPoint]::new($s.To, $port) }
                } catch { $errors += $_.Exception.Message }
            }
            $sent = @()
            for ($i = 0; $i -lt $count; $i++) {
                foreach ($c in $clients) {
                    try {
                        [void]$c.Client.Send($packet, $packet.Length, $c.To)
                        $sent += [string]$c.To.Address
                    } catch { $errors += $_.Exception.Message }
                }
                if ($i -lt $count - 1) { Start-Sleep -Milliseconds 100 }
            }
        } finally {
            foreach ($c in $clients) { $c.Client.Close() }
        }
        if ($sent.Count -eq 0) { throw "Network error: $($errors | Select-Object -First 1)" }
        ($sent | Select-Object -Unique) -join ', '
    }

    # One ICMP echo with a one second timeout. True if the host replies.
    function Test-HDPing([string]$address, [int]$TimeoutMs = 1000) {
        $p = [Net.NetworkInformation.Ping]::new()
        try { $p.Send($address, $TimeoutMs).Status -eq 'Success' } catch { $false } finally { $p.Dispose() }
    }

    # An IP address, or the first IPv4 address of a hostname, else its first address.
    function Resolve-HDAddress([string]$address) {
        $ip = $null
        if ([Net.IPAddress]::TryParse($address, [ref]$ip)) { return $ip }
        try { $all = @([Net.Dns]::GetHostAddresses($address)) } catch { return $null }
        $v4 = @($all | Where-Object { $_.AddressFamily -eq 'InterNetwork' })
        if ($v4.Count) { $v4[0] } elseif ($all.Count) { $all[0] }
    }

    # Open a TCP connection. With no -Send and no -Receive, return an empty byte array when the connection opens.
    # With -Send, send the bytes and return the first reply. With -Receive, return the first data that the server
    # sends. Return $null on failure or timeout.
    function Invoke-HDTcp([string]$address, [int]$port, [byte[]]$Send, [switch]$Receive, [int]$TimeoutMs = 3000) {
        if ($port -lt 1 -or $port -gt 65535) { return $null }
        $client = $null
        try {
            $ip = Resolve-HDAddress $address
            if ($null -eq $ip) { return $null }
            $client = [Net.Sockets.TcpClient]::new($ip.AddressFamily)
            if (-not $client.ConnectAsync($ip, $port).Wait($TimeoutMs)) { return $null }
            if ($null -eq $Send -and -not $Receive) { return , [byte[]]@() }
            $stream = $client.GetStream()
            $stream.ReadTimeout = $TimeoutMs
            if ($null -ne $Send) { $stream.Write($Send, 0, $Send.Length) }
            $buffer = New-Object byte[] 1024
            $n = $stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { return $null }
            return , [byte[]]$buffer[0..($n - 1)]
        } catch {
            return $null
        } finally {
            if ($client) { $client.Close() }
        }
    }

    function Test-HDPort([string]$address, [int]$port) {
        $r = Invoke-HDTcp $address $port
        $null -ne $r
    }

    # True if the server sends an X.224 Connection Confirm. This proves an RDP service, not only an open port.
    function Test-HDRdp([string]$address, [int]$port) {
        # X.224 Connection Request with an RDP negotiation request (TLS and CredSSP).
        $request = [byte[]](0x03, 0x00, 0x00, 0x13,             # TPKT header, length 19
                            0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00, # X.224 Connection Request
                            0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00) # RDP_NEG_REQ
        $r = Invoke-HDTcp $address $port -Send $request -TimeoutMs 5000
        $null -ne $r -and $r.Length -ge 6 -and $r[0] -eq 0x03 -and $r[5] -eq 0xD0
    }

    # True if the server sends an RFB banner, for example "RFB 003.889". This proves a VNC service.
    function Test-HDRfb([string]$address, [int]$port) {
        $r = Invoke-HDTcp $address $port -Receive -TimeoutMs 5000
        $null -ne $r -and $r.Length -ge 4 -and [Text.Encoding]::ASCII.GetString($r, 0, 4) -eq 'RFB '
    }

    # Log in with the key of the host. BatchMode stops ssh from asking for a password.
    # The test passes when ssh reports "Authenticated to", so it does not depend on a remote command:
    # RouterOS has its own command line, not a Unix shell. Linux and macOS hosts run "exit 0". Other hosts get
    # no command, and HostDeck stops ssh after the login. $IsCancelled returns $true to stop the test.
    function Invoke-HDSshLogin($h, [scriptblock]$IsCancelled = { $false }) {
        $ssh = Get-HDSsh
        if (-not $ssh) { return @{ Ok = $false; Cancelled = $false; Message = 'ssh.exe not found. Add the OpenSSH Client in Settings > System > Optional features.' } }
        $argv = @('-v', '-T', '-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes',
                  '-o', 'IdentitiesOnly=yes', '-i', (Get-HDKeyPath $h), '-p', [string](Get-HDServicePort $h), '--', (Get-HDSshTarget $h))
        if ($h.os -eq 'linux' -or $h.os -eq 'macos') { $argv += 'exit 0' }

        $psi = [Diagnostics.ProcessStartInfo]::new($ssh, (($argv | ForEach-Object { ConvertTo-HDArg $_ }) -join ' '))
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        try { $p = [Diagnostics.Process]::Start($psi) } catch { return @{ Ok = $false; Cancelled = $false; Message = $_.Exception.Message } }

        $lines = [Collections.Generic.List[string]]::new()
        $ok = $false
        $cancelled = $false
        try {
            $p.StandardInput.Close()
            [void]$p.StandardOutput.ReadToEndAsync()
            $deadline = (Get-Date).AddSeconds(20)
            $read = $p.StandardError.ReadLineAsync()
            while ($true) {
                if (& $IsCancelled) { $cancelled = $true; break }
                if ((Get-Date) -gt $deadline) { $lines.Add('No result after 20 seconds'); break }
                if (-not $read.Wait(200)) { continue }
                $line = $read.Result
                if ($null -eq $line) { break }
                $lines.Add($line)
                if ($line.Contains('Authenticated to')) { $ok = $true; break }
                $read = $p.StandardError.ReadLineAsync()
            }
        } catch {
            $lines.Add($_.Exception.Message)
        } finally {
            if (-not $p.HasExited) { try { $p.Kill() } catch { } }
            $p.Dispose()
        }
        # The last line that is not debug output.
        $message = $lines | Where-Object { $_ -and -not $_.StartsWith('debug') -and -not $_.StartsWith('OpenSSH') } | Select-Object -Last 1
        @{ Ok = $ok; Cancelled = $cancelled; Message = [string]$message }
    }

    # Ping, then try each service port. Ready if all the ports answer, pingOnly if some do not.
    function Invoke-HDProbe($h) {
        if (-not (Test-HDPing $h.address)) { return @{ Status = 'down'; Open = @() } }
        $services = @(Get-HDServices $h)
        $open = @(foreach ($s in $services) { if (Test-HDPort $h.address (Get-HDPort $h $s)) { $s } })
        @{ Status = $(if ($open.Count -eq $services.Count) { 'ready' } else { 'pingOnly' }); Open = $open }
    }

    # A Wake or Test run. With Wake, send the packet, then wait for each stage until the timeout.
    # Without it, test each stage one time. The run sends its messages to $Job.Queue, and the window shows them.
    function Invoke-HDRun($Job) {
        $h = $Job.Host
        $id = $h.id
        $run = $Job.RunId
        $wake = $Job.Wake
        $addr = [string]$h.address

        function Send-Message([hashtable]$m) { $m.Id = $id; $m.Run = $run; $Job.Queue.Enqueue($m) }
        function Write-Log([string]$tag, [string]$text) {
            Send-Message @{ Kind = 'log'; Time = (Get-Date).ToString('HH:mm:ss'); Tag = $tag; Text = $text }
        }
        function Test-Cancelled { $Job.Cancel.ContainsKey($run) }
        function Set-Failed([string]$svc) { $failed.Add($svc); Send-Message @{ Kind = 'failed'; Service = $svc } }
        # Repeat the check once a second until it passes, the deadline passes, or the run is cancelled.
        function Wait-Until([datetime]$deadline, [scriptblock]$check) {
            while (-not (Test-Cancelled)) {
                if (& $check) { return $true }
                if ((Get-Date) -ge $deadline) { return $false }
                for ($i = 0; $i -lt 10 -and -not (Test-Cancelled); $i++) { Start-Sleep -Milliseconds 100 }
            }
            $false
        }
        function Stop-Stage([string]$stage, [string]$what, [string[]]$services) {
            if (Test-Cancelled) { return Write-Log 'CANCEL' 'Stopped' }
            foreach ($s in $services) { Set-Failed $s }
            Write-Log $stage $(if ($wake) { "$what after $($Job.Timeout) seconds" } else { $what })
        }

        $failed = [Collections.Generic.List[string]]::new()
        $open = [Collections.Generic.List[string]]::new()

        if ($wake) {
            Write-Log 'START' "Sending wake packet to $($h.mac) via $($Job.Broadcast):$($Job.Port)"
            try {
                $to = Send-HDWake $h.mac $Job.Broadcast $Job.Port
                Write-Log 'START' "Sent to $to"
            } catch {
                return Write-Log 'ERROR' $_.Exception.Message
            }
        }
        if (-not $addr) { return Write-Log $(if ($wake) { 'DONE' } else { 'ERROR' }) "Set an address to test $($h.name)." }
        if (Test-HDUnsafe $h) { return Write-Log 'ERROR' "The address or user starts with `"-`". Change it to test $($h.name)." }

        $deadline = if ($wake) { (Get-Date).AddSeconds($Job.Timeout) } else { Get-Date }
        $services = @(Get-HDServices $h)

        Write-Log 'PING' $(if ($wake) { "Waiting for $($h.name) to respond at $addr" } else { "Testing $addr" })
        if (-not (Wait-Until $deadline { Test-HDPing $addr })) {
            Send-Message @{ Kind = 'status'; Status = 'down'; Open = @() }
            return Stop-Stage 'PING' 'No reply to ping' $services
        }
        Send-Message @{ Kind = 'status'; Status = 'pingOnly'; Open = @() }
        Write-Log 'PING' "$($h.name) responds to ping"

        # Test each service. A failed service does not stop the test of the next one.
        foreach ($svc in $services) {
            $p = Get-HDPort $h $svc
            $tag = Get-HDTag $svc
            Write-Log $tag "Waiting for $(Get-HDLabel $svc) on port $p"
            if (-not (Wait-Until $deadline { Test-HDPort $addr $p })) {
                Stop-Stage $tag "Port $p is not answering" @($svc)
                if (Test-Cancelled) { return }
                continue
            }
            $open.Add($svc)
            $status = if ($open.Count -eq $services.Count) { 'ready' } else { 'pingOnly' }
            Send-Message @{ Kind = 'status'; Status = $status; Open = $open.ToArray() }
            Write-Log $tag "Port $p is open"

            if ($svc -eq 'rdp') {
                if (Test-HDRdp $addr $p) { Write-Log 'RDP' 'The RDP service accepted the connection request' }
                else { Set-Failed 'rdp'; Write-Log 'RDP' 'Port is open, but no RDP handshake reply' }
            } elseif ($svc -eq 'vnc') {
                if (Test-HDRfb $addr $p) { Write-Log 'VNC' 'The Screen Sharing service sent its RFB banner' }
                else { Set-Failed 'vnc'; Write-Log 'VNC' 'Port is open, but no RFB banner' }
            } elseif (-not $h.sshKey) {
                Write-Log 'LOGIN' 'No SSH key set, so no login test'
            } elseif (Test-HDKeyMissing $h) {
                Set-Failed 'ssh'
                Write-Log 'LOGIN' "Key file not found: $(Get-HDKeyPath $h)"
            } else {
                Write-Log 'LOGIN' "Logging in as $(Get-HDSshTarget $h) with $($h.sshKey)"
                $result = Invoke-HDSshLogin $h { Test-Cancelled }
                if ($result.Ok) { Write-Log 'LOGIN' 'Login succeeded' }
                elseif (-not $result.Cancelled) { Set-Failed 'ssh'; Write-Log 'LOGIN' "Failed: $($result.Message)" }
            }
            if (Test-Cancelled) { return Write-Log 'CANCEL' 'Stopped' }
        }

        if ($failed.Count -eq 0) {
            $text = switch ($h.os) {
                'windows' { "$($h.name) is ready for RDP connections on port $(Get-HDServicePort $h)" }
                'macos' { "$($h.name) is ready for " + ((@($services) | ForEach-Object { Get-HDLabel $_ }) -join ' and ') }
                default { "$($h.name) is ready" }
            }
            Write-Log 'READY' $text
            Send-Message @{ Kind = 'ready' }
        }
        # Connect if the chosen service passed, even if another service failed.
        $connect = Get-HDConnectService $h
        if ($Job.Connect -and $connect -and -not $failed.Contains($connect) -and $open.Contains($connect)) {
            Send-Message @{ Kind = 'connect'; Service = $connect }
        }
    }
}
. $EngineBlock
$EngineText = $EngineBlock.ToString()

# Each background job runs this script with one argument, the job.
$WorkerText = {
    param($Job)
    . ([scriptblock]::Create($Job.Engine))
    try {
        if ($Job.Kind -eq 'probe') {
            $r = Invoke-HDProbe $Job.Host
            $Job.Queue.Enqueue(@{ Kind = 'probe'; Id = $Job.Host.id; Key = $Job.Key; Status = $r.Status; Open = $r.Open })
        } else {
            Invoke-HDRun $Job
        }
    } catch {
        $Job.Queue.Enqueue(@{ Kind = 'log'; Id = $Job.Host.id; Run = $Job.RunId; Time = (Get-Date).ToString('HH:mm:ss'); Tag = 'ERROR'; Text = $_.Exception.Message })
    } finally {
        $Job.Queue.Enqueue(@{ Kind = 'done'; Id = $Job.Host.id; Run = $Job.RunId; Probe = ($Job.Kind -eq 'probe') })
    }
}.ToString()

# MARK: - File format

# docs/FILE-FORMAT.md defines this format, and the Mac version reads it. Do not change a key name.

function Get-HDProp($o, [string]$name) {
    if ($null -eq $o -or $o -isnot [Management.Automation.PSCustomObject]) { return $null }
    $p = $o.PSObject.Properties[$name]
    # The comma keeps an array as one value. Without it, PowerShell unrolls it, and an empty array becomes $null.
    if ($p) { return , $p.Value }
}
function Get-HDString($o, [string]$name) { $v = Get-HDProp $o $name; if ($v -is [string]) { $v } else { '' } }
function Get-HDInt($o, [string]$name, [int]$min = 1, [int]$max = 65535) {
    $v = Get-HDProp $o $name
    if (($v -is [int] -or $v -is [long]) -and $v -ge $min -and $v -le $max) { [int]$v }
}
function Get-HDBool($o, [string]$name, [bool]$default) { $v = Get-HDProp $o $name; if ($v -is [bool]) { $v } else { $default } }

function Test-HDDate($s) {
    if ($s -isnot [string]) { return $false }
    $d = [DateTimeOffset]::MinValue
    $formats = [string[]]@("yyyy-MM-dd'T'HH:mm:ssK", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK")
    [DateTimeOffset]::TryParseExact($s, $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)
}

function New-HDHost([string]$name = 'new-host') {
    @{
        id = [guid]::NewGuid().ToString().ToUpperInvariant(); name = $name; mac = ''; os = 'linux'; address = ''
        port = $null; user = ''; sshKey = ''; wakeEnabled = $true; sshEnabled = $true; vncEnabled = $true; vncPort = $null
    }
}

# One host from the parsed JSON, with the defaults of docs/FILE-FORMAT.md for missing keys.
function ConvertTo-HDHost($o) {
    $id = Get-HDProp $o 'id'
    $guid = [guid]::Empty
    if ($id -isnot [string] -or -not [guid]::TryParse($id, [ref]$guid)) { throw 'A host has no valid id.' }
    $name = Get-HDProp $o 'name'
    if ($name -isnot [string]) { throw "The host $id has no name." }
    $mac = Get-HDProp $o 'mac'
    if ($mac -isnot [string]) { throw "The host $name has no mac value." }
    # "network" was the first name of the Other type. Read an unknown type as Linux.
    $raw = Get-HDProp $o 'os'
    $os = if ($raw -ceq 'network') { 'other' } elseif ($raw -cin 'linux', 'macos', 'windows', 'other') { $raw } else { 'linux' }
    @{
        id          = $guid.ToString().ToUpperInvariant()
        name        = $name
        mac         = $mac
        os          = $os
        address     = Get-HDString $o 'address'
        port        = Get-HDInt $o 'port'
        user        = Get-HDString $o 'user'
        sshKey      = Get-HDString $o 'sshKey'
        wakeEnabled = Get-HDBool $o 'wakeEnabled' ($os -ne 'other')
        sshEnabled  = Get-HDBool $o 'sshEnabled' $true
        vncEnabled  = Get-HDBool $o 'vncEnabled' $true
        vncPort     = Get-HDInt $o 'vncPort'
    }
}

# Read a hosts file: an export, or a bare JSON array of hosts. Return @{ Hosts; Settings }.
# Throw a message for the user if the file cannot be read. -AllowUnsafe reads hosts whose address or user
# starts with "-". HostDeck uses it only for its own saved file, and never runs ssh for such a host.
function Read-HDFile([string]$text, [switch]$AllowUnsafe) {
    try { $o = ConvertFrom-Json -InputObject $text } catch { throw 'The file is not valid JSON.' }
    $settings = @{}
    if ($o -is [array]) {
        $list = $o
    } else {
        if ((Get-HDProp $o 'app') -cne 'HostDeck') { throw 'The file is not a HostDeck export.' }
        $v = Get-HDProp $o 'version'
        if ($v -isnot [int] -and $v -isnot [long]) { throw 'The file has no format version.' }
        if ($v -ne $HDFormatVersion) {
            throw "The file uses format version $v. This version of HostDeck reads version $HDFormatVersion. Update HostDeck, then try again."
        }
        if (-not (Test-HDDate (Get-HDProp $o 'exported'))) { throw 'The file has no valid export date.' }
        $list = Get-HDProp $o 'hosts'
        if ($list -isnot [array]) { throw 'The file has no list of hosts.' }
        $s = Get-HDProp $o 'settings'
        $b = Get-HDProp $s 'broadcast'
        if ($b -is [string] -and (Test-HDIPv4 $b)) { $settings.broadcast = $b }
        $p = Get-HDInt $s 'port'
        if ($null -ne $p) { $settings.port = $p }
        $t = Get-HDInt $s 'timeout' 1 86400
        if ($null -ne $t) { $settings.timeout = $t }
    }
    $hosts = @(foreach ($item in $list) { ConvertTo-HDHost $item })
    if (-not $AllowUnsafe) {
        $unsafe = @($hosts | Where-Object { Test-HDUnsafe $_ } | ForEach-Object { $_.name })
        if ($unsafe.Count) {
            throw "The address or user of these hosts starts with `"-`", which ssh reads as an option: $($unsafe -join ', ')."
        }
    }
    @{ Hosts = $hosts; Settings = $settings }
}

# A writer leaves out an optional key that has no value.
function ConvertTo-HDHostRecord($h) {
    $r = [ordered]@{ id = ([string]$h.id).ToUpperInvariant(); name = [string]$h.name; mac = [string]$h.mac; os = [string]$h.os; address = [string]$h.address }
    if ($null -ne $h.port) { $r.port = [int]$h.port }
    $r.user = [string]$h.user
    $r.sshKey = [string]$h.sshKey
    $r.wakeEnabled = [bool]$h.wakeEnabled
    $r.sshEnabled = [bool]$h.sshEnabled
    $r.vncEnabled = [bool]$h.vncEnabled
    if ($null -ne $h.vncPort) { $r.vncPort = [int]$h.vncPort }
    $r
}

function New-HDFileText($hostList, $settings) {
    $doc = [ordered]@{
        app      = 'HostDeck'
        version  = $HDFormatVersion
        exported = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        hosts    = @(foreach ($h in $hostList) { ConvertTo-HDHostRecord $h })
        settings = [ordered]@{ broadcast = [string]$settings.broadcast; port = [int]$settings.port; timeout = [int]$settings.timeout }
    }
    ConvertTo-Json -InputObject $doc -Depth 5
}

# Merge by host ID: a host with a known ID replaces that host, and other hosts are added. Nothing is deleted.
function Merge-HDHosts($current, $incoming) {
    $list = [Collections.ArrayList]::new()
    foreach ($h in $current) { [void]$list.Add($h) }
    $added = 0
    $replaced = 0
    foreach ($h in $incoming) {
        $i = -1
        for ($j = 0; $j -lt $list.Count; $j++) { if ($list[$j].id -eq $h.id) { $i = $j; break } }
        if ($i -ge 0) { $list[$i] = $h; $replaced++ } else { [void]$list.Add($h); $added++ }
    }
    @{ List = $list; Added = $added; Replaced = $replaced }
}

# Write UTF-8 without a byte order mark. Write a temporary file first, so that a crash cannot leave half a file.
function Write-HDTextFile([string]$path, [string]$text) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, $null) } else { [IO.File]::Move($tmp, $path) }
}

# MARK: - Icons

# The app icon: a deck of three host cards, each with a status dot, on a blue square. As the Mac icon.
function New-HDAppIcon([int]$size) {
    $dv = [Windows.Media.DrawingVisual]::new()
    $dc = $dv.RenderOpen()
    $k = $size / 64.0
    $dc.PushTransform([Windows.Media.ScaleTransform]::new($k, $k))
    $bc = [Windows.Media.BrushConverter]::new()
    $dc.DrawRoundedRectangle($bc.ConvertFrom('#1565C0'), $null, [Windows.Rect]::new(2, 2, 60, 60), 13, 13)
    $rows = @(@{ Y = 11; Dot = '#2EB84B' }, @{ Y = 26.5; Dot = '#F29B1D' }, @{ Y = 42; Dot = '#E5484D' })
    foreach ($r in $rows) {
        $dc.DrawRoundedRectangle([Windows.Media.Brushes]::White, $null, [Windows.Rect]::new(10, $r.Y, 44, 11), 3, 3)
        $dc.DrawEllipse($bc.ConvertFrom($r.Dot), $null, [Windows.Point]::new(16.5, $r.Y + 5.5), 3.4, 3.4)
        $dc.DrawRoundedRectangle($bc.ConvertFrom('#B9CCE6'), $null, [Windows.Rect]::new(23, $r.Y + 4, 24, 3), 1.5, 1.5)
    }
    $dc.Pop()
    $dc.Close()
    $bmp = [Windows.Media.Imaging.RenderTargetBitmap]::new($size, $size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    $bmp
}

function ConvertTo-HDPng($bitmap) {
    $enc = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $ms = [IO.MemoryStream]::new()
    $enc.Save($ms)
    , $ms.ToArray()
}

# An .ico file with PNG images, for the Start menu shortcut.
function Save-HDIconFile([string]$path) {
    $sizes = @(16, 24, 32, 48, 64, 256)
    $pngs = @(foreach ($s in $sizes) { , (ConvertTo-HDPng (New-HDAppIcon $s)) })
    $ms = [IO.MemoryStream]::new()
    $w = [IO.BinaryWriter]::new($ms)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = [byte]($sizes[$i] % 256)
        $w.Write($dim); $w.Write($dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write([byte[]]$p) }
    $w.Flush()
    [IO.File]::WriteAllBytes($path, $ms.ToArray())
}

if ($NoGui) { return }

# MARK: - Single instance

# One HostDeck for each data folder. A second start shows the window of the first one, then stops.
$instanceName = 'HostDeck-' + [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($DataDir.ToLowerInvariant()))).Replace('-', '').Substring(0, 12)
$createdNew = $false
$script:Mutex = [Threading.Mutex]::new($true, "Local\$instanceName", [ref]$createdNew)
$script:ShowEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, "Local\$instanceName-show")
if (-not $createdNew) {
    [void]$script:ShowEvent.Set()
    return
}

# Give HostDeck its own taskbar button, not the PowerShell one.
Add-Type -Namespace HostDeck -Name Native -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
'@
[void][HostDeck.Native]::SetCurrentProcessExplicitAppUserModelID('edrandall.HostDeck')
[Windows.Forms.Application]::EnableVisualStyles()

# MARK: - Window

$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HostDeck" Width="1000" Height="840" MinWidth="860" MinHeight="760"
        FontFamily="Segoe UI" FontSize="14" Background="#F3F3F3"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#0067C0"/>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#E0E0E0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16,4"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="Row" TargetType="Grid">
      <Setter Property="Margin" Value="0,3"/>
    </Style>
    <Style x:Key="RowLabel" TargetType="TextBlock">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Width" Value="190"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
    </Style>
    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="BorderBrush" Value="#C4C4C4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="IsHitTestVisible" Value="False"/>
      <Setter Property="Foreground" Value="#8A8A8A"/>
      <Setter Property="Margin" Value="9,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Warn" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#C42B1C"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="190,2,0,0"/>
      <Setter Property="Visibility" Value="Collapsed"/>
    </Style>
    <Style x:Key="Action" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.9"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Segment" TargetType="RadioButton">
      <Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="White" BorderBrush="#C4C4C4" BorderThickness="1" CornerRadius="5" Padding="14,4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#F0F0F0"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#0067C0"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#0067C0"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="track" Width="40" Height="20" CornerRadius="10" BorderBrush="#7A7A7A" BorderThickness="1" Background="White">
                <Ellipse x:Name="thumb" Width="12" Height="12" Fill="#5A5A5A" HorizontalAlignment="Left" Margin="4,0"/>
              </Border>
              <TextBlock x:Name="state" Text="Off" Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#0067C0"/>
                <Setter TargetName="track" Property="BorderBrush" Value="#0067C0"/>
                <Setter TargetName="thumb" Property="Fill" Value="White"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="state" Property="Text" Value="On"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Icon" TargetType="Button">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#14000000"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <DockPanel>
    <Menu DockPanel.Dock="Top" Background="#F3F3F3" Padding="4,3">
      <MenuItem Header="_File">
        <MenuItem x:Name="MenuImport" Header="_Import Hosts..."/>
        <MenuItem x:Name="MenuExport" Header="_Export Hosts..." InputGestureText="Ctrl+Shift+E"/>
        <Separator/>
        <MenuItem x:Name="MenuSettings" Header="_Settings..." InputGestureText="Ctrl+,"/>
        <Separator/>
        <MenuItem x:Name="MenuClose" Header="_Close Window"/>
        <MenuItem x:Name="MenuExit" Header="E_xit HostDeck"/>
      </MenuItem>
      <MenuItem x:Name="MenuHost" Header="H_ost">
        <MenuItem x:Name="MenuAdd" Header="_Add Host" InputGestureText="Ctrl+N"/>
        <MenuItem x:Name="MenuDelete" Header="_Delete Host..." InputGestureText="Del"/>
        <MenuItem x:Name="MenuUp" Header="Move _Up" InputGestureText="Alt+Up"/>
        <MenuItem x:Name="MenuDown" Header="Move Do_wn" InputGestureText="Alt+Down"/>
        <Separator/>
        <MenuItem x:Name="MenuWake" Header="_Wake" InputGestureText="Ctrl+Enter"/>
        <MenuItem x:Name="MenuWakeConnect" Header="Wake and _Connect" InputGestureText="Ctrl+Shift+Enter"/>
        <MenuItem x:Name="MenuTest" Header="_Test" InputGestureText="Ctrl+T"/>
        <MenuItem x:Name="MenuCancel" Header="Ca_ncel" InputGestureText="Esc"/>
        <Separator/>
        <MenuItem x:Name="MenuClearLog" Header="C_lear the Log" InputGestureText="Ctrl+K"/>
      </MenuItem>
      <MenuItem Header="_Help">
        <MenuItem x:Name="MenuHelp" Header="HostDeck _Page"/>
        <MenuItem x:Name="MenuDataFolder" Header="Open the _Data Folder"/>
      </MenuItem>
    </Menu>

    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="280" MinWidth="230"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <DockPanel Grid.Column="0" Background="#EAEAEA">
        <Grid DockPanel.Dock="Top" Margin="14,8,8,4">
          <TextBlock Text="Hosts" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <Button x:Name="AddButton" Style="{StaticResource Icon}" Content="&#xE710;" FontSize="14" HorizontalAlignment="Right" ToolTip="Add Host (Ctrl+N)"/>
        </Grid>
        <StackPanel DockPanel.Dock="Bottom" Margin="14,4,12,12" TextElement.FontSize="12">
          <Border Height="1" Background="#D6D6D6" Margin="0,0,0,8"/>
          <TextBlock Text="HostDeck" FontWeight="Bold" FontSize="14" Margin="0,0,0,6"/>
          <StackPanel x:Name="KeyPanel"/>
          <Border Height="1" Background="#D6D6D6" Margin="0,8"/>
          <Grid>
            <StackPanel>
              <TextBlock x:Name="SummaryText"/>
              <TextBlock x:Name="CheckedText" Foreground="#666666" Margin="0,2,0,0"/>
            </StackPanel>
            <Button x:Name="HelpButton" Style="{StaticResource Icon}" Content="&#xE897;" FontSize="16" HorizontalAlignment="Right" ToolTip="Open the HostDeck page on edrandall.uk"/>
          </Grid>
        </StackPanel>
        <ListBox x:Name="HostList" Background="Transparent" BorderThickness="0" Margin="6,0"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled">
          <ListBox.ContextMenu>
            <ContextMenu x:Name="ListMenu">
              <MenuItem x:Name="ListWake" Header="Wake"/>
              <MenuItem x:Name="ListWakeConnect" Header="Wake and Connect"/>
              <MenuItem x:Name="ListTest" Header="Test"/>
              <Separator/>
              <MenuItem x:Name="ListUp" Header="Move Up"/>
              <MenuItem x:Name="ListDown" Header="Move Down"/>
              <Separator/>
              <MenuItem x:Name="ListDelete" Header="Delete..."/>
            </ContextMenu>
          </ListBox.ContextMenu>
        </ListBox>
      </DockPanel>

      <Border Grid.Column="1" Width="1" Background="#D6D6D6"/>

      <TextBlock x:Name="EmptyText" Grid.Column="2" Text="Select a host, or click + to add one." Foreground="#666666"
                 HorizontalAlignment="Center" VerticalAlignment="Center"/>

      <Grid x:Name="Detail" Grid.Column="2" Margin="18,12,18,14">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*" MinHeight="90"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid Style="{StaticResource Row}">
                <TextBlock Style="{StaticResource RowLabel}" Text="Name"/>
                <TextBox x:Name="NameBox" Style="{StaticResource Field}" Margin="190,0,0,0"/>
              </Grid>
              <Grid Style="{StaticResource Row}">
                <TextBlock Style="{StaticResource RowLabel}" Text="OS"/>
                <StackPanel Orientation="Horizontal" Margin="190,0,0,0">
                  <RadioButton x:Name="OsLinux" Style="{StaticResource Segment}" GroupName="os" Content="Linux" Tag="linux"/>
                  <RadioButton x:Name="OsMacos" Style="{StaticResource Segment}" GroupName="os" Content="macOS" Tag="macos"/>
                  <RadioButton x:Name="OsWindows" Style="{StaticResource Segment}" GroupName="os" Content="Windows" Tag="windows"/>
                  <RadioButton x:Name="OsOther" Style="{StaticResource Segment}" GroupName="os" Content="Other" Tag="other"/>
                </StackPanel>
              </Grid>
              <Grid x:Name="RowWake" Style="{StaticResource Row}">
                <TextBlock Style="{StaticResource RowLabel}" Text="Wake-on-LAN"/>
                <CheckBox x:Name="WakeCheck" Style="{StaticResource Switch}" Margin="190,0,0,0"/>
              </Grid>
              <StackPanel x:Name="RowMac" Margin="0,3">
                <Grid>
                  <TextBlock Style="{StaticResource RowLabel}" Text="MAC address"/>
                  <Grid Margin="190,0,0,0">
                    <TextBox x:Name="MacBox" Style="{StaticResource Field}"/>
                    <TextBlock x:Name="MacHint" Style="{StaticResource Hint}" Text="00:11:22:33:44:55"/>
                  </Grid>
                </Grid>
                <TextBlock x:Name="MacWarn" Style="{StaticResource Warn}" Text="A MAC address needs 12 hex digits."/>
              </StackPanel>
              <StackPanel Margin="0,3">
                <Grid>
                  <TextBlock Style="{StaticResource RowLabel}" Text="Address"/>
                  <Grid Margin="190,0,0,0">
                    <TextBox x:Name="AddressBox" Style="{StaticResource Field}"/>
                    <TextBlock x:Name="AddressHint" Style="{StaticResource Hint}" Text="IP address or hostname"/>
                  </Grid>
                </Grid>
                <TextBlock x:Name="AddressWarn" Style="{StaticResource Warn}" Text="An address cannot start with &quot;-&quot;."/>
              </StackPanel>
              <StackPanel x:Name="RowPort" Margin="0,3">
                <Grid>
                  <TextBlock x:Name="PortLabel" Style="{StaticResource RowLabel}" Text="SSH port"/>
                  <Grid Margin="190,0,0,0" HorizontalAlignment="Left" Width="120">
                    <TextBox x:Name="PortBox" Style="{StaticResource Field}"/>
                    <TextBlock x:Name="PortHint" Style="{StaticResource Hint}" Text="22"/>
                  </Grid>
                </Grid>
                <TextBlock x:Name="PortWarn" Style="{StaticResource Warn}" Text="A port is a number from 1 to 65535."/>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border x:Name="MacCard" Style="{StaticResource Card}">
            <StackPanel>
              <Grid Style="{StaticResource Row}">
                <TextBlock Style="{StaticResource RowLabel}" Text="SSH"/>
                <CheckBox x:Name="SshCheck" Style="{StaticResource Switch}" Margin="190,0,0,0"/>
              </Grid>
              <StackPanel x:Name="RowSshPort" Margin="0,3">
                <Grid>
                  <TextBlock Style="{StaticResource RowLabel}" Text="SSH port"/>
                  <Grid Margin="190,0,0,0" HorizontalAlignment="Left" Width="120">
                    <TextBox x:Name="SshPortBox" Style="{StaticResource Field}"/>
                    <TextBlock x:Name="SshPortHint" Style="{StaticResource Hint}" Text="22"/>
                  </Grid>
                </Grid>
                <TextBlock x:Name="SshPortWarn" Style="{StaticResource Warn}" Text="A port is a number from 1 to 65535."/>
              </StackPanel>
              <Grid Style="{StaticResource Row}">
                <TextBlock Style="{StaticResource RowLabel}" Text="Screen Sharing"/>
                <CheckBox x:Name="VncCheck" Style="{StaticResource Switch}" Margin="190,0,0,0"/>
              </Grid>
              <StackPanel x:Name="RowVncPort" Margin="0,3">
                <Grid>
                  <TextBlock Style="{StaticResource RowLabel}" Text="Screen Sharing port"/>
                  <Grid Margin="190,0,0,0" HorizontalAlignment="Left" Width="120">
                    <TextBox x:Name="VncPortBox" Style="{StaticResource Field}"/>
                    <TextBlock x:Name="VncPortHint" Style="{StaticResource Hint}" Text="5900"/>
                  </Grid>
                </Grid>
                <TextBlock x:Name="VncPortWarn" Style="{StaticResource Warn}" Text="A port is a number from 1 to 65535."/>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border x:Name="SshCard" Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Margin="0,3">
                <Grid>
                  <TextBlock Style="{StaticResource RowLabel}" Text="User"/>
                  <Grid Margin="190,0,0,0">
                    <TextBox x:Name="UserBox" Style="{StaticResource Field}"/>
                    <TextBlock x:Name="UserHint" Style="{StaticResource Hint}" Text="optional"/>
                  </Grid>
                </Grid>
                <TextBlock x:Name="UserWarn" Style="{StaticResource Warn}" Text="A user cannot start with &quot;-&quot;."/>
              </StackPanel>
              <StackPanel x:Name="RowKey" Margin="0,3">
                <Grid>
                  <TextBlock Style="{StaticResource RowLabel}" Text="SSH key"/>
                  <DockPanel Margin="190,0,0,0">
                    <Button x:Name="KeyBrowse" DockPanel.Dock="Right" Content="Browse..." Padding="10,3" Margin="6,0,0,0"/>
                    <Grid>
                      <TextBox x:Name="KeyBox" Style="{StaticResource Field}"/>
                      <TextBlock x:Name="KeyHint" Style="{StaticResource Hint}" Text="optional, for example ~\.ssh\id_ed25519"/>
                    </Grid>
                  </DockPanel>
                </Grid>
                <TextBlock x:Name="KeyWarn" Style="{StaticResource Warn}" Text="Key file not found."/>
              </StackPanel>
            </StackPanel>
          </Border>
        </StackPanel>

        <DockPanel Grid.Row="1">
          <Grid DockPanel.Dock="Top" Margin="2,0,0,2">
            <TextBlock Text="Log" FontSize="12" Foreground="#666666" VerticalAlignment="Center"/>
            <Button x:Name="ClearLogButton" Style="{StaticResource Icon}" Content="&#xE74D;" FontSize="13"
                    Width="26" Height="24" HorizontalAlignment="Right"
                    ToolTip="Clear the log (Ctrl+K)" ToolTipService.ShowOnDisabled="True"/>
          </Grid>
          <TextBox x:Name="LogBox" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="13"
                   Background="#FBFBFB" BorderBrush="#E0E0E0" Padding="8,6" TextWrapping="NoWrap"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        </DockPanel>

        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0">
          <ContentControl x:Name="StatusDotHost" Margin="0,0,8,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusText" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </StackPanel>

        <TextBlock x:Name="FooterText" Grid.Row="3" FontSize="12" Foreground="#666666" Margin="0,4,0,10" TextWrapping="Wrap"/>

        <DockPanel Grid.Row="4" LastChildFill="True">
          <StackPanel x:Name="ServicePanel" DockPanel.Dock="Right" Orientation="Horizontal"/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="WakeButton" Style="{StaticResource Action}" Background="#107C10" Content="Wake"/>
            <Button x:Name="WakeConnectButton" Style="{StaticResource Action}" Background="#107C10" Content="Wake and Connect"/>
            <Button x:Name="TestButton" Style="{StaticResource Action}" Background="#0067C0" Content="Test"/>
            <Button x:Name="CancelButton" Style="{StaticResource Action}" Background="#C42B1C" Content="Cancel"/>
          </StackPanel>
        </DockPanel>
      </Grid>
    </Grid>
  </DockPanel>
</Window>
'@

$SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HostDeck Settings" Width="480" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        FontFamily="Segoe UI" FontSize="14" Background="#F3F3F3" UseLayoutRounding="True">
  <StackPanel Margin="20,18">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
      <TextBlock Text="Broadcast address" VerticalAlignment="Center"/>
      <TextBox x:Name="BroadcastBox" Grid.Column="1" Padding="6,4"/>
      <TextBlock Grid.Row="1" Grid.ColumnSpan="2" FontSize="12" Foreground="#666666" TextWrapping="Wrap" Margin="0,6,0,12"
                 Text="Use the subnet broadcast (for example 192.168.1.255) if 255.255.255.255 does not reach the host. HostDeck also sends the packet from each network adapter that is up."/>
      <TextBlock Grid.Row="2" Text="UDP port" VerticalAlignment="Center"/>
      <TextBox x:Name="PortBox" Grid.Row="2" Grid.Column="1" Padding="6,4" Width="100" HorizontalAlignment="Left" Margin="0,0,0,10"/>
      <TextBlock Grid.Row="3" Text="Wait timeout (seconds)" VerticalAlignment="Center"/>
      <TextBox x:Name="TimeoutBox" Grid.Row="3" Grid.Column="1" Padding="6,4" Width="100" HorizontalAlignment="Left"/>
    </Grid>
    <TextBlock x:Name="ErrorText" Foreground="#C42B1C" FontSize="12" Margin="0,10,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="OkButton" Content="OK" IsDefault="True" Width="90" Padding="0,4"/>
      <Button Content="Cancel" IsCancel="True" Width="90" Padding="0,4" Margin="8,0,0,0"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

function Read-HDXaml([string]$text) {
    [xml]$xml = $text
    $root = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
    $named = @{ Root = $root }
    foreach ($node in $xml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($name) { $named[$name] = $root.FindName($name) }
    }
    $named
}

# MARK: - State

$script:Hosts = [Collections.ArrayList]::new()
$script:Settings = @{ broadcast = '255.255.255.255'; port = 9; timeout = 180 }
# Per host: the status of the last check, the services whose port answered, the services that failed in the last
# Wake or Test run, the log, and the ID of the run that is busy.
$script:States = @{}
$script:Queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:Cancel = [Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
$script:Jobs = [Collections.ArrayList]::new()
$script:CheckAt = @{}
$script:SelectedId = $null
$script:Loading = $false
$script:Rebuilding = $false
$script:DirtyAt = $null
$script:LastChecked = $null
$script:Exiting = $false
$script:TrayHintShown = $false
$script:VncCache = @{ At = [datetime]::MinValue; Viewer = $null }
$script:ServiceSignature = ''

$BrushConverter = [Windows.Media.BrushConverter]::new()
function Get-HDBrush([string]$color) { $BrushConverter.ConvertFrom($color) }

function Get-HDState([string]$id) {
    if (-not $script:States.ContainsKey($id)) {
        $script:States[$id] = @{ Status = $null; Open = @(); Failed = @(); Log = [Collections.Generic.List[string]]::new(); Run = $null; Probing = $false; Recheck = $false }
    }
    $script:States[$id]
}

function Find-HDHost([string]$id) {
    foreach ($h in $script:Hosts) { if ($h.id -eq $id) { return $h } }
}

function Get-HDSelected { if ($script:SelectedId) { Find-HDHost $script:SelectedId } }

function Test-HDOnline([string]$id) { (Get-HDState $id).Status -in 'ready', 'pingOnly' }

function Write-HDError($err) {
    try {
        $line = "$(Get-Date -Format s)  $err $($err.ScriptStackTrace)"
        [IO.File]::AppendAllText((Join-Path $DataDir 'errors.log'), $line + [Environment]::NewLine)
    } catch { }
}

function Add-HDLog([string]$id, [string]$tag, [string]$text) {
    (Get-HDState $id).Log.Add(('{0}  {1}{2}' -f (Get-Date).ToString('HH:mm:ss'), $tag.PadRight(8), $text))
}

# MARK: - Storage

function Get-HDDataFile { Join-Path $DataDir 'hostdeck.json' }

# The saved hosts use the export format, so the data file is also a backup that the Mac app can import.
function Import-HDStore {
    $file = Get-HDDataFile
    if (-not (Test-Path -LiteralPath $file)) { return }
    try {
        $data = Read-HDFile ([IO.File]::ReadAllText($file)) -AllowUnsafe
        foreach ($h in $data.Hosts) { [void]$script:Hosts.Add($h) }
        foreach ($k in $data.Settings.Keys) { $script:Settings[$k] = $data.Settings[$k] }
    } catch {
        $bad = "$file.bad"
        Copy-Item -LiteralPath $file -Destination $bad -Force
        $script:LoadError = "HostDeck cannot read its saved hosts: $($_.Exception.Message) It started with no hosts. The old file is $bad."
    }
}

function Save-HDStore {
    if (-not (Test-Path -LiteralPath $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir) }
    Write-HDTextFile (Get-HDDataFile) (New-HDFileText $script:Hosts $script:Settings)
    $script:DirtyAt = $null
}

function Set-HDDirty { $script:DirtyAt = Get-Date }

# MARK: - Background jobs

$script:Pool = [runspacefactory]::CreateRunspacePool(1, 24)
$script:Pool.ApartmentState = 'MTA'
$script:Pool.Open()

function Start-HDJob([hashtable]$job) {
    $job.Engine = $EngineText
    $job.Queue = $script:Queue
    $job.Cancel = $script:Cancel
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($WorkerText).AddArgument($job)
    [void]$script:Jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
}

# What a check depends on. A check result for an older key is out of date.
function Get-HDProbeKey($h) {
    "$($h.address)|$((@(Get-HDServices $h) | ForEach-Object { "$($_):$(Get-HDPort $h $_)" }) -join ',')"
}

function Start-HDProbe($h) {
    $st = Get-HDState $h.id
    if (-not $h.address -or $st.Run) { return }
    if ($st.Probing) { $st.Recheck = $true; return }
    $st.Probing = $true
    Start-HDJob @{ Kind = 'probe'; Host = $h.Clone(); Key = (Get-HDProbeKey $h) }
}

# Check the host soon, for example after a change to its address. Clear the old status now.
function Request-HDCheck($h) {
    $st = Get-HDState $h.id
    if (-not $st.Run) { $st.Status = $null; $st.Open = @() }
    $script:CheckAt[$h.id] = (Get-Date).AddMilliseconds(700)
}

function Start-HDRun($h, [bool]$wake, [bool]$connect) {
    $st = Get-HDState $h.id
    if ($st.Run) { $script:Cancel[$st.Run] = $true }
    $run = [guid]::NewGuid().ToString()
    $st.Run = $run
    $st.Log.Clear()
    $st.Failed = @()
    Start-HDJob @{
        Kind = 'run'; Host = $h.Clone(); RunId = $run; Wake = $wake; Connect = $connect
        Broadcast = $script:Settings.broadcast; Port = [int]$script:Settings.port; Timeout = [int]$script:Settings.timeout
    }
    Update-HDView
}

function Stop-HDRun([string]$id) {
    $st = Get-HDState $id
    if ($st.Run) { $script:Cancel[$st.Run] = $true }
}

# Handle one message from a background job. Messages from a run that is no longer the current one are ignored,
# so a cancelled run cannot write in the log of the next run.
function Receive-HDMessage($m) {
    $h = Find-HDHost $m.Id
    if (-not $h) { return }
    $st = Get-HDState $m.Id
    if ($m.Kind -eq 'probe') {
        $script:LastChecked = Get-Date
        if (-not $st.Run -and $m.Key -eq (Get-HDProbeKey $h)) { $st.Status = $m.Status; $st.Open = @($m.Open) }
        return
    }
    if ($m.Kind -eq 'done') {
        if ($m.Probe) {
            $st.Probing = $false
            if ($st.Recheck) { $st.Recheck = $false; Start-HDProbe $h }
        } elseif ($st.Run -eq $m.Run) {
            $st.Run = $null
            $flag = $false
            [void]$script:Cancel.TryRemove($m.Run, [ref]$flag)
        }
        return
    }
    if ($st.Run -ne $m.Run) { return }
    switch ($m.Kind) {
        'log' { $st.Log.Add(('{0}  {1}{2}' -f $m.Time, ([string]$m.Tag).PadRight(8), $m.Text)) }
        'status' { $st.Status = $m.Status; $st.Open = @($m.Open) }
        'failed' { $st.Failed = @($st.Failed) + $m.Service }
        'ready' { [Media.SystemSounds]::Asterisk.Play() }
        'connect' { Connect-HDService $h $m.Service }
    }
}

# MARK: - Connect

function Get-HDVncViewer {
    if (((Get-Date) - $script:VncCache.At).TotalSeconds -lt 30) { return $script:VncCache.Viewer }
    $viewer = $null
    $known = @(
        @{ Name = 'TigerVNC Viewer'; Path = 'TigerVNC\vncviewer.exe' },
        @{ Name = 'RealVNC Viewer'; Path = 'RealVNC\VNC Viewer\vncviewer.exe' },
        @{ Name = 'TightVNC Viewer'; Path = 'TightVNC\tvnviewer.exe' },
        @{ Name = 'UltraVNC Viewer'; Path = 'uvnc bvba\UltraVNC\vncviewer.exe' }
    )
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) | Where-Object { $_ }
    :search foreach ($k in $known) {
        foreach ($r in $roots) {
            $p = Join-Path $r $k.Path
            if ([IO.File]::Exists($p)) { $viewer = @{ Name = $k.Name; Path = $p }; break search }
        }
    }
    if (-not $viewer) {
        $c = Get-Command vncviewer.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $viewer = @{ Name = 'VNC Viewer'; Path = $c.Source } }
    }
    $script:VncCache = @{ At = Get-Date; Viewer = $viewer }
    $viewer
}

function Get-HDServiceAction([string]$svc) {
    switch ($svc) { 'ssh' { 'Connect' } 'rdp' { 'Remote Desktop' } 'vnc' { 'Screen Sharing' } }
}

function Connect-HDService($h, [string]$svc) {
    if (Test-HDUnsafe $h) { return Add-HDLog $h.id 'ERROR' 'The address or user starts with "-". Change it to connect.' }
    try {
        switch ($svc) {
            'ssh' { Open-HDSsh $h }
            'rdp' { Open-HDRdp $h }
            'vnc' { Open-HDVnc $h }
        }
    } catch {
        Add-HDLog $h.id 'ERROR' "Cannot connect: $($_.Exception.Message)"
    }
    Update-HDView
}

# Open ssh in a new terminal window. A small PowerShell command runs ssh. If ssh stops with an error, the window
# stays open so that you can read the error. If the key does not log you in, ssh asks for the password there.
function Open-HDSsh($h) {
    $ssh = Get-HDSsh
    if (-not $ssh) { return Add-HDLog $h.id 'ERROR' 'ssh.exe not found. Add the OpenSSH Client in Settings > System > Optional features.' }
    $argv = @()
    $port = Get-HDServicePort $h
    if ($port -ne 22) { $argv += '-p', [string]$port }
    if ($h.sshKey) { $argv += '-i', (Get-HDKeyPath $h) }
    # "--" stops a target that starts with "-" from being read as an option.
    $argv += '--', (Get-HDSshTarget $h)
    $quote = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $title = & $quote "$($h.name) (HostDeck)"
    $command = "`$Host.UI.RawUI.WindowTitle = $title; & $(& $quote $ssh) $(($argv | ForEach-Object { & $quote $_ }) -join ' '); " +
               "if (`$LASTEXITCODE -ne 0) { Write-Host ''; [void](Read-Host 'ssh stopped with an error. Press Enter to close') }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Add-HDLog $h.id 'CONNECT' "Opening SSH session to $(Get-HDSshTarget $h)"
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList "-NoProfile -NoLogo -EncodedCommand $encoded"
}

# Remote Desktop Connection connects directly. It asks for the credentials, and can save them in Windows.
function Open-HDRdp($h) {
    $port = Get-HDServicePort $h
    $target = if ($port -eq 3389) { $h.address } else { "$($h.address):$port" }
    Add-HDLog $h.id 'CONNECT' "Opening Remote Desktop Connection to $target"
    Start-Process -FilePath (Join-Path $env:windir 'System32\mstsc.exe') -ArgumentList "/v:$(ConvertTo-HDArg $target)"
}

# Start the VNC viewer with the host. The viewer asks for the credentials.
function Open-HDVnc($h) {
    $viewer = Get-HDVncViewer
    if (-not $viewer) { return Add-HDLog $h.id 'ERROR' 'No VNC viewer found. Install TigerVNC, RealVNC Viewer, TightVNC or UltraVNC.' }
    $target = '{0}::{1}' -f $h.address, (Get-HDPort $h 'vnc')
    Add-HDLog $h.id 'OPEN' "Starting $($viewer.Name) for $target"
    Start-Process -FilePath $viewer.Path -ArgumentList (ConvertTo-HDArg $target)
}

# Why the button for a service is not available. $null if you can connect: the host replies to ping, the service
# port answers, no run is busy, and the service did not fail in the last run.
function Get-HDNotReadyReason($h, [string]$svc) {
    $st = Get-HDState $h.id
    if (-not $h.address) { return 'No address set' }
    if (Test-HDUnsafe $h) { return 'The address or user starts with "-"' }
    if ($st.Run) { return 'Wait for the run to finish' }
    if ($svc -eq 'vnc' -and -not (Get-HDVncViewer)) { return 'No VNC viewer is installed. Install TigerVNC, RealVNC Viewer, TightVNC or UltraVNC.' }
    if ($st.Status -eq 'down') { return 'Host is down' }
    if ($st.Status -in 'ready', 'pingOnly') {
        if ($st.Open -notcontains $svc) { return "Host is up, but $(Get-HDLabel $svc) port $(Get-HDPort $h $svc) is not answering" }
        if ($st.Failed -contains $svc) { return "The last $(Get-HDLabel $svc) test failed" }
        return $null
    }
    'Checking the host'
}

# MARK: - Drawing

function New-HDShape([string]$type, [hashtable]$props, [double]$x = 0, [double]$y = 0) {
    $s = New-Object "Windows.Shapes.$type"
    foreach ($k in $props.Keys) { $s.$k = $props[$k] }
    [Windows.Controls.Canvas]::SetLeft($s, $x)
    [Windows.Controls.Canvas]::SetTop($s, $y)
    $s
}

function New-HDPath([string]$data, $stroke, [double]$width, $fill = $null) {
    New-HDShape 'Path' @{
        Data = [Windows.Media.Geometry]::Parse($data); Stroke = $stroke; StrokeThickness = $width; Fill = $fill
        StrokeStartLineCap = 'Round'; StrokeEndLineCap = 'Round'; StrokeLineJoin = 'Round'
    }
}

# The status of a host as a symbol. Each status has its own shape, so the colour is not necessary to read it:
# a tick for ready, "!" for online with a service not answering, an empty circle with "x" for offline, a dashed
# circle for not checked, and a turning arc while a run is busy.
function New-HDStatusDot($status, [double]$size = 16) {
    $c = [Windows.Controls.Canvas]::new()
    $c.Width = 16; $c.Height = 16
    $white = [Windows.Media.Brushes]::White
    switch ($status) {
        'ready' {
            [void]$c.Children.Add((New-HDShape 'Ellipse' @{ Width = 15; Height = 15; Fill = (Get-HDBrush '#1E9E3A') } 0.5 0.5))
            [void]$c.Children.Add((New-HDPath 'M4.6,8.2 L7,10.6 L11.4,5.6' $white 1.8))
            $name = 'Ready'
        }
        'pingOnly' {
            [void]$c.Children.Add((New-HDShape 'Ellipse' @{ Width = 15; Height = 15; Fill = (Get-HDBrush '#E07800') } 0.5 0.5))
            [void]$c.Children.Add((New-HDPath 'M8,4 L8,9' $white 2))
            [void]$c.Children.Add((New-HDShape 'Ellipse' @{ Width = 2.4; Height = 2.4; Fill = $white } 6.8 10.6))
            $name = 'Online, service not answering'
        }
        'down' {
            $red = Get-HDBrush '#D13438'
            [void]$c.Children.Add((New-HDShape 'Ellipse' @{ Width = 14; Height = 14; Stroke = $red; StrokeThickness = 1.5 } 1 1))
            [void]$c.Children.Add((New-HDPath 'M5.6,5.6 L10.4,10.4 M10.4,5.6 L5.6,10.4' $red 1.6))
            $name = 'Offline'
        }
        'busy' {
            $arc = New-HDPath 'M8,1.6 A6.4,6.4 0 1 1 1.6,8' (Get-HDBrush '#0067C0') 2
            $rotate = [Windows.Media.RotateTransform]::new(0, 8, 8)
            $arc.RenderTransform = $rotate
            $spin = [Windows.Media.Animation.DoubleAnimation]::new(0, 360, [Windows.Duration]::new([TimeSpan]::FromSeconds(1)))
            $spin.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $spin)
            [void]$c.Children.Add($arc)
            $name = 'Working'
        }
        default {
            $dash = New-HDShape 'Ellipse' @{ Width = 14; Height = 14; Stroke = (Get-HDBrush '#8A8A8A'); StrokeThickness = 1.5 } 1 1
            $dash.StrokeDashArray = [Windows.Media.DoubleCollection]::Parse('2 1.6')
            [void]$c.Children.Add($dash)
            $name = 'Not checked'
        }
    }
    $box = [Windows.Controls.Viewbox]::new()
    $box.Width = $size; $box.Height = $size
    $box.Child = $c
    $box.ToolTip = $name
    [Windows.Automation.AutomationProperties]::SetName($box, $name)
    $box
}

# A small mark for the OS type: four panes for Windows, a penguin for Linux, the command key for macOS,
# a router for Other.
function New-HDOsIcon([string]$os) {
    $c = [Windows.Controls.Canvas]::new()
    $c.Width = 16; $c.Height = 16
    switch ($os) {
        'windows' {
            $blue = Get-HDBrush '#0078D4'
            foreach ($p in @(@(1, 1), @(8.5, 1), @(1, 8.5), @(8.5, 8.5))) {
                [void]$c.Children.Add((New-HDShape 'Rectangle' @{ Width = 6.5; Height = 6.5; Fill = $blue } $p[0] $p[1]))
            }
        }
        'linux' {
            # A flat Tux: black body, white front, orange beak and feet.
            $orange = Get-HDBrush '#FAB01A'
            $w = 14.0; $hh = 16.0
            $ovals = @(
                @(0.12, 0.0, 0.76, 0.92, 'Black'), @(0.24, 0.36, 0.52, 0.52, 'White'),
                @(0.30, 0.14, 0.15, 0.17, 'White'), @(0.55, 0.14, 0.15, 0.17, 'White'),
                @(0.35, 0.19, 0.07, 0.08, 'Black'), @(0.58, 0.19, 0.07, 0.08, 'Black'),
                @(0.36, 0.30, 0.28, 0.12, 'Orange'), @(0.06, 0.84, 0.38, 0.16, 'Orange'), @(0.56, 0.84, 0.38, 0.16, 'Orange')
            )
            foreach ($o in $ovals) {
                $fill = switch ($o[4]) { 'Black' { [Windows.Media.Brushes]::Black } 'White' { [Windows.Media.Brushes]::White } default { $orange } }
                [void]$c.Children.Add((New-HDShape 'Ellipse' @{ Width = $o[2] * $w; Height = $o[3] * $hh; Fill = $fill } (1 + $o[0] * $w) ($o[1] * $hh)))
            }
        }
        'macos' {
            $t = [Windows.Controls.TextBlock]::new()
            $t.Text = [string][char]0x2318
            $t.FontFamily = 'Segoe UI Symbol'
            $t.FontSize = 15
            $t.Foreground = Get-HDBrush '#333333'
            [Windows.Controls.Canvas]::SetLeft($t, 0.5)
            [Windows.Controls.Canvas]::SetTop($t, -3.5)
            [void]$c.Children.Add($t)
        }
        default {
            $grey = Get-HDBrush '#6E6E6E'
            [void]$c.Children.Add((New-HDPath 'M4.5,9 L3,2.5 M11.5,9 L13,2.5' $grey 1.4))
            [void]$c.Children.Add((New-HDShape 'Rectangle' @{ Width = 14; Height = 6; Fill = $grey; RadiusX = 1.5; RadiusY = 1.5 } 1 8.5))
            [void]$c.Children.Add((New-HDShape 'Ellipse' @{ Width = 1.8; Height = 1.8; Fill = (Get-HDBrush '#7CE08A') } 3.2 10.6))
            [void]$c.Children.Add((New-HDShape 'Ellipse' @{ Width = 1.8; Height = 1.8; Fill = (Get-HDBrush '#7CE08A') } 6 10.6))
        }
    }
    $box = [Windows.Controls.Viewbox]::new()
    $box.Width = 16; $box.Height = 16
    $box.Child = $c
    $box
}

function Get-HDOsLabel([string]$os) {
    switch ($os) { 'linux' { 'Linux' } 'macos' { 'macOS' } 'windows' { 'Windows' } default { 'Other' } }
}

function Get-HDDisplayStatus($h) {
    $st = Get-HDState $h.id
    if ($st.Run) { 'busy' } elseif ($h.address) { $st.Status } else { $null }
}

# MARK: - Views

$ui = Read-HDXaml $MainXaml
$window = $ui.Root
$window.Icon = New-HDAppIcon 64

function New-HDRow($h) {
    $g = [Windows.Controls.Grid]::new()
    foreach ($w in @('Auto', 'Auto', '*', 'Auto')) {
        $cd = [Windows.Controls.ColumnDefinition]::new()
        $cd.Width = [Windows.GridLengthConverter]::new().ConvertFromString($w)
        $g.ColumnDefinitions.Add($cd)
    }
    $dot = New-HDStatusDot (Get-HDDisplayStatus $h)
    $os = New-HDOsIcon $h.os
    $os.Margin = [Windows.Thickness]::new(8, 0, 8, 0)
    $name = [Windows.Controls.TextBlock]::new()
    $name.Text = $h.name
    $name.TextTrimming = 'CharacterEllipsis'
    $name.VerticalAlignment = 'Center'
    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = Get-HDOsLabel $h.os
    $label.FontSize = 12
    $label.Foreground = Get-HDBrush '#6E6E6E'
    $label.VerticalAlignment = 'Center'
    $label.Margin = [Windows.Thickness]::new(8, 0, 2, 0)
    $cells = @($dot, $os, $name, $label)
    for ($i = 0; $i -lt $cells.Count; $i++) { [Windows.Controls.Grid]::SetColumn($cells[$i], $i); [void]$g.Children.Add($cells[$i]) }
    $g
}

function Update-HDList([switch]$Rebuild) {
    $list = $ui.HostList
    if ($Rebuild) {
        $script:Rebuilding = $true
        $list.Items.Clear()
        foreach ($h in $script:Hosts) {
            $item = [Windows.Controls.ListBoxItem]::new()
            $item.Tag = $h.id
            $item.Padding = [Windows.Thickness]::new(6, 6, 6, 6)
            [void]$list.Items.Add($item)
            if ($h.id -eq $script:SelectedId) { $item.IsSelected = $true }
        }
        $script:Rebuilding = $false
    }
    foreach ($item in $list.Items) {
        $h = Find-HDHost $item.Tag
        if ($h) { $item.Content = New-HDRow $h }
    }
    # The footer: how many hosts are online, and the time of the last check.
    $checked = @($script:Hosts | Where-Object { $_.address })
    $online = @($checked | Where-Object { Test-HDOnline $_.id })
    $ui.SummaryText.Text = "$($online.Count) of $($checked.Count) online"
    $ui.CheckedText.Text = if ($script:LastChecked) { "Checked at $($script:LastChecked.ToString('HH:mm:ss'))" } else { 'Not checked yet' }
}

function Get-HDStatusText($h) {
    $st = Get-HDState $h.id
    if ($st.Run) { return 'Working' }
    if (-not $h.address) { return 'No address set' }
    $services = @(Get-HDServices $h)
    switch ($st.Status) {
        'ready' {
            $bad = @($services | Where-Object { $st.Failed -contains $_ })
            if ($bad.Count -eq 0) { return "Online: ready for $((@($services) | ForEach-Object { Get-HDLabel $_ }) -join ' and ')" }
            return "Online, but the last $((@($bad) | ForEach-Object { Get-HDLabel $_ }) -join ' and ') test failed"
        }
        'pingOnly' {
            $closed = @($services | Where-Object { $st.Open -notcontains $_ })
            $ports = (@($closed) | ForEach-Object { "$(Get-HDLabel $_) port $(Get-HDPort $h $_)" }) -join ' and '
            return "Online, but $ports $(if ($closed.Count -eq 1) { 'is' } else { 'are' }) not answering"
        }
        'down' { return 'Offline' }
    }
    'Checking'
}

function Get-HDFooter([string]$os) {
    switch ($os) {
        'linux' { 'With an SSH key, the test logs in over SSH. Connect opens ssh in a terminal. HostDeck does not store passwords.' }
        'macos' { 'With an SSH key, the test logs in over SSH. Screen Sharing starts your VNC viewer with the host.' }
        'windows' { 'The test checks for an RDP handshake. Remote Desktop opens Remote Desktop Connection to the host.' }
        default { 'With an SSH key, the test logs in over SSH. Turn on Wake-on-LAN only if the device supports it.' }
    }
}

function Set-HDVisible($element, [bool]$visible) { $element.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' } }

function Update-HDHints {
    foreach ($pair in @(@('MacBox', 'MacHint'), @('AddressBox', 'AddressHint'), @('PortBox', 'PortHint'), @('SshPortBox', 'SshPortHint'),
                        @('VncPortBox', 'VncPortHint'), @('UserBox', 'UserHint'), @('KeyBox', 'KeyHint'))) {
        Set-HDVisible $ui[$pair[1]] ($ui[$pair[0]].Text.Length -eq 0)
    }
}

# The rows that apply to the OS type and the services of the host.
function Update-HDFields($h) {
    $isMac = $h.os -eq 'macos'
    Set-HDVisible $ui.RowWake ($h.os -ne 'windows')
    Set-HDVisible $ui.RowMac (Test-HDCanWake $h)
    Set-HDVisible $ui.MacWarn ($h.mac -and -not (Test-HDMacValid $h.mac))
    Set-HDVisible $ui.AddressWarn (Test-HDAddressUnsafe $h)
    Set-HDVisible $ui.RowPort (-not $isMac)
    $ui.PortLabel.Text = if ($h.os -eq 'windows') { 'RDP port' } else { 'SSH port' }
    $ui.PortHint.Text = if ($h.os -eq 'windows') { '3389' } else { '22' }
    Set-HDVisible $ui.MacCard $isMac
    Set-HDVisible $ui.RowSshPort ([bool]$h.sshEnabled)
    Set-HDVisible $ui.RowVncPort ([bool]$h.vncEnabled)
    # You cannot turn off the last service that is on.
    $ui.SshCheck.IsEnabled = -not ($h.sshEnabled -and -not $h.vncEnabled)
    $ui.VncCheck.IsEnabled = -not ($h.vncEnabled -and -not $h.sshEnabled)
    Set-HDVisible $ui.SshCard ($h.os -ne 'windows')
    Set-HDVisible $ui.RowKey (@(Get-HDServices $h) -contains 'ssh')
    Set-HDVisible $ui.UserWarn (Test-HDUserUnsafe $h)
    Set-HDVisible $ui.KeyWarn (Test-HDKeyMissing $h)
    $ui.FooterText.Text = Get-HDFooter $h.os
    Update-HDHints
}

# Fill the fields with the selected host.
function Show-HDHost {
    $h = Get-HDSelected
    Set-HDVisible $ui.Detail ($null -ne $h)
    Set-HDVisible $ui.EmptyText ($null -eq $h)
    if (-not $h) { return }
    $script:Loading = $true
    try {
        $ui.NameBox.Text = $h.name
        foreach ($r in @($ui.OsLinux, $ui.OsMacos, $ui.OsWindows, $ui.OsOther)) { $r.IsChecked = ($r.Tag -eq $h.os) }
        $ui.WakeCheck.IsChecked = [bool]$h.wakeEnabled
        $ui.MacBox.Text = $h.mac
        $ui.AddressBox.Text = $h.address
        $portText = if ($null -ne $h.port) { [string]$h.port } else { '' }
        $ui.PortBox.Text = $portText
        $ui.SshPortBox.Text = $portText
        $ui.VncPortBox.Text = if ($null -ne $h.vncPort) { [string]$h.vncPort } else { '' }
        $ui.SshCheck.IsChecked = [bool]$h.sshEnabled
        $ui.VncCheck.IsChecked = [bool]$h.vncEnabled
        $ui.UserBox.Text = $h.user
        $ui.KeyBox.Text = $h.sshKey
        foreach ($w in @($ui.PortWarn, $ui.SshPortWarn, $ui.VncPortWarn)) { Set-HDVisible $w $false }
    } finally {
        $script:Loading = $false
    }
    $script:ServiceSignature = ''
    Update-HDFields $h
    Update-HDDetail
}

# The parts of the detail view that change while HostDeck checks the host: buttons, status and log.
function Update-HDDetail {
    $h = Get-HDSelected
    if (-not $h) { $window.Title = 'HostDeck'; return }
    $window.Title = "HostDeck: $($h.name)"
    $st = Get-HDState $h.id
    $busy = [bool]$st.Run
    $online = Test-HDOnline $h.id
    $canWake = Test-HDCanWake $h
    $macOk = Test-HDMacValid $h.mac
    $connect = Get-HDConnectService $h

    Set-HDVisible $ui.WakeButton ($canWake -and -not $busy)
    $ui.WakeButton.IsEnabled = $macOk -and -not $online
    $ui.WakeButton.ToolTip = if (-not $macOk) { 'Set a valid MAC address' } elseif ($online) { 'The host is already awake' } else { 'Send the wake packet, then wait for the host (Ctrl+Enter)' }
    Set-HDVisible $ui.WakeConnectButton ($canWake -and $connect -and -not $busy)
    $ui.WakeConnectButton.IsEnabled = $macOk -and [bool]$h.address -and -not $online
    $ui.WakeConnectButton.ToolTip = if (-not $macOk) { 'Set a valid MAC address' } elseif (-not $h.address) { 'Set an address' } elseif ($online) { 'The host is already awake' } else { "Wake, then open $(Get-HDServiceAction $connect) when the host is ready (Ctrl+Shift+Enter)" }
    Set-HDVisible $ui.TestButton (-not $busy)
    $ui.TestButton.IsEnabled = [bool]$h.address
    $ui.TestButton.ToolTip = if ($h.address) { 'Do each check one time (Ctrl+T)' } else { 'Set an address' }
    Set-HDVisible $ui.CancelButton $busy
    $ui.CancelButton.ToolTip = 'Stop the run (Esc)'

    $ui.StatusDotHost.Content = New-HDStatusDot (Get-HDDisplayStatus $h)
    $ui.StatusText.Text = Get-HDStatusText $h

    # Rebuild the service buttons only when the services change, so that a button does not move under the pointer.
    $services = @(Get-HDServices $h)
    $signature = "$($h.id)|$($services -join ',')"
    if ($signature -ne $script:ServiceSignature) {
        $script:ServiceSignature = $signature
        $ui.ServicePanel.Children.Clear()
        foreach ($svc in $services) {
            $b = [Windows.Controls.Button]::new()
            $b.Style = $window.FindResource('Action')
            $b.Background = $window.FindResource('Accent')
            $b.Content = Get-HDServiceAction $svc
            $b.Tag = $svc
            $b.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
            $b.Add_Click({ param($s, $e) $hh = Get-HDSelected; if ($hh) { Connect-HDService $hh $s.Tag } })
            [void]$ui.ServicePanel.Children.Add($b)
        }
    }
    foreach ($b in $ui.ServicePanel.Children) {
        $reason = Get-HDNotReadyReason $h $b.Tag
        $b.IsEnabled = $null -eq $reason
        $b.ToolTip = if ($reason) { $reason } elseif ($b.Tag -eq 'ssh') { "Open ssh to $(Get-HDSshTarget $h) in a terminal" } elseif ($b.Tag -eq 'rdp') { 'Open Remote Desktop Connection' } else { "Open $((Get-HDVncViewer).Name)" }
    }

    $text = $st.Log -join [Environment]::NewLine
    if ($ui.LogBox.Text -ne $text) {
        $ui.LogBox.Text = $text
        $ui.LogBox.ScrollToEnd()
    }
    $ui.ClearLogButton.IsEnabled = -not $busy -and $st.Log.Count -gt 0
}

function Update-HDView { Update-HDList; Update-HDDetail }

# A change to the selected host from a field.
function Set-HDField([string]$key, $value, [switch]$Recheck) {
    if ($script:Loading) { return }
    $h = Get-HDSelected
    if (-not $h) { return }
    if ($h[$key] -ceq $value) { Update-HDHints; return }
    $h[$key] = $value
    Set-HDDirty
    if ($Recheck) { Request-HDCheck $h }
    Update-HDFields $h
    Update-HDView
}

function Read-HDPortText([string]$text) {
    $t = $text.Trim()
    $n = 0
    if (-not $t) { return @{ Ok = $true; Value = $null } }
    if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le 65535) { return @{ Ok = $true; Value = $n } }
    @{ Ok = $false }
}

function Set-HDPortField([string]$key, $box, $warn) {
    Update-HDHints
    if ($script:Loading) { return }
    $r = Read-HDPortText $box.Text
    Set-HDVisible $warn (-not $r.Ok)
    if ($r.Ok) { Set-HDField $key $r.Value -Recheck }
}

# MARK: - Commands

function Select-HDHost([string]$id) {
    foreach ($item in $ui.HostList.Items) { if ($item.Tag -eq $id) { $item.IsSelected = $true; $ui.HostList.ScrollIntoView($item) } }
}

function Add-HDHost {
    $h = New-HDHost
    [void]$script:Hosts.Add($h)
    $script:SelectedId = $h.id
    Set-HDDirty
    Update-HDList -Rebuild
    Show-HDHost
    [void]$ui.NameBox.Focus()
    $ui.NameBox.SelectAll()
}

function Remove-HDHost {
    $h = Get-HDSelected
    if (-not $h) { return }
    $answer = [Windows.MessageBox]::Show($window, "Delete $($h.name)? You cannot undo this.", 'Delete Host', 'YesNo', 'Warning', 'No')
    if ($answer -ne 'Yes') { return }
    Stop-HDRun $h.id
    $i = $script:Hosts.IndexOf($h)
    $script:Hosts.Remove($h)
    $script:States.Remove($h.id)
    $script:SelectedId = if ($script:Hosts.Count) { $script:Hosts[[Math]::Min($i, $script:Hosts.Count - 1)].id } else { $null }
    Set-HDDirty
    Update-HDList -Rebuild
    Show-HDHost
}

function Move-HDHost([int]$by) {
    $h = Get-HDSelected
    if (-not $h) { return }
    $i = $script:Hosts.IndexOf($h)
    $j = $i + $by
    if ($j -lt 0 -or $j -ge $script:Hosts.Count) { return }
    $script:Hosts.RemoveAt($i)
    $script:Hosts.Insert($j, $h)
    Set-HDDirty
    Update-HDList -Rebuild
}

function Invoke-HDSelected([string]$action) {
    $h = Get-HDSelected
    if (-not $h) { return }
    $st = Get-HDState $h.id
    $online = Test-HDOnline $h.id
    switch ($action) {
        'wake' { if (-not $st.Run -and (Test-HDCanWake $h) -and (Test-HDMacValid $h.mac) -and -not $online) { Start-HDRun $h $true $false } }
        'wakeconnect' { if (-not $st.Run -and (Test-HDCanWake $h) -and (Get-HDConnectService $h) -and (Test-HDMacValid $h.mac) -and $h.address -and -not $online) { Start-HDRun $h $true $true } }
        'test' { if (-not $st.Run -and $h.address) { Start-HDRun $h $false $false } }
        'cancel' { Stop-HDRun $h.id }
        'clearlog' { if (-not $st.Run) { $st.Log.Clear(); Update-HDDetail } }
    }
}

function Show-HDMessage([string]$title, [string]$text, [string]$icon = 'Information') {
    [void][Windows.MessageBox]::Show($window, $text, $title, 'OK', $icon)
}

function Export-HDHosts {
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.Title = 'Export Hosts'
    $dlg.Filter = 'JSON files (*.json)|*.json'
    $dlg.FileName = "HostDeck hosts $((Get-Date).ToString('yyyy-MM-dd')).json"
    if (-not $dlg.ShowDialog($window)) { return }
    try {
        Write-HDTextFile $dlg.FileName (New-HDFileText $script:Hosts $script:Settings)
        Show-HDMessage "Exported $($script:Hosts.Count) hosts" "HostDeck wrote the hosts and settings to $([IO.Path]::GetFileName($dlg.FileName))."
    } catch {
        Show-HDMessage 'Cannot export the hosts' $_.Exception.Message 'Error'
    }
}

# Merge by host ID: a host with a known ID replaces that host, and other hosts are added.
# Import does not delete hosts. Settings in the file replace the current settings.
function Import-HDHosts {
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title = 'Import Hosts'
    $dlg.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return }
    try {
        $data = Read-HDFile ([IO.File]::ReadAllText($dlg.FileName))
    } catch {
        return Show-HDMessage 'Cannot import the hosts' "$([IO.Path]::GetFileName($dlg.FileName)): $($_.Exception.Message) HostDeck imported no hosts." 'Warning'
    }
    $merge = Merge-HDHosts $script:Hosts $data.Hosts
    $script:Hosts = $merge.List
    foreach ($k in $data.Settings.Keys) { $script:Settings[$k] = $data.Settings[$k] }
    Set-HDDirty
    if (-not (Find-HDHost $script:SelectedId) -and $script:Hosts.Count) { $script:SelectedId = $script:Hosts[0].id }
    Update-HDList -Rebuild
    Show-HDHost
    foreach ($h in $data.Hosts) { Request-HDCheck $h }
    $text = "$($merge.Added) added, $($merge.Replaced) replaced."
    $missing = @($data.Hosts | Where-Object { Test-HDKeyMissing $_ })
    if ($missing.Count) {
        $text += " The SSH key of $($missing.Count) host(s) is not on this PC: $(($missing | ForEach-Object { $_.name }) -join ', '). Set a new key path for them."
    }
    Show-HDMessage "Imported $($data.Hosts.Count) hosts" $text
}

function Show-HDSettings {
    $s = Read-HDXaml $SettingsXaml
    $script:SettingsUi = $s
    $s.Root.Owner = $window
    $s.Root.Icon = $window.Icon
    $s.BroadcastBox.Text = $script:Settings.broadcast
    $s.PortBox.Text = [string]$script:Settings.port
    $s.TimeoutBox.Text = [string]$script:Settings.timeout
    $s.OkButton.Add_Click({
        $s = $script:SettingsUi
        $port = 0
        $timeout = 0
        $err = $null
        if (-not (Test-HDIPv4 $s.BroadcastBox.Text.Trim())) {
            $err = 'The broadcast address must be an IPv4 address, for example 192.168.1.255.'
        } elseif (-not [int]::TryParse($s.PortBox.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            $err = 'The UDP port must be a number from 1 to 65535.'
        } elseif (-not [int]::TryParse($s.TimeoutBox.Text.Trim(), [ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 86400) {
            $err = 'The timeout must be a number of seconds from 1 to 86400.'
        }
        if ($err) {
            $s.ErrorText.Text = $err
            Set-HDVisible $s.ErrorText $true
            return
        }
        $script:Settings.broadcast = $s.BroadcastBox.Text.Trim()
        $script:Settings.port = $port
        $script:Settings.timeout = $timeout
        Set-HDDirty
        $s.Root.DialogResult = $true
    })
    [void]$s.Root.ShowDialog()
}

# MARK: - Notification area

function Show-HDWindow {
    $window.Show()
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    [void]$window.Activate()
}

$script:Tray = [Windows.Forms.NotifyIcon]::new()
$script:Tray.Text = 'HostDeck'
$iconBitmap = [Drawing.Bitmap]::new([IO.MemoryStream]::new((ConvertTo-HDPng (New-HDAppIcon 32))))
$script:Tray.Icon = [Drawing.Icon]::FromHandle($iconBitmap.GetHicon())
$script:TrayMenu = [Windows.Forms.ContextMenuStrip]::new()
$script:Tray.ContextMenuStrip = $script:TrayMenu

$script:TrayClick = {
    param($s, $e)
    try {
        $t = $s.Tag
        $h = Find-HDHost $t.Id
        if (-not $h) { return }
        switch ($t.Action) {
            'wake' { Start-HDRun $h $true $false }
            'wakeconnect' { Start-HDRun $h $true $true }
            'test' { Start-HDRun $h $false $false }
            'connect' { Connect-HDService $h $t.Service }
            'show' { $script:SelectedId = $h.id; Select-HDHost $h.id; Show-HDWindow }
        }
    } catch { Write-HDError $_ }
}

function New-HDTrayItem([string]$text, [hashtable]$tag, [bool]$enabled = $true) {
    $item = [Windows.Forms.ToolStripMenuItem]::new($text)
    $item.Tag = $tag
    $item.Enabled = $enabled
    $item.Add_Click($script:TrayClick)
    $item
}

# The same commands for each host as the window, when the window is closed.
function Update-HDTrayMenu {
    $menu = $script:TrayMenu
    $menu.Items.Clear()
    foreach ($h in $script:Hosts) {
        $st = Get-HDState $h.id
        $mark = switch (Get-HDDisplayStatus $h) { 'busy' { [char]0x25CC } 'ready' { [char]0x25CF } 'pingOnly' { [char]0x25D0 } 'down' { [char]0x25CB } default { ' ' } }
        $top = [Windows.Forms.ToolStripMenuItem]::new("$mark  $($h.name)")
        $online = Test-HDOnline $h.id
        $macOk = Test-HDMacValid $h.mac
        $free = -not $st.Run
        if (Test-HDCanWake $h) {
            [void]$top.DropDownItems.Add((New-HDTrayItem 'Wake' @{ Id = $h.id; Action = 'wake' } ($free -and $macOk -and -not $online)))
            if (Get-HDConnectService $h) {
                [void]$top.DropDownItems.Add((New-HDTrayItem 'Wake and Connect' @{ Id = $h.id; Action = 'wakeconnect' } ($free -and $macOk -and [bool]$h.address -and -not $online)))
            }
        }
        [void]$top.DropDownItems.Add((New-HDTrayItem 'Test' @{ Id = $h.id; Action = 'test' } ($free -and [bool]$h.address)))
        [void]$top.DropDownItems.Add([Windows.Forms.ToolStripSeparator]::new())
        foreach ($svc in @(Get-HDServices $h)) {
            [void]$top.DropDownItems.Add((New-HDTrayItem (Get-HDServiceAction $svc) @{ Id = $h.id; Action = 'connect'; Service = $svc } ($null -eq (Get-HDNotReadyReason $h $svc))))
        }
        [void]$top.DropDownItems.Add([Windows.Forms.ToolStripSeparator]::new())
        [void]$top.DropDownItems.Add((New-HDTrayItem 'Show in HostDeck' @{ Id = $h.id; Action = 'show' }))
        [void]$menu.Items.Add($top)
    }
    if ($script:Hosts.Count) { [void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new()) }
    $open = [Windows.Forms.ToolStripMenuItem]::new('Open HostDeck')
    $open.Font = [Drawing.Font]::new($open.Font, [Drawing.FontStyle]::Bold)
    $open.Add_Click({ Show-HDWindow })
    [void]$menu.Items.Add($open)
    $exit = [Windows.Forms.ToolStripMenuItem]::new('Exit HostDeck')
    $exit.Add_Click({ Exit-HD })
    [void]$menu.Items.Add($exit)
}

$script:TrayMenu.Add_Opening({ param($s, $e) try { Update-HDTrayMenu } catch { Write-HDError $_ }; $e.Cancel = $false })
$script:Tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-HDWindow } })

function Exit-HD {
    $script:Exiting = $true
    foreach ($id in @($script:States.Keys)) { Stop-HDRun $id }
    try { if ($script:DirtyAt) { Save-HDStore } } catch { Write-HDError $_ }
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    $window.Close()
    [Windows.Application]::Current.Shutdown()
}

# MARK: - Events

$ui.NameBox.Add_TextChanged({ Set-HDField 'name' $ui.NameBox.Text })
foreach ($r in @($ui.OsLinux, $ui.OsMacos, $ui.OsWindows, $ui.OsOther)) {
    $r.Add_Checked({ param($s, $e) Set-HDField 'os' $s.Tag -Recheck })
}
$ui.WakeCheck.Add_Click({ Set-HDField 'wakeEnabled' ([bool]$ui.WakeCheck.IsChecked) })
$ui.MacBox.Add_TextChanged({ Set-HDField 'mac' $ui.MacBox.Text.Trim() })
$ui.AddressBox.Add_TextChanged({ Set-HDField 'address' $ui.AddressBox.Text.Trim() -Recheck })
$ui.PortBox.Add_TextChanged({ Set-HDPortField 'port' $ui.PortBox $ui.PortWarn })
$ui.SshPortBox.Add_TextChanged({ Set-HDPortField 'port' $ui.SshPortBox $ui.SshPortWarn })
$ui.VncPortBox.Add_TextChanged({ Set-HDPortField 'vncPort' $ui.VncPortBox $ui.VncPortWarn })
$ui.SshCheck.Add_Click({ Set-HDField 'sshEnabled' ([bool]$ui.SshCheck.IsChecked) -Recheck })
$ui.VncCheck.Add_Click({ Set-HDField 'vncEnabled' ([bool]$ui.VncCheck.IsChecked) -Recheck })
$ui.UserBox.Add_TextChanged({ Set-HDField 'user' $ui.UserBox.Text.Trim() })
$ui.KeyBox.Add_TextChanged({ Set-HDField 'sshKey' $ui.KeyBox.Text.Trim() })
$ui.KeyBrowse.Add_Click({
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title = 'Choose the private SSH key'
    $sshDir = Join-Path $HOME '.ssh'
    if (Test-Path -LiteralPath $sshDir) { $dlg.InitialDirectory = $sshDir }
    if ($dlg.ShowDialog($window)) { $ui.KeyBox.Text = $dlg.FileName }
})

$ui.HostList.Add_SelectionChanged({
    if ($script:Rebuilding) { return }
    $item = $ui.HostList.SelectedItem
    $script:SelectedId = if ($item) { $item.Tag } else { $null }
    Show-HDHost
    $h = Get-HDSelected
    if ($h) { Start-HDProbe $h }
})

$ui.AddButton.Add_Click({ Add-HDHost })
$ui.HelpButton.Add_Click({ Start-Process $HDHelpUrl })
$ui.WakeButton.Add_Click({ Invoke-HDSelected 'wake' })
$ui.WakeConnectButton.Add_Click({ Invoke-HDSelected 'wakeconnect' })
$ui.TestButton.Add_Click({ Invoke-HDSelected 'test' })
$ui.CancelButton.Add_Click({ Invoke-HDSelected 'cancel' })
$ui.ClearLogButton.Add_Click({ Invoke-HDSelected 'clearlog' })

$ui.MenuImport.Add_Click({ Import-HDHosts })
$ui.MenuExport.Add_Click({ Export-HDHosts })
$ui.MenuSettings.Add_Click({ Show-HDSettings })
$ui.MenuClose.Add_Click({ $window.Close() })
$ui.MenuExit.Add_Click({ Exit-HD })
$ui.MenuAdd.Add_Click({ Add-HDHost })
$ui.MenuDelete.Add_Click({ Remove-HDHost })
$ui.MenuUp.Add_Click({ Move-HDHost -1 })
$ui.MenuDown.Add_Click({ Move-HDHost 1 })
$ui.MenuWake.Add_Click({ Invoke-HDSelected 'wake' })
$ui.MenuWakeConnect.Add_Click({ Invoke-HDSelected 'wakeconnect' })
$ui.MenuTest.Add_Click({ Invoke-HDSelected 'test' })
$ui.MenuCancel.Add_Click({ Invoke-HDSelected 'cancel' })
$ui.MenuClearLog.Add_Click({ Invoke-HDSelected 'clearlog' })
$ui.MenuHelp.Add_Click({ Start-Process $HDHelpUrl })
$ui.MenuDataFolder.Add_Click({
    if (-not (Test-Path -LiteralPath $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir) }
    Start-Process explorer.exe -ArgumentList (ConvertTo-HDArg $DataDir)
})
$ui.ListWake.Add_Click({ Invoke-HDSelected 'wake' })
$ui.ListWakeConnect.Add_Click({ Invoke-HDSelected 'wakeconnect' })
$ui.ListTest.Add_Click({ Invoke-HDSelected 'test' })
$ui.ListUp.Add_Click({ Move-HDHost -1 })
$ui.ListDown.Add_Click({ Move-HDHost 1 })
$ui.ListDelete.Add_Click({ Remove-HDHost })

# Grey out the commands that do not apply now, in the Host menu and in the list menu.
$updateMenus = {
    $h = Get-HDSelected
    $has = $null -ne $h
    $st = if ($has) { Get-HDState $h.id } else { @{ Run = $null; Log = @() } }
    $free = $has -and -not $st.Run
    $online = $has -and (Test-HDOnline $h.id)
    $canWake = $free -and (Test-HDCanWake $h) -and (Test-HDMacValid $h.mac) -and -not $online
    $wakeConnect = $canWake -and [bool]$h.address -and [bool](Get-HDConnectService $h)
    $i = if ($has) { $script:Hosts.IndexOf($h) } else { -1 }
    foreach ($m in @($ui.MenuWake, $ui.ListWake)) { $m.IsEnabled = $canWake }
    foreach ($m in @($ui.MenuWakeConnect, $ui.ListWakeConnect)) { $m.IsEnabled = $wakeConnect }
    foreach ($m in @($ui.MenuTest, $ui.ListTest)) { $m.IsEnabled = $free -and [bool]$h.address }
    foreach ($m in @($ui.MenuUp, $ui.ListUp)) { $m.IsEnabled = $i -gt 0 }
    foreach ($m in @($ui.MenuDown, $ui.ListDown)) { $m.IsEnabled = $i -ge 0 -and $i -lt $script:Hosts.Count - 1 }
    foreach ($m in @($ui.MenuDelete, $ui.ListDelete)) { $m.IsEnabled = $has }
    $ui.MenuCancel.IsEnabled = $has -and [bool]$st.Run
    $ui.MenuClearLog.IsEnabled = $free -and $st.Log.Count -gt 0
}
$ui.MenuHost.Add_SubmenuOpened($updateMenus)
$ui.ListMenu.Add_Opened($updateMenus)

$window.Add_PreviewKeyDown({
    param($s, $e)
    try {
        $mods = [Windows.Input.Keyboard]::Modifiers
        $ctrl = ($mods -band [Windows.Input.ModifierKeys]::Control) -ne 0
        $shift = ($mods -band [Windows.Input.ModifierKeys]::Shift) -ne 0
        $key = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
        $handled = $true
        if ($ctrl -and $key -eq 'Return') { Invoke-HDSelected $(if ($shift) { 'wakeconnect' } else { 'wake' }) }
        elseif ($ctrl -and -not $shift -and $key -eq 'T') { Invoke-HDSelected 'test' }
        elseif ($ctrl -and -not $shift -and $key -eq 'K') { Invoke-HDSelected 'clearlog' }
        elseif ($ctrl -and -not $shift -and $key -eq 'N') { Add-HDHost }
        elseif ($ctrl -and $shift -and $key -eq 'E') { Export-HDHosts }
        elseif ($ctrl -and $key -eq 'OemComma') { Show-HDSettings }
        elseif ($key -eq 'Escape' -and (Get-HDSelected) -and (Get-HDState $script:SelectedId).Run) { Invoke-HDSelected 'cancel' }
        elseif ($key -eq 'Delete' -and $ui.HostList.IsKeyboardFocusWithin) { Remove-HDHost }
        elseif ($mods -eq 'Alt' -and $key -eq 'Up') { Move-HDHost -1 }
        elseif ($mods -eq 'Alt' -and $key -eq 'Down') { Move-HDHost 1 }
        else { $handled = $false }
        $e.Handled = $handled
    } catch { Write-HDError $_ }
})

# Closing the window keeps HostDeck in the notification area, as the Mac app keeps its menu bar icon.
$window.Add_Closing({
    param($s, $e)
    if ($script:Exiting) { return }
    $e.Cancel = $true
    $window.Hide()
    if (-not $script:TrayHintShown) {
        $script:TrayHintShown = $true
        $script:Tray.ShowBalloonTip(4000, 'HostDeck is still running', 'Click the HostDeck icon in the notification area to open it. Right-click it for the hosts, or to exit.', 'Info')
    }
})

# MARK: - Timers

# Handle the messages from the background jobs, start the checks that are due, and save changes.
$script:Pump = [Windows.Threading.DispatcherTimer]::new()
$script:Pump.Interval = [TimeSpan]::FromMilliseconds(100)
$script:Pump.Add_Tick({
    try {
        $changed = $false
        $m = $null
        while ($script:Queue.TryDequeue([ref]$m)) { Receive-HDMessage $m; $changed = $true }
        foreach ($j in @($script:Jobs)) {
            if ($j.Handle.IsCompleted) {
                try { [void]$j.PS.EndInvoke($j.Handle) } catch { Write-HDError $_ }
                $j.PS.Dispose()
                $script:Jobs.Remove($j)
            }
        }
        $now = Get-Date
        foreach ($id in @($script:CheckAt.Keys)) {
            if ($script:CheckAt[$id] -le $now) {
                $script:CheckAt.Remove($id)
                $h = Find-HDHost $id
                if ($h) { Start-HDProbe $h; $changed = $true }
            }
        }
        if ($script:DirtyAt -and ($now - $script:DirtyAt).TotalMilliseconds -gt 500) { Save-HDStore }
        if ($script:ShowEvent.WaitOne(0)) { Show-HDWindow }
        if ($changed) { Update-HDView }
    } catch { Write-HDError $_ }
})

# Check each host every 15 seconds.
$script:Poll = [Windows.Threading.DispatcherTimer]::new()
$script:Poll.Interval = [TimeSpan]::FromSeconds(15)
$script:Poll.Add_Tick({ try { foreach ($h in $script:Hosts) { Start-HDProbe $h } } catch { Write-HDError $_ } })

# MARK: - Start

foreach ($pair in @(@('ready', 'Ready'), @('pingOnly', 'Online, service not answering'), @('down', 'Offline'), @($null, 'Not checked'))) {
    $row = [Windows.Controls.StackPanel]::new()
    $row.Orientation = 'Horizontal'
    $row.Margin = [Windows.Thickness]::new(0, 0, 0, 5)
    [void]$row.Children.Add((New-HDStatusDot $pair[0] 14))
    $t = [Windows.Controls.TextBlock]::new()
    $t.Text = $pair[1]
    $t.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
    $t.VerticalAlignment = 'Center'
    [void]$row.Children.Add($t)
    [void]$ui.KeyPanel.Children.Add($row)
}

if (-not (Test-Path -LiteralPath $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir) }
Import-HDStore
if ($Select) { $script:SelectedId = ($script:Hosts | Where-Object { $_.name -eq $Select } | Select-Object -First 1).id }
if (-not $script:SelectedId -and $script:Hosts.Count) { $script:SelectedId = $script:Hosts[0].id }
Update-HDList -Rebuild
Show-HDHost

$app = [Windows.Application]::Current
if (-not $app) { $app = [Windows.Application]::new() }
$app.ShutdownMode = 'OnExplicitShutdown'

$window.Add_ContentRendered({
    if ($script:LoadError) { Show-HDMessage 'HostDeck' $script:LoadError 'Warning'; $script:LoadError = $null }
    if ($Action -and -not $script:ActionDone) {
        $script:ActionDone = $true
        # Wait for the first check, so that Wake knows if the host is already online.
        $script:ActionTimer = [Windows.Threading.DispatcherTimer]::new()
        $script:ActionTimer.Interval = [TimeSpan]::FromSeconds(1.5)
        $script:ActionTimer.Add_Tick({ $script:ActionTimer.Stop(); try { Invoke-HDSelected $Action } catch { Write-HDError $_ } })
        $script:ActionTimer.Start()
    }
    if ($Screenshot) {
        $script:ShotTimer = [Windows.Threading.DispatcherTimer]::new()
        $script:ShotTimer.Interval = [TimeSpan]::FromSeconds($ScreenshotDelay)
        $script:ShotTimer.Add_Tick({
            $script:ShotTimer.Stop()
            try {
                $content = $window.Content
                $w = [int]$content.ActualWidth
                $hh = [int]$content.ActualHeight
                $dv = [Windows.Media.DrawingVisual]::new()
                $dc = $dv.RenderOpen()
                $dc.DrawRectangle($window.Background, $null, [Windows.Rect]::new(0, 0, $w, $hh))
                $dc.DrawRectangle([Windows.Media.VisualBrush]::new($content), $null, [Windows.Rect]::new(0, 0, $w, $hh))
                $dc.Close()
                $bmp = [Windows.Media.Imaging.RenderTargetBitmap]::new($w, $hh, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                $bmp.Render($dv)
                [IO.File]::WriteAllBytes($Screenshot, (ConvertTo-HDPng $bmp))
            } catch { Write-HDError $_ }
            Exit-HD
        })
        $script:ShotTimer.Start()
    }
})

$script:Tray.Visible = $true
$script:Pump.Start()
$script:Poll.Start()
foreach ($h in $script:Hosts) { Start-HDProbe $h }
$window.Show()
try {
    [void]$app.Run()
} finally {
    $script:Pump.Stop()
    $script:Poll.Stop()
    foreach ($id in @($script:States.Keys)) { Stop-HDRun $id }
    $script:Pool.Close()
    $script:Pool.Dispose()
    $script:Mutex.ReleaseMutex()
}
