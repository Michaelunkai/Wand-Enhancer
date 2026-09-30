$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Self-locating defaults: the script lives in <repo>/scripts, so it builds
# whatever checkout it ships with. Override any of these from the environment.
$RepoDir = if ($env:WAND_ENHANCER_REPO) { $env:WAND_ENHANCER_REPO } else { Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$InstallDir = if ($env:WAND_ENHANCER_INSTALL_DIR) { $env:WAND_ENHANCER_INSTALL_DIR } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WandEnhancer' }
$Owner = if ($env:WAND_ENHANCER_UPSTREAM_OWNER) { $env:WAND_ENHANCER_UPSTREAM_OWNER } else { 'k1tbyte' }
$Repo = if ($env:WAND_ENHANCER_UPSTREAM_REPO) { $env:WAND_ENHANCER_UPSTREAM_REPO } else { 'Wand-Enhancer' }
$RepoUrl = "https://github.com/$Owner/$Repo.git"
$ApiBase = "https://api.github.com/repos/$Owner/$Repo"
$FallbackBranch = 'master'
$DefaultBranch = $FallbackBranch
$SquirrelRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Wand'

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
}

# Force-close any running client/enhancer processes first so nothing locks the
# stub swap or the asar during patch (same behavior as `skill wand wemod`).
Get-Process wand,WeMod,WandEnhancer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements
    Refresh-Path
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements
    Refresh-Path
}

# Ask GitHub what the very latest release is right now (falls back to newest commit).
# When run from this fork's checkout, the fetched tag/branch is used only to
# fast-forward the local master — the build always compiles this checkout.
$ReleaseTag = $null
$DefaultBranch = $FallbackBranch
try {
    $repoInfo = Invoke-RestMethod -Uri $ApiBase -TimeoutSec 30
    if ($repoInfo.default_branch) { $DefaultBranch = $repoInfo.default_branch }
    try {
        $latest = Invoke-RestMethod -Uri "$ApiBase/releases/latest" -TimeoutSec 30
        if ($latest.tag_name) { $ReleaseTag = $latest.tag_name }
    } catch { $ReleaseTag = $null }
} catch { $ReleaseTag = $null }
Write-Output "Upstream latest: tag=$ReleaseTag branch=$DefaultBranch"

# pnpm version pinned by the repo itself when possible, so future lockfiles keep working.
$PnpmVersion = '10.17.0'
try {
    $pkgRaw = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$Owner/$Repo/$DefaultBranch/web-panel/package.json" -TimeoutSec 30
    if ($pkgRaw.packageManager -match 'pnpm@([\d.]+)') { $PnpmVersion = $Matches[1] }
} catch { }

try {
    corepack enable 2>$null
    corepack prepare "pnpm@$PnpmVersion" --activate
} catch {
    npm install -g "pnpm@$PnpmVersion" --allow-scripts=pnpm 2>$null
    Refresh-Path
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements
}
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath
if ([string]::IsNullOrWhiteSpace($vsPath)) {
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements --override "--quiet --add Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools"
    $vsPath = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath
}
if ([string]::IsNullOrWhiteSpace($vsPath)) { throw 'Visual Studio Build Tools (MSBuild) not found and could not be installed.' }

function Test-VSManagedDesktopWorkload {
    param([string]$VsWhere, [string]$InstallationPath)
    if ([string]::IsNullOrWhiteSpace($InstallationPath) -or -not (Test-Path -LiteralPath $VsWhere)) { return $false }
    foreach ($id in @('Microsoft.VisualStudio.Component.ManagedDesktop.BuildTools','Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools')) {
        $probe = & $VsWhere -latest -products '*' -requires $id -property installationPath
        if (-not [string]::IsNullOrWhiteSpace($probe)) { return $true }
    }
    return $false
}

