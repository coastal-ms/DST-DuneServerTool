[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$ParentId,
    [Parameter(Mandatory)][string]$CompanionPath, [int]$Port = 18749, [switch]$LoopbackOnly,
    [switch]$SkipFirewall)
$ErrorActionPreference = 'Stop'
$listener = $null
$rsa = $null
$certificate = $null
$firewallName = 'DSTDeck-' + [guid]::NewGuid().ToString('N')

function Write-BridgeJson([string]$Name, $Value) {
    $temp = Join-Path $Root ($Name + '.tmp')
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination (Join-Path $Root $Name) -Force
}
function Send-BridgeResponse($Stream, [int]$Code, [byte[]]$Bytes, [string]$Type = 'application/json') {
    $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Code Response`r`nContent-Length: $($Bytes.Length)`r`nContent-Type: $Type`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}
function Reply-BridgeJson($Stream, [int]$Code, $Value) {
    Send-BridgeResponse $Stream $Code ([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 20 -Compress)))
}
try {
    $publicKey = [IO.File]::ReadAllText((Join-Path $Root 'ssh_key.pub')).Trim()
    $code = [guid]::NewGuid().ToString('N').Substring(0,6).ToUpperInvariant()
    $pairUntil = [DateTime]::UtcNow.AddMinutes(10)
    $certificatePath = Join-Path $Root 'pairing-certificate.pfx'
    if (Test-Path -LiteralPath $certificatePath -PathType Leaf) {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath,'',[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)
    } else {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=DST Deck Pairing', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddYears(2))
        [IO.File]::WriteAllBytes($certificatePath,$certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx,''))
        $certificate.Dispose()
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath,'',[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)
    }
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($certificate.RawData))
    $bind = if ($LoopbackOnly) { [Net.IPAddress]::Loopback } else { [Net.IPAddress]::Any }
    $listener = [Net.Sockets.TcpListener]::new($bind,$Port)
    $listener.Start()
    if (-not $LoopbackOnly -and -not $SkipFirewall -and (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $firewallName -DisplayName 'DST Steam Deck pairing' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress LocalSubnet -Profile Private -Program (Get-Process -Id $PID).Path | Out-Null
    }
    Write-BridgeJson 'bridge-status.json' @{ok=$true;pid=$PID;port=$Port;code=$code;certificateFingerprint=$fingerprint;pairExpires=$pairUntil.ToString('o');firewallName=$firewallName}
    $failures = 0
    while (Get-Process -Id $ParentId -ErrorAction SilentlyContinue) {
        if(Test-Path -LiteralPath (Join-Path $Root ('bridge-stop-'+$PID))){break}
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 250; continue }
        $client = $listener.AcceptTcpClient()
        $tls = $null
        $path = ''
        $clientAuth = $false
        try {
            $peer = $client.Client.RemoteEndPoint.Address.ToString()
            $client.ReceiveTimeout=10000; $client.SendTimeout=30000
            $tls = [Net.Security.SslStream]::new($client.GetStream(),$false)
            $tls.ReadTimeout=10000; $tls.WriteTimeout=30000
            $tls.AuthenticateAsServer($certificate,$false,[Security.Authentication.SslProtocols]::Tls12,$false)
            $header = [Collections.Generic.List[byte]]::new()
            while ($header.Count -lt 16384) {
                $next=$tls.ReadByte(); if ($next -lt 0) { throw 'Incomplete request' }; $header.Add([byte]$next)
                $n=$header.Count
                if ($n -ge 4 -and $header[$n-4] -eq 13 -and $header[$n-3] -eq 10 -and $header[$n-2] -eq 13 -and $header[$n-1] -eq 10) { break }
            }
            $lines=[Text.Encoding]::ASCII.GetString($header.ToArray()).Split(@("`r`n"),[StringSplitOptions]::None)
            if ($lines[0] -notmatch '^(GET|POST) (/[-a-z]+) HTTP/1\.[01]$') { throw 'Unsupported request' }
            $method=$Matches[1];$path=$Matches[2];$headers=@{}
            foreach($line in $lines[1..($lines.Count-1)]) { if($line -match '^([^:]+):\s*(.*)$') {$headers[$Matches[1].ToLowerInvariant()]=$Matches[2]} }
            if ($headers.ContainsKey('transfer-encoding')) { throw 'Chunked request unsupported' }
            $connectionPath=Join-Path $Root 'connection.json'
            $connection=if(Test-Path -LiteralPath $connectionPath){Get-Content -LiteralPath $connectionPath -Raw|ConvertFrom-Json}else{$null}
            $paired=$connection -and $connection.host -eq $peer
            $pairAuth=$failures -lt 10 -and [DateTime]::UtcNow -lt $pairUntil -and $headers.authorization -ceq ('Bearer '+$code)
            $clientAuth=$paired -and $connection.clientToken -and $headers.authorization -ceq ('Bearer '+$connection.clientToken)
            if ($method -eq 'GET' -and $path -eq '/app') { Send-BridgeResponse $tls 200 ([IO.File]::ReadAllBytes($CompanionPath)) 'application/x-sh'; continue }
            if ($method -eq 'GET' -and $path -eq '/mods' -and $clientAuth) {
                Send-BridgeResponse $tls 200 ([IO.File]::ReadAllBytes((Join-Path $Root 'mods-bundle.zip'))) 'application/zip'; continue
            }
            if ($method -eq 'GET' -and $path -eq '/mods-info' -and $clientAuth) {
                # Companion-initiated sync must use today's PC selection, not
                # the last package somebody previewed in the desktop tab.
                $script:AppDir=Split-Path (Split-Path (Split-Path $CompanionPath))
                foreach($library in @('SoloXbox.ps1','SoloMode.ps1','SoloMods.ps1','SoloDeckMods.ps1')) {
                    . (Join-Path $script:AppDir ('server/lib/'+$library))
                }
                $metadata=New-DuneSoloDeckModBundle -Status (Get-DuneSoloMods) -Output (Join-Path $Root 'mods-bundle.zip')
                Write-BridgeJson 'mods-bundle.json' $metadata
                $local=$client.Client.LocalEndPoint.Address.ToString()
                Reply-BridgeJson $tls 200 @{ok=$true;url="https://${local}:$Port/mods";sha256=$metadata.sha256;mods=$metadata.mods};continue
            }
            if (-not $pairAuth) { $failures++; Reply-BridgeJson $tls 403 @{ok=$false;error='Pairing code expired or invalid'};continue }
            if ($method -eq 'GET' -and $path -eq '/ssh-info') { Reply-BridgeJson $tls 200 @{public_key=$publicKey};continue }
            if ($method -eq 'POST' -and $path -eq '/ssh-paired') {
                $size=0
                if (-not [int]::TryParse([string]$headers['content-length'],[ref]$size) -or $size -lt 1 -or $size -gt 65536) { throw 'Invalid pairing report size' }
                $bytes=[byte[]]::new($size);$read=0
                while($read -lt $size){$count=$tls.Read($bytes,$read,$size-$read);if($count -le 0){throw 'Incomplete report'};$read+=$count}
                $data=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
                if ($data.ssh_user -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $data.host_key -notmatch '^ssh-ed25519 ([A-Za-z0-9+/=]+)( [^\r\n]*)?$' -or
                    $data.report.os.ID -ne 'steamos' -or $data.report.os.VARIANT_ID -ne 'steamdeck' -or $data.cloud_status_user_confirmed -ne $true) { throw 'Unsupported Deck report' }
                $keyBytes=[Convert]::FromBase64String($Matches[1])
                if($keyBytes.Length -ne 51){throw 'Invalid ED25519 host key'}
                $hostKey=([string]$data.host_key).Split(' ')[0..1] -join ' '
                $sshPort=22
                if($null -ne $data.ssh_port -and (-not [int]::TryParse([string]$data.ssh_port,[ref]$sshPort) -or $sshPort -lt 1024 -or $sshPort -gt 65535)){throw 'Invalid private connection port'}
                $knownHost=if($sshPort -eq 22){$peer}else{'['+$peer+']:'+$sshPort}
                $token=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
                [IO.File]::WriteAllText((Join-Path $Root 'known_hosts'), "$knownHost $hostKey`n", [Text.UTF8Encoding]::new($false))
                Write-BridgeJson 'connection.json' @{host=$peer;port=$sshPort;user=[string]$data.ssh_user;mode='private-ssh';clientToken=$token;pcAddress=$client.Client.LocalEndPoint.Address.ToString()}
                $pairUntil=[DateTime]::MinValue
                Reply-BridgeJson $tls 200 @{ok=$true;client_token=$token};continue
            }
            Reply-BridgeJson $tls 404 @{ok=$false}
        } catch {
            Write-BridgeJson 'bridge-last-error.json' @{error=$_.Exception.Message;time=[DateTime]::UtcNow.ToString('o')}
            $message=if($clientAuth -and $path -eq '/mods-info'){$_.Exception.Message}else{'Pairing request failed. Refresh DST and try again.'}
            if($tls){try{Reply-BridgeJson $tls 400 @{ok=$false;error=$message}}catch{}}
        }
        finally {if($tls){$tls.Dispose()};$client.Dispose()}
    }
} catch { Write-BridgeJson 'bridge-status.json' @{ok=$false;error=$_.Exception.Message;pid=$PID} }
finally {
    if($listener){$listener.Stop()};if($certificate){$certificate.Dispose()};if($rsa){$rsa.Dispose()}
    if(Get-Command Remove-NetFirewallRule -ErrorAction SilentlyContinue){Remove-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue}
}
