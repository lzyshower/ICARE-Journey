# Fincept Terminal Windows bootstrap script.
#
# Usage from an empty folder:
#   powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -Launch
#
# Usage from this repo root:
#   powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -Launch
#
# The script can install missing prerequisites via winget:
#   - Git for Windows
#   - Python 3.11+
#   - Visual Studio 2022 Build Tools with "Desktop development with C++"
#
# Notes:
#   - Visual Studio Build Tools installation may show a UAC/admin prompt.
#   - If winget is unavailable, install "App Installer" from Microsoft Store or
#     install the prerequisites manually, then rerun this script.

param(
    [string]$RepoUrl = "https://github.com/Fincept-Corporation/FinceptTerminal.git",
    [string]$TargetDir = (Join-Path (Get-Location).Path "FinceptTerminal"),
    [string]$QtRoot = (Join-Path (Get-Location).Path ".qt-fincept"),
    [int]$Parallel = 4,
    [switch]$SkipPrereqInstall,
    [switch]$Launch
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Require-Command {
    param(
        [string]$Name,
        [string]$InstallHint
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing command '$Name'. $InstallHint"
    }
}

function Refresh-PathFromRegistry {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath) -join ";"
}

function Require-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install 'App Installer' from Microsoft Store, or install Git/Python/VS Build Tools manually and rerun with -SkipPrereqInstall."
    }
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Override = ""
    )

    Require-Winget
    Write-Host "Installing $Name via winget..." -ForegroundColor Yellow

    $args = @(
        "install",
        "--id", $Id,
        "--exact",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $args += @("--override", $Override)
    }

    winget @args
    if ($LASTEXITCODE -ne 0) {
        throw "winget install failed for $Name ($Id). Exit code: $LASTEXITCODE"
    }

    Refresh-PathFromRegistry
}

function Ensure-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host "Git: $((git --version) -join ' ')"
        return
    }
    if ($SkipPrereqInstall) {
        throw "Git not found. Install Git for Windows or rerun without -SkipPrereqInstall."
    }
    Install-WingetPackage -Id "Git.Git" -Name "Git for Windows"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git was installed but is not visible in this PowerShell session. Close PowerShell, reopen it, and rerun this script."
    }
    Write-Host "Git: $((git --version) -join ' ')"
}

function Get-PythonCommand {
    $candidates = @(
        @{ Command = "py"; Args = @("-3.11") },
        @{ Command = "py"; Args = @("-3") },
        @{ Command = "python"; Args = @() },
        @{ Command = "python3"; Args = @() }
    )

    foreach ($candidate in $candidates) {
        if (-not (Get-Command $candidate.Command -ErrorAction SilentlyContinue)) {
            continue
        }

        $versionText = & $candidate.Command @($candidate.Args + @("-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")) 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($versionText)) {
            continue
        }

        $parts = $versionText.Trim().Split(".") | ForEach-Object { [int]$_ }
        if ($parts[0] -gt 3 -or ($parts[0] -eq 3 -and $parts[1] -ge 11)) {
            return @{ Command = $candidate.Command; Args = $candidate.Args; Version = $versionText.Trim() }
        }
    }

    throw "Python 3.11+ not found. Install Python 3.11 from python.org, then re-run this script."
}

function Ensure-Python {
    try {
        return Get-PythonCommand
    }
    catch {
        if ($SkipPrereqInstall) {
            throw
        }
        Install-WingetPackage -Id "Python.Python.3.11" -Name "Python 3.11"
        Refresh-PathFromRegistry
        try {
            return Get-PythonCommand
        }
        catch {
            throw "Python 3.11 was installed but is not visible in this PowerShell session. Close PowerShell, reopen it, and rerun this script."
        }
    }
}

function Invoke-Python {
    param(
        [hashtable]$Python,
        [string[]]$Arguments
    )
    & $Python.Command @($Python.Args + $Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed: $($Python.Command) $($Python.Args -join ' ') $($Arguments -join ' ')"
    }
}

function Get-VcVars64Path {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found. Install Visual Studio 2022 Build Tools with the C++ workload. Example: winget install Microsoft.VisualStudio.2022.BuildTools"
    }

    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installPath)) {
        throw "MSVC C++ tools not found. Open Visual Studio Installer and install 'Desktop development with C++'."
    }

    $vcvars = Join-Path $installPath.Trim() "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $vcvars)) {
        throw "vcvars64.bat not found at: $vcvars"
    }

    return $vcvars
}

function Get-VisualStudioInstallPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        return $null
    }

    $installPath = & $vswhere -latest -products * -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installPath)) {
        return $null
    }

    return $installPath.Trim()
}

function Add-VcToolsWorkload {
    $installPath = Get-VisualStudioInstallPath
    if ([string]::IsNullOrWhiteSpace($installPath)) {
        return $false
    }

    $installer = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vs_installer.exe"
    if (-not (Test-Path $installer)) {
        return $false
    }

    Write-Host "Adding Visual Studio C++ workload to: $installPath" -ForegroundColor Yellow
    & $installer modify `
        --installPath $installPath `
        --quiet `
        --wait `
        --norestart `
        --add Microsoft.VisualStudio.Workload.VCTools `
        --includeRecommended

    if ($LASTEXITCODE -ne 0) {
        throw "Visual Studio Installer failed while adding C++ workload. Exit code: $LASTEXITCODE"
    }

    return $true
}