# VS Installer has NO --wait flag (passing it exits 87 "Option 'wait' is unknown").
# Probe first; only modify when the workload is genuinely missing; wait on the
# installer process ourselves instead.
$vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
if (-not (Test-VSManagedDesktopWorkload -VsWhere $vswhere -InstallationPath $vsPath) -and (Test-Path -LiteralPath $vsInstaller)) {
    Write-Output 'VS ManagedDesktop BuildTools workload missing - installing via VS Installer (no --wait)...'
    $proc = Start-Process -FilePath $vsInstaller -ArgumentList @(
        'modify', '--installPath', "`"$vsPath`"",
        '--add', 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools',
        '--quiet', '--norestart', '--nocache'
    ) -PassThru
    [void]$proc.WaitForExit(30 * 60 * 1000)
    if (-not (Test-VSManagedDesktopWorkload -VsWhere $vswhere -InstallationPath $vsPath)) {
        Write-Warning 'VS ManagedDesktop BuildTools workload still not detected after installer run; continuing (build step will verify).'
    } else {
        Write-Output 'VS ManagedDesktop BuildTools workload installed.'
    }
} else {
    Write-Output 'VS ManagedDesktop BuildTools workload already present - installer skipped.'
}

$fwDir = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8"
$fwDir81 = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8.1"
if (-not (Test-Path "$fwDir\RedistList\FrameworkList.xml")) {
    $nuget = Join-Path ([IO.Path]::GetTempPath()) 'nuget.exe'
    if (-not (Test-Path $nuget)) { (New-Object System.Net.WebClient).DownloadFile('https://dist.nuget.org/win-x86-commandline/latest/nuget.exe', $nuget) }
    $refAsmTmp = Join-Path ([IO.Path]::GetTempPath()) 'refasm-tmp'
    & $nuget install Microsoft.NETFramework.ReferenceAssemblies.net48 -OutputDirectory $refAsmTmp -NonInteractive | Out-Null
    $pkg = Get-ChildItem "$refAsmTmp\Microsoft.NETFramework.ReferenceAssemblies.net48*" -Directory | Select-Object -First 1 -ExpandProperty FullName
    robocopy "$pkg\build\.NETFramework\v4.8" "$fwDir" /MIR /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
    Remove-Item $refAsmTmp -Recurse -Force -ErrorAction SilentlyContinue
}
Copy-Item "$fwDir81\Facades\*.dll" "$fwDir81\" -Force -ErrorAction SilentlyContinue
Copy-Item "$fwDir\Facades\*.dll" "$fwDir\" -Force -ErrorAction SilentlyContinue

if (-not (Test-Path "$RepoDir\.git")) {
    if ($ReleaseTag) {
        git clone --branch $ReleaseTag --depth 1 $RepoUrl $RepoDir
    } else {
        git clone --branch $DefaultBranch --depth 1 $RepoUrl $RepoDir
    }
    git -C $RepoDir fetch --all --prune --tags
} else {
    git -C $RepoDir fetch --all --prune --tags
    # Never destroy the checkout this script ships with: fast-forward local
    # master toward the newest upstream tag/branch, but keep every local
    # commit (e.g. the reducer-idempotency fix) intact. A dirty tree is left
    # alone for the caller to inspect.
    $treeClean = [string]::IsNullOrWhiteSpace((git -C $RepoDir status --porcelain))
    $localHead = (git -C $RepoDir rev-parse HEAD)
    $ffTarget = $null
    if ($ReleaseTag -and (git -C $RepoDir rev-parse -q --verify "refs/tags/$ReleaseTag")) {
        $ffTarget = "tags/$ReleaseTag"
    } elseif (git -C $RepoDir rev-parse -q --verify "origin/$DefaultBranch") {
        $ffTarget = "origin/$DefaultBranch"
    }
    if ($ffTarget -and $treeClean) {
        $targetSha = (git -C $RepoDir rev-parse $ffTarget)
        $isAncestor = $false
        git -C $RepoDir merge-base --is-ancestor $localHead $targetSha
        if ($LASTEXITCODE -eq 0) { $isAncestor = $true }
        if ($isAncestor -and ($localHead -ne $targetSha)) {
            git -C $RepoDir merge --ff-only $ffTarget
        }
    } elseif (-not $treeClean) {
        Write-Warning 'Working tree is dirty; skipping fast-forward. Local changes are kept as-is.'
    }
}
Write-Output ("Checkout: " + (git -C $RepoDir describe --tags --always))

$targetsFile = Join-Path $RepoDir 'Directory.Build.targets'
Set-Content $targetsFile '<Project>
  <ItemGroup>
    <Reference Include="netstandard">
      <HintPath>C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8.1\Facades\netstandard.dll</HintPath>
      <Private>false</Private>
    </Reference>
  </ItemGroup>
</Project>' -Encoding UTF8

$buildPs1 = Join-Path $RepoDir 'build.ps1'
$buildText = Get-Content $buildPs1 -Raw
if ($buildText -notmatch 'FrameworkPathOverride') {
    $origLine = "@('/m', `"/p:Configuration=`$Configuration`", '/p:Platform=Any CPU')"
    if ($buildText.Contains($origLine)) {
        $newLine = $origLine -replace "'/p:Platform=Any CPU'\)", "'/p:Platform=Any CPU', `"/p:FrameworkPathOverride=`$(Join-Path `${env:ProgramFiles(x86)} 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8.1')`")"
        $buildText = $buildText.Replace($origLine, $newLine)
        Set-Content $buildPs1 $buildText -Encoding UTF8
    } else {
        throw "Upstream build.ps1 changed shape and has no patch hook; manual update needed."
    }
}

