# Broadcast.ps1
# In-game broadcasts via the battlegroup's mq-game RabbitMQ pod.
#
# Mirrors the standalone `send-dune-broadcast` shell script (and dune-admin's
# rmq_commands.go) but runs over SSH from this Windows tool. Two broadcast
# kinds are supported:
#   - Generic  : pop-up Title/Body with a duration in seconds.
#   - Shutdown : server Restart/Shutdown countdown with a delay in minutes.
#
# Transport: ssh dune@<vm-ip> -> sudo kubectl exec -i -n <ns> <mq-game-pod>
# -> sh -lc 'rabbitmqctl eval "<erlang>"'. The Erlang publishes a
# ServiceBroadcast ServerCommand to the `heartbeats` exchange with routing
# key `notifications`, which the game servers forward to all connected
# players.
#
# Depends on Invoke-V6Ssh from Db-Postgres.ps1 (auto-loaded by Sietch.ps1's
# dot-source block; if not yet loaded we load it lazily below).

$script:V6MqGamePodCache     = $null
$script:V6MqGamePodCacheTime = [datetime]::MinValue

$script:DuneDbPostgresPath = $null
foreach ($candidate in @(
    (Join-Path $PSScriptRoot '..\..\lib\Db-Postgres.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) '..\lib\Db-Postgres.ps1')
)) {
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
    if ($full) { $script:DuneDbPostgresPath = $full; break }
}
if ($script:DuneDbPostgresPath -and -not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
    . $script:DuneDbPostgresPath
}

function Get-V6BroadcastContext {
    $ctx = @{ ok = $true }
    try { $vm = Get-DuneVmStatus } catch {
        return @{ ok = $false; status = 503; message = "VM status unavailable: $($_.Exception.Message)" }
    }
    if (-not $vm)         { return @{ ok = $false; status = 503; message = 'VM status unavailable.' } }
    if (-not $vm.exists)  { return @{ ok = $false; status = 503; message = 'VM does not exist on this host.' } }
    if (-not $vm.running) { return @{ ok = $false; status = 503; message = "VM state: $($vm.state) - start the VM first." } }
    if (-not $vm.ip)      { return @{ ok = $false; status = 503; message = 'VM is running but has no IP yet.' } }

    $cfg = Read-DuneConfig
    if (-not $cfg.SshKey -or -not (Test-Path -LiteralPath $cfg.SshKey)) {
        return @{ ok = $false; status = 503; message = 'SSH key not configured. Set SshKey in dune-server.config or via Settings.' }
    }
    $ctx.vm = $vm
    return $ctx
}

function Find-V6MqGamePod {
    param([string]$Ip, [switch]$Force)
    if (-not $Force -and $script:V6MqGamePodCache -and ((Get-Date) - $script:V6MqGamePodCacheTime).TotalSeconds -lt 120) {
        return $script:V6MqGamePodCache
    }
    $raw = Invoke-V6Ssh -Ip $Ip -Cmd "sudo kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep 'mq-game-sts-0.*Running'"
    $line = (($raw -join "`n") -split "`n" | Where-Object { $_ } | Select-Object -First 1)
    if (-not $line) { throw 'mq-game pod not found. Make sure the battlegroup is running.' }
    $parts = ($line.Trim() -split '\s+')
    $pod = @{ ns = $parts[0]; name = $parts[1] }
    $script:V6MqGamePodCache = $pod
    $script:V6MqGamePodCacheTime = Get-Date
    return $pod
}

# Escape a string for inclusion inside an Erlang <<"...">> binary literal.
# Erlang binaries in this context behave like Erlang strings — the only
# delimiter we need to escape is the literal double-quote and backslash.
# Newlines are passed through (Title/Body shouldn't contain them anyway).
function _Escape-V6ErlBinary {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -replace '\\', '\\\\' -replace '"', '\\"')
}

