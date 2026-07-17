<#
.SYNOPSIS
  OTK config signing helper - PowerShell port of otk-sign.sh for Windows admins.

.DESCRIPTION
  Produces the exact same key format and detached RSA/SHA-256 (PKCS#1 v1.5)
  signatures as otk-sign.sh, so keys and .sig files are fully interchangeable
  between the two tools and verify identically on-device with macOS LibreSSL.

  Workflow:
    1. .\otk-sign.ps1 -Init
         Generates an RSA-4096 keypair in .\signing\ (one time) and writes the
         public key into ONBOARDING_SIGNING_PUBKEY in both installer scripts
         automatically (no manual copy/paste).
    2. .\otk-sign.ps1 [file ...]
         Signs each file, writing <file>.sig next to it. With no arguments it
         signs apps.json and onboardingtoolkit.zip if present in the current
         directory. Upload each file together with its .sig.
    3. .\otk-sign.ps1 -Verify <file> [file ...]
         Local sanity check: verifies <file> against <file>.sig with the
         public key, exactly like the installers will on-device.
    4. .\otk-sign.ps1 -InstallKey
         Re-writes the public key into the installer scripts on demand (e.g.
         after pulling fresh copies of them, or when rotating keys).

  Requires PowerShell 7+ (pwsh). KEEP .\signing\otk-signing.key OUT OF THE
  REPO AND OFF THE HOSTING - anyone holding it can push root-executed config
  to your entire fleet.
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
  [switch]$Init,
  [switch]$Verify,
  [switch]$InstallKey,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Files = @()
)

$ErrorActionPreference = 'Stop'

$KeyDir     = if ($env:OTK_KEY_DIR) { $env:OTK_KEY_DIR } else { Join-Path $PSScriptRoot 'signing' }
$PrivateKey = Join-Path $KeyDir 'otk-signing.key'
$PublicKey  = Join-Path $KeyDir 'otk-signing.pub'

function Fail([string]$Message) {
  Write-Error $Message -ErrorAction Continue
  exit 1
}

function ConvertTo-Pem([byte[]]$Der, [string]$Label) {
  $b64 = [Convert]::ToBase64String($Der)
  $lines = for ($i = 0; $i -lt $b64.Length; $i += 64) {
    $b64.Substring($i, [Math]::Min(64, $b64.Length - $i))
  }
  # Unix newlines so the same PEM pastes cleanly into the shell scripts.
  "-----BEGIN $Label-----`n" + ($lines -join "`n") + "`n-----END $Label-----`n"
}

function Import-RsaFromPemFile([string]$Path) {
  $rsa = [System.Security.Cryptography.RSA]::Create()
  # Accepts PKCS#1 (openssl genrsa) and PKCS#8 (this script) alike.
  $rsa.ImportFromPem((Get-Content -Path $Path -Raw))
  return $rsa
}

# Rewrite the ONBOARDING_SIGNING_PUBKEY="..." assignment in the installer
# scripts with the current public key. Handles both the empty placeholder and
# an already-populated multi-line value (key rotation), and is idempotent.
function Install-PublicKey {
  if (-not (Test-Path $PublicKey)) { Fail "No public key at $PublicKey - run: .\otk-sign.ps1 -Init first" }
  $pem = (Get-Content -Path $PublicKey -Raw).TrimEnd("`r", "`n")

  $targets = @('otk-install.sh', 'otk-intune-onboarding.sh') |
    ForEach-Object { Join-Path $PSScriptRoot $_ } |
    Where-Object { Test-Path $_ }

  if (-not $targets) {
    Write-Host "No installer scripts found next to this script - paste this manually into"
    Write-Host "ONBOARDING_SIGNING_PUBKEY in both installer scripts:"
    Write-Host ""
    Write-Host (Get-Content -Path $PublicKey -Raw)
    return
  }

  $regex = [regex]'readonly ONBOARDING_SIGNING_PUBKEY="[^"]*"'
  foreach ($t in $targets) {
    $content = [System.IO.File]::ReadAllText($t)
    if (-not $regex.IsMatch($content)) {
      Write-Warning "No ONBOARDING_SIGNING_PUBKEY line in $t - skipped."
      continue
    }
    $assignment = 'readonly ONBOARDING_SIGNING_PUBKEY="' + $pem + '"'
    # Escape $ in the substitution so .NET regex replacement treats it literally.
    $updated = $regex.Replace($content, $assignment.Replace('$', '$$'), 1)
    # WriteAllText: UTF-8 without BOM, line endings preserved as-is.
    [System.IO.File]::WriteAllText($t, $updated)
    Write-Host "Public key installed in: $t"
  }
}