# ---- Reducer-idempotency fix (kept in-tree, re-verified every run) ----
# The enhancer's setAccountReducer locator only matched pristine
# "account:<identifier>" code. Once a bundle was patched (the wrapper payload
# is present), re-running the enhancer threw "Pattern not found" and aborted.
# The guard below lives in WandEnhancer\Core\EnhancerConfig.cs in this repo;
# this block only verifies it is still there and fails loudly if an upstream
# merge ever drops it. Upstream is never modified in place by this script.
$csPath = Join-Path $RepoDir 'WandEnhancer\Core\EnhancerConfig.cs'
$csText = [IO.File]::ReadAllText($csPath)
if ($csText.IndexOf('WAND_ENHANCER_IDEMPOTENT_REDUCER', [StringComparison]::Ordinal) -lt 0) {
    throw "EnhancerConfig.cs is missing the WAND_ENHANCER_IDEMPOTENT_REDUCER guard; re-apply the reducer-idempotency fix before building."
}
Write-Output 'EnhancerConfig.cs: reducer idempotency guard present.'

$webPanelDir = Join-Path $RepoDir 'web-panel'
pnpm --dir $webPanelDir install --frozen-lockfile
pnpm --dir $webPanelDir rebuild esbuild

powershell -ExecutionPolicy Bypass -File $buildPs1

$builtExe = Join-Path $RepoDir 'WandEnhancer\bin\Release\WandEnhancer.exe'
if (-not (Test-Path $builtExe)) { throw "Build output not found: $builtExe" }

# Refuse to deploy a build that lacks the reducer fix: prove the compiled
# guard is embedded. The guard's literal "typeof account" is real compiled
# code (comments are stripped from the binary, so the marker comment is not).
$exeBytes = [IO.File]::ReadAllBytes($builtExe)
$hasFix = $false
foreach ($enc in @([Text.Encoding]::Unicode, [Text.Encoding]::UTF8)) {
    $exeText = $enc.GetString($exeBytes)
    if ($exeText.IndexOf('typeof account', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $hasFix = $true
        break
    }
}
if (-not $hasFix) { throw "Built WandEnhancer.exe is missing the reducer idempotency guard ('typeof account'); refusing to deploy." }
Write-Output 'Built WandEnhancer.exe verified to contain the reducer idempotency guard.'

Get-Process WandEnhancer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$installedExe = Join-Path $InstallDir 'WandEnhancer.exe'
Copy-Item $builtExe $installedExe -Force

# ---- Headless enhance: run the launcher AS the client stub (launch mode) ----
# TryLaunchMode only fires when the exe name matches a brand (Wand/WeMod), so
# the launcher must sit at <LocalAppData>\Wand\Wand.exe.
if (-not (Test-Path -LiteralPath $SquirrelRoot -PathType Container)) {
    throw "Wand install root not found: $SquirrelRoot"
}
# Default auto-patch config: full enhancement (Pro + no updates + F12 devtools +
# remote web panel), static fuse strategy (UI default for new patches), and
# auto re-apply after future client updates.
$enhancerConfigPath = Join-Path $SquirrelRoot 'enhancer.json'
$enhancerConfig = [ordered]@{
    PatchTypes = @(1, 2, 8, 16)   # ActivatePro, DisableUpdates, DevToolsOnF12, RemoteWebPanelPreview
    Strategy = 1                  # Static (EPatchStrategy)
    CustomScriptPaths = @()
    AutoApplyAfterUpdate = $true
}
[IO.File]::WriteAllText($enhancerConfigPath, ($enhancerConfig | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Write-Output "Auto-patch config written: $enhancerConfigPath (types=1,2,8,16 strategy=Static autoReapply=true)"

$stubPath = Join-Path $SquirrelRoot 'Wand.exe'
$stubBackup = Join-Path $SquirrelRoot 'Wand.exe.stub'
if (-not (Test-Path -LiteralPath $stubBackup -PathType Leaf)) {
    Copy-Item -LiteralPath $stubPath -Destination $stubBackup -Force
    Write-Output "Original Squirrel stub preserved: $stubBackup"
}
Copy-Item -LiteralPath $installedExe -Destination $stubPath -Force
Write-Output "Launcher deployed over client stub: $stubPath"

# Reap anything that could hold the stub/asar, then launch in launch mode.
Get-Process wand,WeMod -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Process $stubPath | Out-Null
Write-Output 'WandEnhancer launched in launch mode (auto-patch + client start)...'

Write-Output $PSCommandPath
Write-Output $installedExe
Write-Output $stubPath
