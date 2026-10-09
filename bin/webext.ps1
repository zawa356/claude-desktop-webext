# claude-desktop-webext: load several plain MV3 extensions into Claude Desktop (Windows).
#
# Claude Desktop loads exactly one unpacked extension, from
# %APPDATA%\Claude\extensions\fmkadmapgofadopljbjfkapdkoienihi, when REACT_PROFILE=1.
# This script keeps each tool's extension as a normal folder under
# %LOCALAPPDATA%\ClaudeDesktopWebExt\web-extensions\<id>\ and rebuilds that one slot
# from all of them. See docs/SPEC.md.
#
# Never modifies Claude itself (app.asar, MSIX, claude.exe) and never closes Claude.
# Windows PowerShell 5.1+. No admin rights, no downloads.
#
#   -Action diagnose   read-only report (default)
#   -Action install    add or update one extension (-Config or -Id/-Source)
#   -Action uninstall  remove one extension (-Config or -Id)
#   -Action rebuild    regenerate the slot from the installed extensions (repair)
#   -Sandbox / -FailAt are for tests only.
[CmdletBinding()]
param(
    [ValidateSet('diagnose', 'install', 'uninstall', 'rebuild')]
    [string]$Action = 'diagnose',
    [string]$Config,
    [string]$Id,
    [string]$Source,
    [string]$ClaudePath,
    [int]$Order = -1,
    [switch]$AdoptEnv,
    [switch]$TakeOver,
    [switch]$Yes,
    [string]$Sandbox,
    [string]$FailAt
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($PSVersionTable.PSVersion.Major -le 5) {
    # PowerShell 7 started from 5.1 leaks its module path; restore the system default for this run.
    $env:PSModulePath = (@([Environment]::GetEnvironmentVariable('PSModulePath', 'User'), [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')) | Where-Object { $_ }) -join ';'
}

# ---- Fixed values (changing them breaks existing installs; see docs/SPEC.md) ----
$LoaderVersion  = '0.2.0'
$Schema         = 1
$SlotId         = 'fmkadmapgofadopljbjfkapdkoienihi'
$SlotMarker     = '.claude-desktop-webext.json'
$DefaultOrder   = 100
$AllowedTopKeys = @('manifest_version', 'name', 'short_name', 'version', 'version_name', 'description', 'author', 'homepage_url', 'icons', 'minimum_chrome_version', 'browser_specific_settings', 'content_scripts', 'permissions')
$AllowedPerms   = @('storage')
$AllowedCsKeys  = @('matches', 'exclude_matches', 'include_globs', 'exclude_globs', 'css', 'js', 'run_at', 'world', 'all_frames', 'match_about_blank', 'match_origin_as_fallback')

if ($Sandbox) {
    $Roaming = Join-Path $Sandbox 'AppData\Roaming'
    $Local   = Join-Path $Sandbox 'AppData\Local'
} else {
    $Roaming = $env:APPDATA
    $Local   = $env:LOCALAPPDATA
}
$UserData  = Join-Path $Roaming 'Claude'
$ExtDir    = Join-Path $UserData 'extensions'
$Slot      = Join-Path $ExtDir $SlotId
$HomeDir   = Join-Path $Local 'ClaudeDesktopWebExt'
$Store     = Join-Path $HomeDir 'web-extensions'
$StateFile = Join-Path $HomeDir 'state.json'
$Backups   = Join-Path $HomeDir 'backups'
$LockFile  = Join-Path $HomeDir '.lock'

# ---------------------------------------------------------------- JSON helpers
# Canonical writer shared with webext.py: 2-space indent, LF, UTF-8 without BOM, trailing newline.
function ConvertTo-Plain($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}; foreach ($k in $Value.Keys) { $o[[string]$k] = ConvertTo-Plain $Value[$k] }; return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$list.Add((ConvertTo-Plain $item)) }
        return , $list.ToArray()
    }
    $o = [ordered]@{}; foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-Plain $p.Value }; $o
}
function Format-JsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder; [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ([int]$ch) {
            34 { [void]$sb.Append('\"') } 92 { [void]$sb.Append('\\') }
            8 { [void]$sb.Append('\b') } 12 { [void]$sb.Append('\f') } 10 { [void]$sb.Append('\n') }
            13 { [void]$sb.Append('\r') } 9 { [void]$sb.Append('\t') }
            default { if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) } else { [void]$sb.Append($ch) } }
        }
    }
    [void]$sb.Append('"'); $sb.ToString()
}
function Format-Json($v, [int]$Level = 0) {
    $pad = '  ' * ($Level + 1); $end = '  ' * $Level
    if ($null -eq $v) { return 'null' }
    if ($v -is [datetime]) { return Format-JsonString ($v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [string]) { return Format-JsonString $v }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return ([string]$v) }
    if ($v -is [System.Collections.IDictionary]) {
        if ($v.Count -eq 0) { return '{}' }
        $parts = foreach ($k in $v.Keys) { $pad + (Format-JsonString ([string]$k)) + ': ' + (Format-Json $v[$k] ($Level + 1)) }
        return "{`n" + ($parts -join ",`n") + "`n$end}"
    }
    $items = @($v)
    if ($items.Count -eq 0) { return '[]' }
    $parts = foreach ($i in $items) { $pad + (Format-Json $i ($Level + 1)) }
    "[`n" + ($parts -join ",`n") + "`n$end]"
}
function Read-Json([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { ConvertTo-Plain ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { $null }
}
function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (Format-Json $Value) + "`n", (New-Object Text.UTF8Encoding $false))
}
function Get-Key($Dict, [string]$Name, $Default = $null) {
    if ($null -ne $Dict -and $Dict -is [System.Collections.IDictionary] -and $Dict.Contains($Name)) { $Dict[$Name] } else { $Default }
}