function Invoke-Init {
  if (Test-Path $PrivateKey) {
    Write-Host "Keypair already exists at $KeyDir - refusing to overwrite."
    Write-Host "Delete the directory manually if you really want to rotate keys"
    Write-Host "(remember: rotating means updating the public key in both installer"
    Write-Host "scripts and re-signing every hosted artifact)."
  }
  else {
    New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null
    Write-Host "Generating RSA-4096 keypair in $KeyDir ..."
    $rsa = [System.Security.Cryptography.RSA]::Create(4096)
    [System.IO.File]::WriteAllText($PrivateKey, (ConvertTo-Pem $rsa.ExportPkcs8PrivateKey() 'PRIVATE KEY'))
    [System.IO.File]::WriteAllText($PublicKey,  (ConvertTo-Pem $rsa.ExportSubjectPublicKeyInfo() 'PUBLIC KEY'))
    # Best-effort ACL lockdown to the current user (Windows equivalent of chmod 600).
    try {
      icacls $PrivateKey /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    } catch { Write-Warning "Could not restrict ACLs on the private key - protect it manually." }
    Write-Host "Done."
  }

  Write-Host ""
  Install-PublicKey
  Write-Host ""
  Write-Host "Sign your artifacts before every upload:"
  Write-Host ""
  Write-Host "  .\otk-sign.ps1 apps.json onboardingtoolkit.zip"
  Write-Host ""
  Write-Host "IMPORTANT: never commit or upload $PrivateKey. Back it up somewhere safe"
  Write-Host "(password manager / offline). Losing it means generating a new pair and"
  Write-Host "updating the installers; leaking it means an attacker can sign malicious"
  Write-Host "config for your whole fleet."
}

function Invoke-Sign([string[]]$Targets) {
  if (-not (Test-Path $PrivateKey)) { Fail "No private key at $PrivateKey - run: .\otk-sign.ps1 -Init first" }
  $rsa = Import-RsaFromPemFile $PrivateKey
  foreach ($f in $Targets) {
    if (-not (Test-Path $f)) { Fail "File not found: $f" }
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $f))
    $sig = $rsa.SignData($bytes,
      [System.Security.Cryptography.HashAlgorithmName]::SHA256,
      [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    [System.IO.File]::WriteAllBytes("$((Resolve-Path $f).Path).sig", $sig)
    Write-Host "Signed: $f -> $f.sig"
  }
  Write-Host ""
  Write-Host "Upload each file TOGETHER WITH its .sig to your hosting (same folder)."
}

function Invoke-Verify([string[]]$Targets) {
  if (-not (Test-Path $PublicKey)) { Fail "No public key at $PublicKey - run: .\otk-sign.ps1 -Init" }
  if ($Targets.Count -lt 1) { Fail "Usage: .\otk-sign.ps1 -Verify <file> [file ...]" }
  $rsa = [System.Security.Cryptography.RSA]::Create()
  $rsa.ImportFromPem((Get-Content -Path $PublicKey -Raw))
  foreach ($f in $Targets) {
    if (-not (Test-Path $f))       { Fail "File not found: $f" }
    if (-not (Test-Path "$f.sig")) { Fail "Signature not found: $f.sig" }
    $ok = $rsa.VerifyData(
      [System.IO.File]::ReadAllBytes((Resolve-Path $f)),
      [System.IO.File]::ReadAllBytes((Resolve-Path "$f.sig")),
      [System.Security.Cryptography.HashAlgorithmName]::SHA256,
      [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if ($ok) { Write-Host "OK: $f matches $f.sig" }
    else     { Fail "VERIFICATION FAILED for $f - do not upload this pair." }
  }
}

if ($Init) {
  Invoke-Init
}
elseif ($InstallKey) {
  Install-PublicKey
}
elseif ($Verify) {
  Invoke-Verify $Files
}
else {
  $targets = $Files
  if ($targets.Count -eq 0) {
    $targets = @('apps.json', 'onboardingtoolkit.zip') | Where-Object { Test-Path $_ }
    if ($targets.Count -eq 0) { Fail "Nothing to sign: no apps.json or onboardingtoolkit.zip here. Pass files explicitly." }
  }
  Invoke-Sign $targets
}