# Build the Erlang script + sh wrapper for a generic ServiceBroadcast, then
# pipe it over SSH into the mq-game pod and execute it via rabbitmqctl eval.
function Send-V6GenericBroadcast {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Body,
        [int] $DurationSec = 30
    )
    if ($DurationSec -lt 1) { $DurationSec = 1 }
    if ($DurationSec -gt 3600) { $DurationSec = 3600 }

    $ctx = Get-V6BroadcastContext
    if (-not $ctx.ok) { return $ctx }
    $ip  = $ctx.vm.ip
    $pod = Find-V6MqGamePod -Ip $ip

    $tEsc = _Escape-V6ErlBinary $Title
    $bEsc = _Escape-V6ErlBinary $Body

    $erl = @"
Title = unicode:characters_to_binary(<<"$tEsc">>, utf8),
Body = unicode:characters_to_binary(<<"$bEsc">>, utf8),
Duration = $DurationSec,
EntryEn = #{<<"Key">> => <<"en">>, <<"Title">> => Title, <<"Body">> => Body},
EntryEnUs = #{<<"Key">> => <<"en-US">>, <<"Title">> => Title, <<"Body">> => Body},
Inner = iolist_to_binary(rabbit_json:encode(#{
    <<"ServerCommand">> => <<"ServiceBroadcast">>,
    <<"BroadcastType">> => <<"Generic">>,
    <<"BroadcastPayload">> => #{
        <<"BroadcastDuration">> => Duration,
        <<"LocalizedText">> => [EntryEn, EntryEnUs]
    }
})),
Outer = iolist_to_binary(rabbit_json:encode(#{
    <<"Version">> => 2,
    <<"AuthToken">> => <<"Nu6VmPWUMvdPMeB7qErr">>,
    <<"MessageContent">> => Inner
})),
XName = rabbit_misc:r(<<"/">>, exchange, <<"heartbeats">>),
X = rabbit_exchange:lookup_or_die(XName),
MsgId = list_to_binary("manual-service-broadcast-" ++ integer_to_list(erlang:system_time(millisecond))),
P = {list_to_atom("P_basic"), <<"Content">>, undefined, [], undefined,
     undefined, undefined, undefined, undefined, MsgId, undefined,
     undefined, <<"fls">>, <<"fls_backend">>, undefined},
Content = rabbit_basic:build_content(P, Outer),
{ok, Msg} = rabbit_basic:message(XName, <<"notifications">>, Content),
rabbit_queue_type:publish_at_most_once(X, Msg).
"@

    return _Invoke-V6BroadcastErl -Ip $ip -Pod $pod -Erl $erl -Action 'broadcast'
}

function Send-V6ShutdownBroadcast {
    param(
        [string] $ShutdownType = 'Restart',
        [int] $DelayMinutes = 10,
        [int] $Frequency = 0,
        [int] $Duration = 0,
        [bool] $Cancel = $false
    )
    if ($ShutdownType -notin @('Restart','Shutdown','Maintenance','Update')) {
        return @{ ok = $false; status = 400; message = "Invalid shutdown type: $ShutdownType" }
    }
    if ($DelayMinutes -lt 0) { $DelayMinutes = 0 }

    $ctx = Get-V6BroadcastContext
    if (-not $ctx.ok) { return $ctx }
    $ip  = $ctx.vm.ip
    $pod = Find-V6MqGamePod -Ip $ip

    # Compute the absolute Unix-epoch timestamp host-side. The earlier
    # implementation shelled out to the VM (`ssh ... date -d ...`) to dodge
    # host/VM clock drift, but in practice both sides are NTP-synced and
    # the SSH round-trip turned into a real failure mode (single-quote
    # round-trip through PowerShell/ssh occasionally returned empty,
    # surfacing as "Could not compute shutdown timestamp on the VM").
    $ts = [int64]([DateTimeOffset]::UtcNow.AddMinutes($DelayMinutes).ToUnixTimeSeconds())
    if ($ts -le 0) { return @{ ok = $false; status = 500; message = 'Could not compute shutdown timestamp.' } }

    $cancelAtom = if ($Cancel) { 'true' } else { 'false' }
    $tEsc = _Escape-V6ErlBinary $ShutdownType

    $erl = @"
Inner = iolist_to_binary(rabbit_json:encode(#{
    <<"ServerCommand">> => <<"ServiceBroadcast">>,
    <<"BroadcastType">> => <<"ServerShutdown">>,
    <<"BroadcastPayload">> => #{
        <<"ShutdownType">> => <<"$tEsc">>,
        <<"ShouldCancel">> => $cancelAtom,
        <<"ShutdownTimestamp">> => $ts,
        <<"BroadcastFrequency">> => $Frequency,
        <<"ShutdownDuration">> => $Duration,
        <<"DateTimestamp">> => $ts
    }
})),
Outer = iolist_to_binary(rabbit_json:encode(#{
    <<"Version">> => 2,
    <<"AuthToken">> => <<"Nu6VmPWUMvdPMeB7qErr">>,
    <<"MessageContent">> => Inner
})),
XName = rabbit_misc:r(<<"/">>, exchange, <<"heartbeats">>),
X = rabbit_exchange:lookup_or_die(XName),
MsgId = list_to_binary("manual-shutdown-broadcast-" ++ integer_to_list(erlang:system_time(millisecond))),
P = {list_to_atom("P_basic"), <<"Content">>, undefined, [], undefined,
     undefined, undefined, undefined, undefined, MsgId, undefined,
     undefined, <<"fls">>, <<"fls_backend">>, undefined},
