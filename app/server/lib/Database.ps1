# Database lib — SQL editor backing for the Database page.
# Reuses Find-V6DbPod and Invoke-V6Ssh from app/lib/Db-Postgres.ps1
# (loaded by Characters.ps1 earlier in alphabetical order).
#
# Read-only mode wraps the user SQL in a READ ONLY transaction so accidental
# INSERT/UPDATE/DELETE/DDL get rejected by Postgres itself.

# Default max rows to ship back over HTTP. Bigger result sets get truncated
# server-side to keep responses snappy and bounded.
$script:DuneDbMaxRows = 1000

function Get-DuneDbContext {
    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='SSH helper unavailable (Db-Postgres.ps1 not loaded).' }
    }
    if (-not (Get-Command Get-DuneVmStatus -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='VM status helper unavailable.' }
    }
    $vm = Get-DuneVmStatus
    if (-not $vm.exists)  { return @{ ok=$false; status=503; message='VM does not exist on this host.' } }
    if (-not $vm.running) { return @{ ok=$false; status=503; message='VM is not running. Start the battlegroup first.' } }
    if (-not $vm.ip)      { return @{ ok=$false; status=503; message='VM has no IP yet — wait for it to finish booting.' } }
    return @{ ok=$true; ip=$vm.ip; vm=$vm }
}

# -----------------------------------------------------------------------------
# Build the psql command. Use `psql -X --csv -A` so we get CSV with headers
# for SELECTs and command tags ("UPDATE 5") for DML. -X skips .psqlrc, -A
# disables alignment (irrelevant for CSV but defensive).
# -----------------------------------------------------------------------------
function Invoke-DuneSqlRaw {
    param(
        [string]$Ip,
        [string]$Sql,
        [int]$TimeoutSec = 30,
        [switch]$Csv
    )
    $pod = Find-V6DbPod -Ip $Ip
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
    $flags = if ($Csv) { '-X --csv' } else { '-X -A' }
    $cmd = "echo $b64 | base64 -d | sudo kubectl exec -i -n $($pod.ns) $($pod.name) -- psql -U dune -d dune -p 15432 -v ON_ERROR_STOP=1 $flags 2>&1"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec $TimeoutSec
    return ($out -join "`n")
}

# -----------------------------------------------------------------------------
# Wrap user SQL with a READ ONLY transaction. Postgres rejects writes inside
# READ ONLY — no client-side parsing or string filtering needed.
# -----------------------------------------------------------------------------
function Wrap-DuneReadOnlySql {
    param([string]$Sql)
    $trimmed = $Sql.TrimEnd()
    if ($trimmed.EndsWith(';')) { $trimmed = $trimmed.Substring(0, $trimmed.Length - 1) }
    return "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;`n$trimmed;`nROLLBACK;"
}

# -----------------------------------------------------------------------------
# Detect psql error output. psql with -v ON_ERROR_STOP=1 emits messages like:
#   ERROR:  syntax error at or near "..."
#   ERROR:  cannot execute UPDATE in a read-only transaction
# Lowest-effort detection is the literal "ERROR:" prefix on any line.
# -----------------------------------------------------------------------------
function Test-DunePsqlError {
    param([string]$Output)
    if (-not $Output) { return $false }
    return ($Output -match '(?m)^(ERROR|FATAL|PANIC):')
}

function Get-DunePsqlErrorMessage {
    param([string]$Output)
    $matches = [regex]::Matches($Output, '(?m)^(?:ERROR|FATAL|PANIC):\s*(.+)$')
    if ($matches.Count -gt 0) {
        return ($matches | ForEach-Object { $_.Groups[1].Value }) -join '; '
    }
    return $Output.Trim()
}