function Ensure-VsBuildTools {
    try {
        return Get-VcVars64Path
    }
    catch {
        if ($SkipPrereqInstall) {
            throw
        }

        $override = "--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
        Install-WingetPackage -Id "Microsoft.VisualStudio.2022.BuildTools" -Name "Visual Studio 2022 Build Tools C++ workload" -Override $override

        try {
            return Get-VcVars64Path
        }
        catch {
            if (Add-VcToolsWorkload) {
                try {
                    return Get-VcVars64Path
                }
                catch {
                    # Fall through to the actionable error below.
                }
            }
            throw "Visual Studio Build Tools were installed, but C++ tools are not visible yet. If installation is still finishing, wait for it; otherwise reboot or reopen PowerShell, then rerun this script."
        }
    }
}

function Invoke-VcVarsCommand {
    param(
        [string]$VcVars64,
        [string]$WorkingDirectory,
        [string[]]$Commands
    )

    $batchPath = Join-Path $env:TEMP ("fincept-build-{0}.cmd" -f ([guid]::NewGuid().ToString("N")))
    $batchLines = @(
        "@echo off",
        "call `"$VcVars64`"",
        "if errorlevel 1 exit /b %errorlevel%",
        "cd /d `"$WorkingDirectory`""
    ) + $Commands + @(
        "exit /b %errorlevel%"
    )

    Set-Content -Path $batchPath -Value ($batchLines -join "`r`n") -Encoding ASCII
    try {
        cmd.exe /d /s /c "`"$batchPath`""
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed inside MSVC environment. Exit code: $LASTEXITCODE"
        }
    }
    finally {
        Remove-Item $batchPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Checking prerequisites"
Ensure-Git
$python = Ensure-Python
Write-Host "Python: $($python.Command) $($python.Args -join ' ') ($($python.Version))"
$vcvars64 = Ensure-VsBuildTools
Write-Host "MSVC environment: $vcvars64"

Write-Step "Installing user-level build tools"
Invoke-Python $python @("-m", "pip", "install", "--user", "--upgrade", "pip")
Invoke-Python $python @("-m", "pip", "install", "--user", "cmake==3.27.7", "ninja", "aqtinstall", "yt-dlp")

$userScripts = (& $python.Command @($python.Args + @("-c", "import site, pathlib; print(pathlib.Path(site.USER_BASE) / 'Scripts')"))).Trim()
if (-not (Test-Path $userScripts)) {
    throw "Python user Scripts directory not found: $userScripts"
}
$env:Path = "$userScripts;$env:Path"
Write-Host "Using Python Scripts path: $userScripts"

Write-Step "Cloning or reusing repository"
$repoFromScriptRoot = Test-Path (Join-Path $PSScriptRoot "fincept-qt\CMakeLists.txt")
if ($repoFromScriptRoot) {
    $repoDir = $PSScriptRoot
    Write-Host "Running inside repo: $repoDir"
}
else {
    $repoDir = $TargetDir
    if (-not (Test-Path $repoDir)) {
        git clone $RepoUrl $repoDir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
    else {
        Write-Host "Repo already exists: $repoDir"
    }
}

$appDir = Join-Path $repoDir "fincept-qt"
if (-not (Test-Path (Join-Path $appDir "CMakePresets.json"))) {
    throw "Could not find fincept-qt/CMakePresets.json under: $repoDir"
}

Write-Step "Installing Qt 6.8.3 with required modules"
$qtPrefix = Join-Path $QtRoot "6.8.3\msvc2022_64"
$qtConfig = Join-Path $qtPrefix "lib\cmake\Qt6\Qt6Config.cmake"
if (-not (Test-Path $qtConfig)) {
    aqt install-qt windows desktop 6.8.3 win64_msvc2022_64 --outputdir $QtRoot --modules qtcharts qtwebsockets qtmultimedia qtspeech
    if ($LASTEXITCODE -ne 0) { throw "aqt Qt install failed" }
}
else {
    Write-Host "Qt already installed: $qtPrefix"
}

if (-not (Test-Path $qtConfig)) {
    throw "Qt6Config.cmake not found after install: $qtConfig"
}

$ytDlp = (Get-Command yt-dlp -ErrorAction Stop).Source
Write-Host "yt-dlp: $ytDlp"

Write-Step "Configuring and building Fincept Terminal"
$buildCommands = @(
    "set `"PATH=$userScripts;%PATH%`"",
    "cmake --preset win-release -DCMAKE_PREFIX_PATH=`"$qtPrefix`" -DFINCEPT_YTDLP_EXE=`"$ytDlp`"",
    "if errorlevel 1 exit /b %errorlevel%",
    "cmake --build --preset win-release --parallel $Parallel",
    "if errorlevel 1 exit /b %errorlevel%"
)
Invoke-VcVarsCommand -VcVars64 $vcvars64 -WorkingDirectory $appDir -Commands $buildCommands

$exePath = Join-Path $appDir "build\win-release\FinceptTerminal.exe"
if (-not (Test-Path $exePath)) {
    throw "Build finished but executable was not found: $exePath"
}

Write-Step "Done"
Write-Host "Executable: $exePath" -ForegroundColor Green
Write-Host "Run it with: `"$exePath`""
Write-Host "First launch may initialize the embedded Python analytics environments."

if ($Launch) {
    Write-Step "Launching Fincept Terminal"
    Start-Process -FilePath $exePath -WorkingDirectory (Split-Path $exePath -Parent)
}