Content = rabbit_basic:build_content(P, Outer),
{ok, Msg} = rabbit_basic:message(XName, <<"notifications">>, Content),
rabbit_queue_type:publish_at_most_once(X, Msg).
"@

    $action = if ($Cancel) { 'cancel' } else { 'shutdown' }
    return _Invoke-V6BroadcastErl -Ip $ip -Pod $pod -Erl $erl -Action $action -Extra @{
        shutdownType = $ShutdownType
        delayMinutes = $DelayMinutes
        shutdownAt   = $ts
        cancel       = $Cancel
    }
}

# Internal: package an Erlang expression as a single base64-encoded blob,
# pipe it over SSH into the mq-game pod, and run it through `rabbitmqctl eval`.
function _Invoke-V6BroadcastErl {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] $Pod,
        [Parameter(Mandatory)] [string] $Erl,
        [string] $Action = 'broadcast',
        [hashtable] $Extra
    )
    # Strip CRs — heredoc above is CRLF-terminated when read from a CRLF .ps1.
    $clean = ($Erl -replace "`r","")
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clean))

    # The inner remote script: base64-decode the Erlang into a temp file,
    # ensure the RabbitMQ + Erlang binaries are on PATH, then run rabbitmqctl
    # eval with the script contents. PATH mirrors the upstream
    # send-dune-broadcast script.
    $remote = "set -eu; export PATH=/opt/rabbitmq/sbin:/opt/erlang/lib/erlang/bin:/opt/erlang/lib/erlang/erts-14.2.5.12/bin:/bin:/usr/bin:/usr/local/bin:`$PATH; expr=`$(cat); /opt/rabbitmq/sbin/rabbitmqctl eval `"`$expr`""
    $remoteB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))

    $sshCmd = "echo $b64 | base64 -d | sudo kubectl exec -i -n $($Pod.ns) $($Pod.name) -- sh -lc `"`$(echo $remoteB64 | base64 -d)`" 2>&1"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $sshCmd -TimeoutSec 30
    $text = (($out -join "`n")).Trim()

    # rabbitmqctl eval returns "{ok,enqueued}." or similar on success and
    # an Erlang stack trace on failure.
    $ok = ($text -match '\{ok,') -or ($text -match '^\s*ok\s*$') -or ($text -match 'enqueued')
    $result = @{
        ok      = $ok
        action  = $Action
        raw     = $text
        ns      = $Pod.ns
        pod     = $Pod.name
    }
    if (-not $ok) {
        $result.status = 500
        if ([string]::IsNullOrWhiteSpace($text)) {
            $result.message = 'No response from rabbitmqctl eval (mq-game pod may not be ready).'
        } else {
            $result.message = "rabbitmqctl eval failed: $text"
        }
    } else {
        $result.message = if ($Action -eq 'cancel') {
            'Shutdown broadcast cancelled.'
        } elseif ($Action -eq 'shutdown') {
            'Shutdown broadcast sent.'
        } else {
            'Broadcast sent.'
        }
    }
    if ($Extra) {
        foreach ($k in $Extra.Keys) { $result[$k] = $Extra[$k] }
    }
    return $result
}