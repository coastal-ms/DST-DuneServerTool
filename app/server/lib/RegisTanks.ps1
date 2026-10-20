# Native server compatibility is generated locally from the owner's game files.
# A version label alone is not enough: grants require the accepted executable
# and all three generated compatibility files on the exact player's map.
function Get-DuneRegisTankSupport {
    param([string]$Ip, [long]$ActorId = 0)
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if (-not $target.available) { return @{ enabled = $false; message = 'Server is unavailable.' } }
    $map = 'HaggaBasin'
    if ($ActorId -gt 0) {
        $lookup = Invoke-DuneSqlQuery -Ip $Ip -ReadOnly $true -MaxRows 1 -TimeoutSec 10 -Sql "SELECT a.map FROM dune.player_state ps JOIN dune.actors a ON a.id=ps.player_pawn_id WHERE ps.player_pawn_id=${ActorId}::bigint AND ps.online_status::text='Online';"
        if (-not $lookup.ok) { return @{ enabled = $false; message = 'Could not verify the online player.' } }
        $rows = ConvertTo-DuneRowMaps -Result $lookup
        if ($rows.Count -ne 1) { return @{ enabled = $false; message = 'Log into Hagga before granting a Tank.' } }
        $map = [string]$rows[0]['map']
    }
    if ($map -ne 'HaggaBasin') { return @{ enabled = $false; message = 'Regis Tanks are currently supported on Hagga.' } }
    if ($target.namespace -cnotmatch '^[a-z0-9-]+$') { throw 'Invalid battlegroup namespace.' }
    $raw = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo kubectl -n '$($target.namespace)' get pods -o json" -TimeoutSec 15) -join "`n"
    $pods = $raw | ConvertFrom-Json
    $games = @($pods.items | Where-Object { $_.metadata.name -cmatch '-sg-survival-[0-9]+-pod-[0-9]+$' -and $_.status.phase -eq 'Running' })
    if ($games.Count -ne 1) { return @{ enabled = $false; message = 'Regis Tank grants require one ready Hagga server.' } }
    $pod = $games[0]
    if (-not @($pod.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count) { return @{ enabled = $false; message = 'Hagga is not ready.' } }
    $binary = '/home/dune/server/DuneSandbox/Binaries/Linux/DuneSandboxServer-Linux-Shipping'
    $overlay = '/home/dune/server/DuneSandbox/Content/Paks/pakchunk999-DSTRegisTank-2147284-LinuxServer_P'
    $expected = @{
        $binary = '240b4bb378a93b70134fa685fc467bc2ae94fd40d81da2feea0f987758bc9126'
        "$overlay.pak" = '75e7144577253917f6da7312ef5e585b12fb728226a22b0938323751a6b555cd'
        "$overlay.ucas" = '13011a68170df5a9320782691768b0b0bd568610bc682ec1979e979de534c01e'
        "$overlay.utoc" = '12781c923dcace79204bfecaf0ff4ea49c41ec6a07e68fe81fd3feb96767ced5'
    }
    $quoted = @($expected.Keys | Sort-Object | ForEach-Object { "'$_'" }) -join ' '
    $hashes = Invoke-V6Ssh -Ip $Ip -Cmd "sudo kubectl -n '$($target.namespace)' exec '$($pod.metadata.name)' -- sha256sum $quoted" -TimeoutSec 30
    $matched = @{}
    $supportedBinaries = @{
        '240b4bb378a93b70134fa685fc467bc2ae94fd40d81da2feea0f987758bc9126' = '2147284'
        '3e8966850e911826f4e5339dea5b3830a71e037acc9b0ed400bc9f0e21e6e318' = '2156652'
    }
    $build = ''
    foreach ($line in $hashes) {
        if ("$line" -notmatch '^([a-f0-9]{64})\s+(.+)$') { continue }
        $digest = $matches[1]; $path = $matches[2]
        if ($path -ceq $binary -and $supportedBinaries.ContainsKey($digest)) { $matched[$path] = $true; $build = $supportedBinaries[$digest] }
        elseif ($path -cne $binary -and $expected.ContainsKey($path) -and $expected[$path] -ceq $digest) { $matched[$path] = $true }
    }
    if ($matched.Count -ne $expected.Count) { return @{ enabled = $false; message = 'Regis Tank compatibility is not enabled for this server build.' } }
    return @{ enabled = $true; build = $build; map = $map; message = 'Regis Tank compatibility is enabled.' }
}

function Invoke-DuneRegisTankGrant {
    param([string]$Ip, [long]$ActorId, [string]$TemplateName)
    if ($ActorId -le 0 -or $TemplateName -cnotin @('T6_CombatDart','T6_CombatFire')) { throw 'Select an online player and a Regis Tank variant.' }
    return Invoke-DuneVehicleSpawnLive -Ip $Ip -ActorId $ActorId -VehicleId 'Tank' -ActorClass '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM_C' -TemplateName $TemplateName -Persistent $true
}
