<#
.SYNOPSIS
    One-command helper to sign and sideload AegisClaw .ipa onto a USB-connected iPhone from Windows using xtool in WSL2 Ubuntu.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$IpaPath = "AegisClaw-unsigned.ipa",

    [Parameter(Mandatory = $false)]
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " AegisClaw iOS Sideloader (Windows + WSL2 xtool 1.22.0)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Step 1: Ensure .ipa exists locally (or auto-download from GitHub Actions)
Write-Host "`n[1/2] Checking for compiled iOS IPA ($IpaPath)..." -ForegroundColor Yellow
if (-not (Test-Path $IpaPath)) {
    Write-Host "Local IPA not found at '$IpaPath'. Checking GitHub Actions for latest 'AegisClaw-unsigned-ipa' artifact..." -ForegroundColor Cyan
    $ghToken = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "C:\Program Files\Git\mingw64\bin\git-credential-manager.exe"
        $psi.Arguments = "get"
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.WriteLine("protocol=https")
        $p.StandardInput.WriteLine("host=github.com")
        $p.StandardInput.WriteLine("")
        $p.StandardInput.Flush()
        $p.StandardInput.Close()
        $credOut = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        if ($credOut -match "password=([^\r\n]+)") {
            $ghToken = $Matches[1].Trim()
        }
    } catch {
        Write-Warning "Failed to query Git Credential Manager: $($_.Exception.Message)"
    }

    if ($ghToken) {
        $headers = @{
            Authorization = "Bearer $ghToken"
            Accept        = "application/vnd.github+json"
            "User-Agent"  = "AegisClaw-xtool-Sideloader"
        }
        $artifactsResp = Invoke-RestMethod -Uri "https://api.github.com/repos/archdakid/AegisClaw-iOS/actions/artifacts?name=AegisClaw-unsigned-ipa&per_page=1" -Headers $headers
        if ($artifactsResp.artifacts -and $artifactsResp.artifacts.Count -gt 0) {
            $artifact = $artifactsResp.artifacts[0]
            $zipPath = Join-Path $env:TEMP "AegisClaw-unsigned-ipa.zip"
            Write-Host "Downloading artifact #$($artifact.id) (created $($artifact.created_at))..." -ForegroundColor Cyan
            
            # Use HttpWebRequest without auto-redirect to capture redirect URL without forwarding Authorization header
            $req = [System.Net.HttpWebRequest]::Create($artifact.archive_download_url)
            $req.Headers.Add("Authorization", "Bearer $ghToken")
            $req.UserAgent = "AegisClaw-xtool-Sideloader"
            $req.AllowAutoRedirect = $false
            $resp = $req.GetResponse()
            $redirectUri = $resp.GetResponseHeader("Location")
            $resp.Close()

            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($redirectUri, $zipPath)
            Expand-Archive -Path $zipPath -DestinationPath "." -Force
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not (Test-Path $IpaPath)) {
    Write-Host "IPA file not found at: $IpaPath" -ForegroundColor Red
    exit 1
}

$resolvedWinPath = (Resolve-Path $IpaPath).Path
Write-Host "Ready to sideload: $resolvedWinPath" -ForegroundColor Green

# Convert Windows path to WSL path
$wslIpaPath = (wsl -d $Distro -e wslpath -u "$resolvedWinPath").Trim()

# Step 2: Run the WSL2 bridge + auth check + xtool install inside a single persistent WSL2 session
Write-Host "`n[2/2] Starting WSL2 usbmuxd bridge, Apple ID auth, and xtool install..." -ForegroundColor Yellow

$scriptDir = $PSScriptRoot
$wslScriptDir = (wsl -d $Distro -e wslpath -u "$scriptDir").Trim()

wsl -d $Distro -u root -- sed -i 's/\r$//' "$wslScriptDir/start-wsl-usbmuxd-bridge.sh" "$wslScriptDir/wsl-sideload.sh"
wsl -d $Distro -u root -- bash "$wslScriptDir/wsl-sideload.sh" "$wslIpaPath"
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n Successfully signed and installed AegisClaw onto your iPhone!" -ForegroundColor Green
    Write-Host "Note: On free Apple IDs, the first time you open the app on your iPhone, go to:" -ForegroundColor Yellow
    Write-Host "  Settings -> General -> VPN & Device Management -> [Your Apple ID] -> Trust" -ForegroundColor Yellow
} else {
    throw "xtool sideload exited with code $LASTEXITCODE"
}