# -----------------------------------------------------------------------------
# CSV parser — uses PowerShell's built-in ConvertFrom-Csv. Returns:
#   { columns: [...], rows: [[...], [...]], rowCount: N, truncated: bool }
# Returns empty columns/rows for command-tag-only output ("UPDATE 5").
# -----------------------------------------------------------------------------
function ConvertFrom-DunePsqlCsv {
    param([string]$Output, [int]$MaxRows)
    if (-not $Output) {
        return @{ columns = @(); rows = @(); rowCount = 0; truncated = $false; message = '' }
    }
    $lines = ($Output -split "`r?`n")
    # Strip transaction wrappers if present (BEGIN/ROLLBACK psql tags)
    $filtered = $lines | Where-Object {
        $_ -notmatch '^(BEGIN|COMMIT|ROLLBACK|SET|SAVEPOINT|RELEASE)$' -and $_ -ne ''
    }
    # If no lines, nothing to parse
    if (-not $filtered) {
        return @{ columns = @(); rows = @(); rowCount = 0; truncated = $false; message = '' }
    }
    # Command-tag-only outputs: "UPDATE 5", "INSERT 0 3", "DELETE 12", "CREATE TABLE"
    # These have no commas in the trivial case and look like a single word + numbers.
    # Heuristic: if the *first* filtered line doesn't contain a comma AND matches a
    # known command-tag prefix, treat the whole thing as a message.
    $first = ($filtered | Select-Object -First 1)
    if ($filtered.Count -eq 1 -and $first -notmatch ',' -and $first -match '^(INSERT|UPDATE|DELETE|SELECT|MERGE|CREATE|DROP|ALTER|TRUNCATE|GRANT|REVOKE|COPY|VACUUM|ANALYZE)\b') {
        return @{ columns = @(); rows = @(); rowCount = 0; truncated = $false; message = $first }
    }
    # CSV path — try to parse using PowerShell's CSV reader
    try {
        $csvText = ($filtered -join "`n")
        $parsed = $csvText | ConvertFrom-Csv
        if (-not $parsed) {
            return @{ columns = @(); rows = @(); rowCount = 0; truncated = $false; message = '' }
        }
        # Force to array (single-row results come back as a single PSCustomObject)
        $parsedArr = @($parsed)
        $cols = @($parsedArr[0].PSObject.Properties.Name)
        $truncated = $false
        if ($parsedArr.Count -gt $MaxRows) {
            $parsedArr = $parsedArr[0..($MaxRows - 1)]
            $truncated = $true
        }
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($obj in $parsedArr) {
            $row = New-Object object[] $cols.Count
            for ($i = 0; $i -lt $cols.Count; $i++) {
                $row[$i] = $obj.($cols[$i])
            }
            [void]$rows.Add($row)
        }
        return @{
            columns   = $cols
            rows      = $rows.ToArray()
            rowCount  = $parsedArr.Count
            truncated = $truncated
            message   = ''
        }
    } catch {
        return @{
            columns   = @()
            rows      = @()
            rowCount  = 0
            truncated = $false
            message   = "Parse error: $($_.Exception.Message)"
        }
    }
}

# -----------------------------------------------------------------------------
# Top-level: run SQL. Returns a HTTP-friendly hashtable.
# -----------------------------------------------------------------------------
function Invoke-DuneSqlQuery {
    param(
        [string]$Ip,
        [string]$Sql,
        [bool]$ReadOnly = $true,
        [int]$MaxRows = 0,
        [int]$TimeoutSec = 30
    )
    if (-not $Sql -or -not $Sql.Trim()) {
        return @{ ok = $false; error = 'Empty SQL.' }
    }
    if ($MaxRows -le 0) { $MaxRows = $script:DuneDbMaxRows }

    $effective = if ($ReadOnly) { Wrap-DuneReadOnlySql -Sql $Sql } else { $Sql }
    $start = [DateTime]::UtcNow
    $raw = Invoke-DuneSqlRaw -Ip $Ip -Sql $effective -TimeoutSec $TimeoutSec -Csv
    $durationMs = [int](([DateTime]::UtcNow - $start).TotalMilliseconds)

    if (Test-DunePsqlError -Output $raw) {
        return @{
            ok         = $false
            error      = Get-DunePsqlErrorMessage -Output $raw
            raw        = $raw
            durationMs = $durationMs
            readOnly   = $ReadOnly
        }
    }

    $parsed = ConvertFrom-DunePsqlCsv -Output $raw -MaxRows $MaxRows
    return @{
        ok         = $true
        columns    = $parsed.columns
        rows       = $parsed.rows
        rowCount   = $parsed.rowCount
        truncated  = $parsed.truncated
        message    = $parsed.message
        durationMs = $durationMs
        readOnly   = $ReadOnly
        maxRows    = $MaxRows
    }
}

# -----------------------------------------------------------------------------
# Quick DB info — version, current_database, simple table list. Used by the
# editor sidebar.
# -----------------------------------------------------------------------------
function Get-DuneDbInfo {
    param([string]$Ip)
    $sql = @'
SELECT 'version'  AS k, version() AS v
UNION ALL SELECT 'database',     current_database()
UNION ALL SELECT 'user',         current_user
UNION ALL SELECT 'now',          now()::text;
'@
    $raw = Invoke-DuneSqlRaw -Ip $Ip -Sql $sql -Csv -TimeoutSec 15
    $info = @{ version = ''; database = ''; user = ''; now = '' }
    if (-not (Test-DunePsqlError -Output $raw)) {
        $parsed = ConvertFrom-DunePsqlCsv -Output $raw -MaxRows 100
        foreach ($row in $parsed.rows) {
            if ($row.Length -ge 2) {
                $info[[string]$row[0]] = [string]$row[1]
            }
        }
    }

    # Table list (top 200, alphabetical)
    $tableSql = @"
SELECT n.nspname AS schema, c.relname AS name, c.relkind AS kind
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r','v','m','f','p')
   AND n.nspname NOT IN ('pg_catalog','information_schema')
 ORDER BY n.nspname, c.relname
 LIMIT 200;
"@
    $tablesRaw = Invoke-DuneSqlRaw -Ip $Ip -Sql $tableSql -Csv -TimeoutSec 15
    $tables = @()
    if (-not (Test-DunePsqlError -Output $tablesRaw)) {
        $tParsed = ConvertFrom-DunePsqlCsv -Output $tablesRaw -MaxRows 200
        $tables = @($tParsed.rows | ForEach-Object {
            @{ schema = $_[0]; name = $_[1]; kind = $_[2] }
        })
    }

    return @{
        version  = $info.version
        database = $info.database
        user     = $info.user
        now      = $info.now
        tables   = $tables
    }
}