# ---------------------------------------------------------------- small helpers
function Step([string]$Name) { if ($FailAt -eq $Name) { throw "intentional test failure at: $Name" } }
function Now { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Get-Sha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create(); $stream = [IO.File]::OpenRead($Path)
    try { ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
}
function Copy-Verified([string]$From, [string]$To) {
    # Copy a directory tree and verify every file by SHA-256. Recurses by name instead of slicing
    # FullName, because 8.3 short paths (C:\Users\RUNNER~1) and long paths differ in length.
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $From -Force) {
        $dest = Join-Path $To $item.Name
        if ($item.PSIsContainer) { Copy-Verified $item.FullName $dest; continue }
        Copy-Item -LiteralPath $item.FullName -Destination $dest
        if ((Get-Sha256 $dest) -ne (Get-Sha256 $item.FullName)) { throw "copy verification failed: $($item.FullName)" }
    }
}
function New-Stamp { (Get-Date).ToString('yyyyMMdd-HHmmss-fff') }

# Discovery is read-only. Never execute registry command strings or Claude itself.
function Get-ClaudePackages {
    if ($Sandbox) {
        $fake = Read-Json (Join-Path $Sandbox 'claude-package.json')
        if ($fake) { [pscustomobject]@{ Version = (Get-Key $fake 'Version'); PackageFamilyName = (Get-Key $fake 'PackageFamilyName'); InstallLocation = (Get-Key $fake 'InstallLocation') } }
        return
    }
    try { Get-AppxPackage -Name 'Claude' -ErrorAction Stop } catch { }
}
function Get-VirtualUserData($Package) {
    if (!$Package -or !$Package.PackageFamilyName) { return $null }
    Join-Path $Local "Packages\$($Package.PackageFamilyName)\LocalCache\Roaming\Claude"
}
function Find-ClaudeExecutables([string]$Path) {
    if (!$Path) { return }
    $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ([IO.Path]::GetFileName($Path) -ieq 'claude.exe') { (Get-Item -LiteralPath $Path).FullName }
        return
    }
    if (!(Test-Path -LiteralPath $Path -PathType Container)) { return }
    foreach ($rel in @('claude.exe', 'app\claude.exe', 'current\claude.exe')) {
        $exe = Join-Path $Path $rel
        if (Test-Path -LiteralPath $exe -PathType Leaf) { (Get-Item -LiteralPath $exe).FullName }
    }
    # Squirrel-style installations keep versioned app-* directories.
    foreach ($d in Get-ChildItem -LiteralPath $Path -Directory -Filter 'app-*' -ErrorAction SilentlyContinue) {
        $exe = Join-Path $d.FullName 'claude.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) { (Get-Item -LiteralPath $exe).FullName }
    }
}
function Get-ClaudeInstallations($Packages) {
    $found = New-Object System.Collections.ArrayList
    $add = { param($Path, $Kind, $Version, $Running)
        foreach ($exe in Find-ClaudeExecutables $Path) {
            $existing = @($found | Where-Object { $_.Path -ieq $exe })
            if ($existing.Count) { if ($Running) { $existing[0].Running = $true }; continue }
            $v = $Version
            if (!$v) { $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
            [void]$found.Add([pscustomobject]@{ Path = $exe; Kind = $Kind; Version = $v; Running = [bool]$Running })
        }
    }
    if ($ClaudePath) {
        & $add $ClaudePath 'explicit' $null $false
        return $found.ToArray()
    }
    foreach ($pkg in $Packages) { & $add $pkg.InstallLocation 'MSIX' $pkg.Version $false }
    if ($Sandbox) {
        $fixtures = Read-Json (Join-Path $Sandbox 'claude-installations.json')
        foreach ($f in $fixtures) {
            if ($f) { & $add (Get-Key $f 'Path') (Get-Key $f 'Kind' 'classic') (Get-Key $f 'Version') (Get-Key $f 'Running' $false) }
        }
    } else {
        foreach ($proc in Get-Process -Name 'claude' -ErrorAction SilentlyContinue) {
            try { & $add $proc.Path 'running executable' $null $true } catch { }
        }
        $roots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($entry in Get-ItemProperty $roots -ErrorAction SilentlyContinue) {
            if (!$entry.PSObject.Properties['DisplayName'] -or $entry.DisplayName -notmatch '^Claude(?:\s|$)') { continue }
            if ($entry.PSObject.Properties['InstallLocation']) { & $add $entry.InstallLocation 'classic registry' $null $false }
            if ($entry.PSObject.Properties['DisplayIcon']) {
                $icon = [string]$entry.DisplayIcon
                if ($icon -match '^"([^"]+\.exe)"(?:,\s*-?\d+)?$') { $icon = $Matches[1] }
                else { $icon = $icon -replace ',\s*-?\d+$', '' }
                & $add $icon 'classic registry' $null $false
            }
        }
        foreach ($base in @((Join-Path $Local 'AnthropicClaude'), (Join-Path $Local 'Programs\Claude'),
            (Join-Path $env:ProgramFiles 'Claude'), (Join-Path $env:ProgramFiles 'Anthropic\Claude'))) {
            & $add $base 'standard location' $null $false
        }
    }
    $found.ToArray()
}

# REACT_PROFILE: raw registry value (not expanded). The sandbox uses env-<Scope>.json files.
function Get-ReactProfile([string]$Scope) {
    if ($Sandbox) { return Read-Json (Join-Path $Sandbox "env-$Scope.json") }
    $path = if ($Scope -eq 'User') { 'HKCU:\Environment' } else { 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
    $key = Get-Item -LiteralPath $path
    if ($key.GetValueNames() -notcontains 'REACT_PROFILE') { return $null }
    [ordered]@{ Value = [string]$key.GetValue('REACT_PROFILE', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = $key.GetValueKind('REACT_PROFILE').ToString() }
}
function Set-UserReactProfile([bool]$On) {
    if ($Sandbox) {
        $file = Join-Path $Sandbox 'env-User.json'
        if ($On) { Write-Json $file ([ordered]@{ Value = '1'; Kind = 'String' }) } else { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
        return
    }
    if ($On) { [Environment]::SetEnvironmentVariable('REACT_PROFILE', '1', 'User') } else { [Environment]::SetEnvironmentVariable('REACT_PROFILE', $null, 'User') }
}

# ---------------------------------------------------------------- state and config
function Read-State {
    $s = Read-Json $StateFile
    if (!$s) { $s = [ordered]@{ schema = $Schema; generation = 0; envSetByUs = $false; extensions = [ordered]@{} } }
    if ([int](Get-Key $s 'schema' 0) -gt $Schema) { throw "state.json was written by a newer claude-desktop-webext (schema $(Get-Key $s 'schema')). Update this tool." }
    if (!(Get-Key $s 'extensions')) { $s['extensions'] = [ordered]@{} }
    $s
}
function Save-State($State) {
    New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null
    Write-Json $StateFile $State
}
function Resolve-Request {
    # Merge -Config (desktop-webext.json) with explicit parameters.
    $r = [ordered]@{ id = $Id; source = $Source; order = $Order; displayName = $null; tested = @(); adoptMarkers = @(); adoptNames = @() }
    if ($Config) {
        $c = Read-Json $Config
        if (!$c) { throw "cannot read config: $Config" }
        $base = Split-Path -Parent (Resolve-Path -LiteralPath $Config).ProviderPath
        if (!$r.id) { $r.id = Get-Key $c 'id' }
        $src = Get-Key $c 'source'
        if (!$r.source -and $src) { $r.source = if ([IO.Path]::IsPathRooted($src)) { $src } else { Join-Path $base $src } }
        if ($r.order -lt 0 -and $null -ne (Get-Key $c 'order')) { $r.order = [int](Get-Key $c 'order') }
        $r.displayName = Get-Key $c 'displayName'
        $tested = Get-Key $c 'testedClaudeVersions'
        if ($tested) { $r.tested = @(Get-Key $tested 'windows' @()) }
        $adopt = Get-Key $c 'adopt'
        if ($adopt) { $r.adoptMarkers = @(Get-Key $adopt 'markers' @()); $r.adoptNames = @(Get-Key $adopt 'manifestNames' @()) }
    }
    if ($r.id -and $r.id -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') { throw "invalid extension id: $($r.id)" }
    if (!$r.displayName) { $r.displayName = $r.id }
    $r
}

# ---------------------------------------------------------------- validation and merge
function Test-RelPath([string]$p) {
    if (!$p -or $p.Contains('\') -or $p.StartsWith('/') -or $p -match '^[A-Za-z]:' -or $p.Contains('?') -or $p.Contains('#')) { return $false }
    -not (@($p.Split('/')) | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' })
}
# Returns @{ ok; reason; manifest; scripts; permissions; version }
function Test-Extension([string]$Dir, [string]$ExtId) {
    $fail = { param($why) [ordered]@{ ok = $false; reason = $why } }
    $m = Read-Json (Join-Path $Dir 'manifest.json')
    if (!$m -or $m -isnot [System.Collections.IDictionary]) { return & $fail 'manifest.json missing or not valid JSON' }
    if ((Get-Key $m 'manifest_version') -ne 3) { return & $fail 'manifest_version must be 3' }
    foreach ($k in $m.Keys) { if ($AllowedTopKeys -notcontains $k) { return & $fail "unsupported manifest key: $k" } }
    $name = Get-Key $m 'name'
    if ($name -isnot [string] -or $name -like '*__MSG_*') { return & $fail 'name must be a plain string (no __MSG_ placeholders)' }
    $perms = @(Get-Key $m 'permissions' @())
    foreach ($p in $perms) { if ($AllowedPerms -notcontains $p) { return & $fail "unsupported permission: $p" } }
    $cs = @(Get-Key $m 'content_scripts' @())
    if ($cs.Count -eq 0) { return & $fail 'no content_scripts' }
    $out = New-Object System.Collections.ArrayList
    foreach ($entry in $cs) {
        if ($entry -isnot [System.Collections.IDictionary]) { return & $fail 'content_scripts entry is not an object' }
        $copy = [ordered]@{}
        foreach ($k in $entry.Keys) {
            if ($AllowedCsKeys -notcontains $k) { return & $fail "unsupported content_scripts key: $k" }
            $v = $entry[$k]
            if ($k -eq 'js' -or $k -eq 'css') {
                $paths = New-Object System.Collections.ArrayList
                foreach ($p in @($v)) {
                    if ($p -isnot [string] -or !(Test-RelPath $p)) { return & $fail "invalid $k path: $p" }
                    if (!(Test-Path -LiteralPath (Join-Path $Dir ($p -replace '/', '\')) -PathType Leaf)) { return & $fail "missing file: $p" }
                    [void]$paths.Add("ext/$ExtId/$p")
                }
                $v = $paths.ToArray()
            } elseif ($k -eq 'matches') {
                if (@($v).Count -eq 0) { return & $fail 'content_scripts.matches is empty' }
                $v = @($v)
            } elseif ($k -eq 'world' -and @('MAIN', 'ISOLATED') -notcontains $v) { return & $fail "invalid world: $v" }
            elseif ($k -eq 'run_at' -and @('document_start', 'document_end', 'document_idle') -notcontains $v) { return & $fail "invalid run_at: $v" }
            $copy[$k] = $v
        }
        if (!$copy.Contains('matches')) { return & $fail 'content_scripts entry without matches' }
        if (!$copy.Contains('js') -and !$copy.Contains('css')) { return & $fail 'content_scripts entry without js/css' }
        [void]$out.Add($copy)
    }
    [ordered]@{ ok = $true; reason = $null; version = [string](Get-Key $m 'version' ''); name = $name; scripts = $out.ToArray(); permissions = $perms }
}

# Build the merged manifest + marker for the extensions currently in the store.
function Get-Plan($State, [int]$Generation) {
    $entries = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Store) {
        foreach ($d in Get-ChildItem -LiteralPath $Store -Directory | Where-Object { $_.Name -notlike '.*' }) {
            $meta = Get-Key $State.extensions $d.Name
            $order = [int](Get-Key $meta 'order' $DefaultOrder)
            if ($d.Name -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') { [void]$skipped.Add([ordered]@{ id = $d.Name; reason = 'invalid folder name' }); continue }
            $t = Test-Extension $d.FullName $d.Name
            if ($t.ok) { [void]$entries.Add([pscustomobject]@{ id = $d.Name; order = $order; dir = $d.FullName; test = $t }) }
            else { [void]$skipped.Add([ordered]@{ id = $d.Name; reason = $t.reason }) }
        }
    }
    # Ordinal sort by (order, id) so PowerShell and Python agree.
    $sorted = $entries.ToArray()
    [Array]::Sort($sorted, [Comparison[object]]{ param($a, $b) $c = ([int]$a.order).CompareTo([int]$b.order); if ($c -ne 0) { $c } else { [string]::CompareOrdinal($a.id, $b.id) } })
    $skippedArr = $skipped.ToArray()
    [Array]::Sort($skippedArr, [Comparison[object]]{ param($a, $b) [string]::CompareOrdinal($a.id, $b.id) })
    $perms = New-Object System.Collections.Generic.SortedSet[string] ([StringComparer]::Ordinal)
    $scripts = New-Object System.Collections.ArrayList
    foreach ($e in $sorted) {
        foreach ($p in $e.test.permissions) { [void]$perms.Add($p) }
        foreach ($s in $e.test.scripts) { [void]$scripts.Add($s) }
    }
    $ids = @($sorted | ForEach-Object { $_.id })
    $manifest = [ordered]@{
        manifest_version = 3
        name             = 'Claude Desktop WebExt'
        version          = ('1.{0}.{1}' -f [math]::Floor($Generation / 65535), ($Generation % 65535))
        description      = 'Generated by claude-desktop-webext. Do not edit. Extensions: ' + ($ids -join ', ')
    }
    if ($perms.Count -gt 0) { $manifest['permissions'] = @($perms) }
    $manifest['content_scripts'] = $scripts.ToArray()
    $marker = [ordered]@{
        schema        = $Schema
        tool          = 'claude-desktop-webext'
        loaderVersion = $LoaderVersion
        generation    = $Generation
        generatedAt   = (Now)
        extensions    = @($sorted | ForEach-Object { [ordered]@{ id = $_.id; version = $_.test.version; order = $_.order } })
        skipped       = $skippedArr
    }
    [pscustomobject]@{ entries = $sorted; skipped = $skippedArr; manifest = $manifest; marker = $marker }
}

# ---------------------------------------------------------------- slot ownership
# none | ours | adoptable | react-devtools | unknown
function Get-SlotOwner([string]$Path, $Request) {
    if (!(Test-Path -LiteralPath $Path)) { return 'none' }
    $marker = Read-Json (Join-Path $Path $SlotMarker)
    if ($marker -and (Get-Key $marker 'tool') -eq 'claude-desktop-webext') { return 'ours' }
    if ($Request) {
        foreach ($f in $Request.adoptMarkers) { if ($f -and (Test-Path -LiteralPath (Join-Path $Path $f))) { return 'adoptable' } }
    }
    $name = Get-Key (Read-Json (Join-Path $Path 'manifest.json')) 'name'
    if ($Request -and $name -and ($Request.adoptNames -contains $name)) { return 'adoptable' }
    if ($name -is [string] -and $name -match 'React Developer Tools') { return 'react-devtools' }
    'unknown'
}

# ---------------------------------------------------------------- findings
function Get-Findings($Request, [string]$Mode) {
    $list = New-Object System.Collections.ArrayList
    $add = { param($Level, $Item, $Detail) [void]$list.Add([pscustomobject]@{ Level = $Level; Item = $Item; Detail = $Detail }) }
    & $add 'INFO' 'Loader' "claude-desktop-webext $LoaderVersion, PowerShell $($PSVersionTable.PSVersion)"

    $packages = @(Get-ClaudePackages)
    $installs = @(Get-ClaudeInstallations $packages)
    foreach ($candidate in $installs) {
        & $add 'INFO' 'Claude candidate' "$($candidate.Kind): $($candidate.Path) (version $($candidate.Version), running=$($candidate.Running))"
    }
    $runningInstalls = @($installs | Where-Object { $_.Running })
    $selected = $null
    if ($runningInstalls.Count -eq 1) { $selected = $runningInstalls[0] }
    elseif ($installs.Count -eq 1) { $selected = $installs[0] }
    elseif ($installs.Count -gt 1) { & $add 'NG' 'Claude' 'Multiple installations found. Specify -ClaudePath with the intended claude.exe path.' }
    elseif ($ClaudePath) { & $add 'NG' 'Claude' '-ClaudePath does not identify a claude.exe file. Nothing will be changed.' }
    else { & $add 'WARN' 'Claude' 'No executable found in package, process, registry or standard locations. Use -ClaudePath to specify it; runtime compatibility is unverified.' }
    if ($selected) {
        if ($Request -and @($Request.tested).Count -gt 0 -and ($Request.tested -notcontains $selected.Version)) {
            & $add 'WARN' 'Claude version' "$($selected.Version) (not tested with $($Request.displayName))"
        }
        & $add 'INFO' 'Claude selected' $selected.Path
        & $add 'WARN' 'Runtime compatibility' 'Finding Claude does not verify its REACT_PROFILE hook. Restart and runtime verification are still required.'
    }

    $virtualDataFound = $false
    foreach ($pkg in $packages) {
        $virtualData = Get-VirtualUserData $pkg
        if (!$virtualData) { continue }
        if (Test-Path -LiteralPath $virtualData -PathType Container) {
            $virtualDataFound = $true
            & $add 'INFO' 'Claude package user data' $virtualData
        }
        $virtual = Join-Path $virtualData "extensions\$SlotId"
        if (Test-Path -LiteralPath $virtual) { & $add 'NG' 'Slot (package-virtualized)' "$virtual exists and may shadow the real slot." }
    }
    if (Test-Path -LiteralPath $UserData -PathType Container) { & $add 'OK' 'Claude user data' $UserData }
    elseif ($virtualDataFound) {
        & $add 'OK' 'Claude user data' "Package user data exists. Install will create the stable real slot under $UserData; diagnose does not create it."
    } else { & $add 'NG' 'Claude user data' "$UserData does not exist and no package user data was found. Start the intended Claude once first." }
    & $add 'INFO' 'Extension destination' $Slot

    $rawState = Read-Json $StateFile
    if ([int](Get-Key $rawState 'schema' 0) -gt $Schema) { & $add 'NG' 'Loader' "state.json was written by a newer claude-desktop-webext (schema $(Get-Key $rawState 'schema')). Update this tool."; return , $list.ToArray() }
    $slotSchema = [int](Get-Key (Read-Json (Join-Path $Slot $SlotMarker)) 'schema' 0)
    if ($slotSchema -gt $Schema) { & $add 'NG' 'Loader' "the slot was generated by a newer claude-desktop-webext (schema $slotSchema). Update this tool."; return , $list.ToArray() }
    $owner = Get-SlotOwner $Slot $Request
    switch ($owner) {
        'none'           { & $add 'OK' 'Slot' 'empty' }
        'ours'           { & $add 'OK' 'Slot' "managed by claude-desktop-webext (generation $(Get-Key (Read-Json (Join-Path $Slot $SlotMarker)) 'generation'))" }
        'adoptable'      { & $add 'OK' 'Slot' "previous standalone install of $($Request.displayName); it will be moved to backups and taken over" }
        'react-devtools' { & $add 'NG' 'Slot' 'the real React DevTools is installed there; it will not be overwritten.' }
        default {
            if ($Mode -eq 'rebuild' -and $TakeOver) { & $add 'WARN' 'Slot' 'unknown content; -TakeOver moves it to backups.' }
            else { & $add 'NG' 'Slot' "$Slot is used by another tool. Update that tool to a claude-desktop-webext based version, or remove it." }
        }
    }

    $machine = Get-ReactProfile 'Machine'; $user = Get-ReactProfile 'User'
    if ($machine) { & $add 'NG' 'REACT_PROFILE (machine)' "value '$(Get-Key $machine 'Value')'; machine-wide settings are not changed." }
    if (!$user) { & $add 'OK' 'REACT_PROFILE (user)' 'not set' }
    elseif ((Get-Key $user 'Value') -eq '1') { & $add 'OK' 'REACT_PROFILE (user)' '1' }
    else { & $add 'NG' 'REACT_PROFILE (user)' "value '$(Get-Key $user 'Value')' is used for something else; it will not be changed." }

    if (Test-Path -LiteralPath $LockFile) { & $add 'NG' 'Lock' "$LockFile exists. Another install may be running; delete it if not." }

    $state = Read-State
    $plan = Get-Plan $state ([int]$state.generation)
    foreach ($e in $plan.entries) { & $add 'INFO' "Extension $($e.id)" "$($e.test.name) $($e.test.version) (order $($e.order))" }
    foreach ($s in $plan.skipped) { & $add 'WARN' "Extension $($s.id)" "skipped: $($s.reason)" }

    if (!$Sandbox) {
        $running = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
        & $add 'INFO' 'Claude process' $(if ($running) { "running ($running). Quit Claude completely and start it again afterwards." } else { 'not running' })
    }
    , $list.ToArray()
}
function Show-Findings($Findings) {
    $colors = @{ OK = 'Green'; INFO = 'Gray'; WARN = 'Yellow'; NG = 'Red' }
    foreach ($f in $Findings) { Write-Host ('[{0,-4}] {1}: {2}' -f $f.Level, $f.Item, $f.Detail) -ForegroundColor $colors[$f.Level] }
    Write-Host ''
    @($Findings | Where-Object { $_.Level -eq 'NG' }).Count
}
function Confirm-Action([string]$Message) {
    if ($Yes) { return }
    $answer = Read-Host "$Message Continue? (Y/N)"
    if ($answer -notmatch '^[Yy]') { Write-Host 'Cancelled. Nothing was changed.'; exit 2 }
}

# ---------------------------------------------------------------- transaction
# Each change registers an undo record; on failure they run newest first.
#   move  : if From exists, move it to To
#   env   : set (On) or remove the user REACT_PROFILE
#   bytes : restore a file's previous bytes (null = delete)
$script:Undo = New-Object System.Collections.ArrayList
function Register-Undo([hashtable]$Op) { [void]$script:Undo.Insert(0, $Op) }
function Invoke-Rollback {
    $failed = $false
    foreach ($op in $script:Undo) {
        try {
            switch ($op.op) {
                'move' {
                    if (Test-Path -LiteralPath $op.From) {
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $op.To) | Out-Null
                        Move-Item -LiteralPath $op.From -Destination $op.To
                    }
                }
                'env' { Set-UserReactProfile $op.On }
                'bytes' { if ($null -ne $op.Bytes) { [IO.File]::WriteAllBytes($op.Path, $op.Bytes) } else { Remove-Item -LiteralPath $op.Path -ErrorAction SilentlyContinue } }
            }
        } catch { $failed = $true; Write-Host "rollback step failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    -not $failed
}
function Enter-Lock {
    New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null
    try { $fs = [IO.File]::Open($LockFile, 'CreateNew', 'Write') } catch { throw "another operation holds $LockFile" }
    $bytes = [Text.Encoding]::UTF8.GetBytes((Format-Json ([ordered]@{ pid = $PID; createdAt = (Now) })))
    $fs.Write($bytes, 0, $bytes.Length); $fs.Dispose()
}
function Exit-Lock { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue }

# Move the current slot away and put a freshly generated one in place (or none if empty).
function Update-Slot($State, [string]$BackupDir) {
    $gen = [int]$State.generation + 1
    $plan = Get-Plan $State $gen
    foreach ($s in $plan.skipped) { Write-Host "skipped $($s.id): $($s.reason)" -ForegroundColor Yellow }
    $hadSlot = Test-Path -LiteralPath $Slot
    if ($plan.entries.Count -gt 0) {
        $staging = Join-Path $ExtDir ".$SlotId.staging-$(New-Stamp)"
        New-Item -ItemType Directory -Force -Path $staging | Out-Null
        Register-Undo @{ op = 'move'; From = $staging; To = (Join-Path $BackupDir 'slot-failed') }
        foreach ($e in $plan.entries) { Copy-Verified $e.dir (Join-Path $staging "ext\$($e.id)") }
        Write-Json (Join-Path $staging 'manifest.json') $plan.manifest
        Write-Json (Join-Path $staging $SlotMarker) $plan.marker
    }
    Step 'slot-stage'
    if ($hadSlot) {
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        $prev = Join-Path $BackupDir 'slot-previous'
        Move-Item -LiteralPath $Slot -Destination $prev
        Register-Undo @{ op = 'move'; From = $prev; To = $Slot }
    }
    Step 'slot-swap'
    if ($plan.entries.Count -gt 0) {
        New-Item -ItemType Directory -Force -Path $ExtDir | Out-Null
        Move-Item -LiteralPath $staging -Destination $Slot
        Register-Undo @{ op = 'move'; From = $Slot; To = (Join-Path $BackupDir 'slot-failed-placed') }
    }
    $State.generation = $gen
    $plan
}

function Update-Env($State, [bool]$Wanted) {
    $user = Get-ReactProfile 'User'
    if ($Wanted) {
        if (!$user) {
            Set-UserReactProfile $true; $State.envSetByUs = $true
            Register-Undo @{ op = 'env'; On = $false }
        } elseif ($AdoptEnv) { $State.envSetByUs = $true }
    } elseif ($State.envSetByUs) {
        if ($user -and (Get-Key $user 'Value') -eq '1') {
            Set-UserReactProfile $false
            Register-Undo @{ op = 'env'; On = $true }
            Write-Host 'Removed REACT_PROFILE.'
        }
        $State.envSetByUs = $false
    }
    Step 'env'
}

function Invoke-Transaction([string]$Label, [scriptblock]$Body) {
    Enter-Lock
    $stateBefore = if (Test-Path -LiteralPath $StateFile) { [IO.File]::ReadAllBytes($StateFile) } else { $null }
    Register-Undo @{ op = 'bytes'; Path = $StateFile; Bytes = $stateBefore }
    try {
        & $Body
        Step 'state'
    } catch {
        Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Restoring the previous state...'
        $ok = Invoke-Rollback
        Exit-Lock
        if (!$ok) { Write-Host 'Manual check needed. Backups are in:' $Backups -ForegroundColor Red; exit 3 }
        Write-Host 'Restored. Nothing was changed.' -ForegroundColor Yellow
        exit 1
    }
    Exit-Lock
    Write-Host "$Label completed." -ForegroundColor Green
    Write-Host 'Quit Claude completely (tray icon > Quit) and start it again from the usual icon. This script never closes Claude.'
}

# ---------------------------------------------------------------- actions
function Invoke-Diagnose {
    $req = if ($Config -or $Id) { Resolve-Request } else { $null }
    $ng = Show-Findings (Get-Findings $req 'diagnose')
    if ($ng) { Write-Host "Result: $ng problem(s) found (NG above)." -ForegroundColor Yellow } else { Write-Host 'Result: no problems found.' -ForegroundColor Green }
    Write-Host 'Diagnose is read-only; nothing was changed.'
    if ($ng) { exit 1 }
}

function Invoke-Install {
    $req = Resolve-Request
    if (!$req.id -or !$req.source) { throw 'install needs -Config or -Id and -Source' }
    if (!(Test-Path -LiteralPath $req.source -PathType Container)) { throw "source folder not found: $($req.source)" }
    $check = Test-Extension $req.source $req.id
    if (!$check.ok) { Write-Host "The extension cannot be loaded this way: $($check.reason)" -ForegroundColor Red; exit 1 }
    $ng = Show-Findings (Get-Findings $req 'install')
    if ($ng) { Write-Host "Stopped because of $ng problem(s). Nothing was changed." -ForegroundColor Yellow; exit 1 }
    $target = Join-Path $Store $req.id
    $mode = if (Test-Path -LiteralPath $target) { 'Update' } else { 'Install' }
    Confirm-Action "$mode $($req.displayName) $($check.version)."

    Invoke-Transaction $mode {
        $stamp = New-Stamp; $backup = Join-Path $Backups $stamp
        $state = Read-State
        New-Item -ItemType Directory -Force -Path $Store | Out-Null
        $staging = Join-Path $Store ".$($req.id).staging-$stamp"
        Register-Undo @{ op = 'move'; From = $staging; To = (Join-Path $backup "store-failed-$($req.id)") }
        Copy-Verified $req.source $staging
        Step 'copy'
        if (Test-Path -LiteralPath $target) {
            New-Item -ItemType Directory -Force -Path $backup | Out-Null
            $prev = Join-Path $backup "store-previous-$($req.id)"
            Move-Item -LiteralPath $target -Destination $prev
            Register-Undo @{ op = 'move'; From = $prev; To = $target }
        }
        Move-Item -LiteralPath $staging -Destination $target
        Register-Undo @{ op = 'move'; From = $target; To = (Join-Path $backup "store-failed-placed-$($req.id)") }
        $old = Get-Key $state.extensions $req.id
        $order = if ($req.order -ge 0) { $req.order } else { [int](Get-Key $old 'order' $DefaultOrder) }
        $state.extensions[$req.id] = [ordered]@{
            displayName = $req.displayName; version = $check.version; order = $order
            installedAt = (Get-Key $old 'installedAt' (Now)); updatedAt = (Now)
        }
        $plan = Update-Slot $state $backup
        if (@($plan.entries | Where-Object { $_.id -eq $req.id }).Count -ne 1) { throw "$($req.id) was not accepted into the slot" }
        Update-Env $state $true
        Save-State $state
    }
}

function Invoke-Uninstall {
    $req = Resolve-Request
    if (!$req.id) { throw 'uninstall needs -Config or -Id' }
    $target = Join-Path $Store $req.id
    $state = Read-State
    if (!(Test-Path -LiteralPath $target) -and !(Get-Key $state.extensions $req.id)) { Write-Host "$($req.displayName) is not installed. Nothing was changed."; return }
    $ng = Show-Findings (Get-Findings $req 'uninstall')
    if ($ng) { Write-Host 'Uninstall stopped because of the problems above. Nothing was changed.'; exit 1 }
    $owner = Get-SlotOwner $Slot $null
    if ($owner -ne 'ours' -and $owner -ne 'none') { Write-Host "The slot is used by another tool; it will not be changed. Nothing was changed." -ForegroundColor Yellow; exit 1 }
    Confirm-Action "Uninstall $($req.displayName)."
    Invoke-Transaction 'Uninstall' {
        $backup = Join-Path $Backups (New-Stamp)
        $state = Read-State
        if (Test-Path -LiteralPath $target) {
            New-Item -ItemType Directory -Force -Path $backup | Out-Null
            $removed = Join-Path $backup "store-removed-$($req.id)"
            Move-Item -LiteralPath $target -Destination $removed
            Register-Undo @{ op = 'move'; From = $removed; To = $target }
            Write-Host "Moved the extension to $removed (not deleted)."
        }
        if ($state.extensions.Contains($req.id)) { $state.extensions.Remove($req.id) }
        $plan = Update-Slot $state $backup
        Update-Env $state ($plan.entries.Count -gt 0)
        Save-State $state
    }
}

function Invoke-Rebuild {
    $ng = Show-Findings (Get-Findings $null 'rebuild')
    if ($ng) { Write-Host "Stopped because of $ng problem(s). Nothing was changed." -ForegroundColor Yellow; exit 1 }
    Confirm-Action 'Rebuild the Claude Desktop extension slot.'
    Invoke-Transaction 'Rebuild' {
        $state = Read-State
        $plan = Update-Slot $state (Join-Path $Backups (New-Stamp))
        Update-Env $state ($plan.entries.Count -gt 0)
        Save-State $state
    }
}

switch ($Action) {
    'diagnose'  { Invoke-Diagnose }
    'install'   { Invoke-Install }
    'uninstall' { Invoke-Uninstall }
    'rebuild'   { Invoke-Rebuild }
}
