#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $UnityCli,
    [string] $LicensePath = "$env:ProgramData\Unity\Unity_lic.ulf",
    [string] $AssetRef = 'main'
)

$ErrorActionPreference = 'Stop'
$oldOutputEncoding = $OutputEncoding
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$tempDirectory = $null

function Assert-NativeSuccess([string] $Message) {
    if ($LASTEXITCODE -ne 0) { throw $Message }
}

try {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Run this setup on Windows with PowerShell 5.1 or later. No administrator privileges are required.'
    }
    foreach ($path in @('Assets', 'ProjectSettings/ProjectVersion.txt', 'Packages/manifest.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PWD $path))) {
            throw 'Run this script from the Unity project root (Assets, Packages and ProjectSettings must exist).'
        }
    }
    $gitRoot = & git rev-parse --show-toplevel
    Assert-NativeSuccess 'Git is required, and this Unity project must already be a GitHub repository.'
    if ([IO.Path]::GetFullPath($gitRoot) -ne [IO.Path]::GetFullPath($PWD.Path)) {
        throw 'The Unity project must be at the Git repository root.'
    }
    $versionText = Get-Content -LiteralPath (Join-Path $PWD 'ProjectSettings/ProjectVersion.txt') -Raw
    if ($versionText -notmatch '(?m)^m_EditorVersion: (6000\.\d+\.\d+[abfp]\d+)\s*$') {
        throw 'Unity 6 (6000.x) is required because the workflow uses Build Profiles.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ("unity-ci-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDirectory | Out-Null
    if (-not $UnityCli) {
        $unityCommand = Get-Command unity -CommandType Application -ErrorAction SilentlyContinue
        if ($unityCommand) {
            $UnityCli = $unityCommand.Source
        } else {
            Write-Host 'Installing Unity CLI for the current user (no elevation).'
            $installer = Join-Path $tempDirectory 'install-unity.ps1'
            Invoke-WebRequest 'https://unity.com/install.ps1' -OutFile $installer -UseBasicParsing
            $oldUnityHome = $env:UNITY_CLI_HOME
            $oldSkipSetup = $env:UNITY_CLI_SKIP_SETUP
            try {
                $env:UNITY_CLI_HOME = Join-Path $env:LOCALAPPDATA 'Unity'
                $env:UNITY_CLI_SKIP_SETUP = '1'
                $shellName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
                $process = Start-Process -FilePath (Join-Path $PSHOME $shellName) -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installer`"" -Wait -PassThru -NoNewWindow
                if ($process.ExitCode -ne 0) {
                    throw 'Unity CLI installation failed. Check the installer output, network access and write access to LOCALAPPDATA, then rerun setup.'
                }
                $UnityCli = Join-Path $env:UNITY_CLI_HOME 'bin\unity.exe'
            } finally {
                $env:UNITY_CLI_HOME = $oldUnityHome
                $env:UNITY_CLI_SKIP_SETUP = $oldSkipSetup
            }
        }
    }
    if (-not $UnityCli -or -not (Test-Path -LiteralPath $UnityCli -PathType Leaf)) {
        throw 'Unity CLI executable was not found. Check the installation output or supply a valid standalone CLI path with -UnityCli (not the Unity Editor executable).'
    }

    $ghCommand = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue
    if ($ghCommand) {
        $gh = $ghCommand.Source
    } else {
        Write-Host 'Downloading the official portable GitHub CLI (no installation or elevation).'
        $release = Invoke-RestMethod 'https://api.github.com/repos/cli/cli/releases/latest'
        $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        $architecture = switch ($architecture) {
            'AMD64' { 'amd64' }
            'ARM64' { 'arm64' }
            'x86' { '386' }
            default { throw "Unsupported Windows architecture: $architecture" }
        }
        $archives = @($release.assets | Where-Object { $_.name -like "*_windows_$architecture.zip" })
        $checksums = @($release.assets | Where-Object { $_.name -like '*_checksums.txt' })
        if ($archives.Count -ne 1 -or $checksums.Count -ne 1) {
            throw 'The GitHub CLI release is missing its Windows archive or checksum manifest.'
        }
        $archive = Join-Path $tempDirectory $archives[0].name
        $checksumFile = Join-Path $tempDirectory 'checksums.txt'
        Invoke-WebRequest $archives[0].browser_download_url -OutFile $archive -UseBasicParsing
        Invoke-WebRequest $checksums[0].browser_download_url -OutFile $checksumFile -UseBasicParsing
        $checksumPattern = '^([a-fA-F0-9]{64})\s+\*?' + [regex]::Escape($archives[0].name) + '$'
        $expectedHash = $null
        foreach ($line in Get-Content -LiteralPath $checksumFile) {
            if ($line -match $checksumPattern) { $expectedHash = $Matches[1] }
        }
        if (-not $expectedHash -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'GitHub CLI checksum verification failed. Nothing will be executed.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $tempDirectory 'gh')
        $executables = @(Get-ChildItem (Join-Path $tempDirectory 'gh') -Filter gh.exe -Recurse -File)
        if ($executables.Count -ne 1) { throw 'The portable GitHub CLI archive has an unexpected layout.' }
        $gh = $executables[0].FullName
    }

    & $gh auth login --hostname github.com --git-protocol https --web --scopes 'repo,workflow'
    Assert-NativeSuccess 'GitHub login failed. Remove GH_TOKEN/GITHUB_TOKEN from this shell if they prevent interactive login.'
    $repositoryJson = & $gh repo view --json 'nameWithOwner,defaultBranchRef'
    Assert-NativeSuccess 'Cannot identify the GitHub repository. Check the Git remote and your repository permissions.'
    $repositoryInfo = $repositoryJson | ConvertFrom-Json
    $repository = $repositoryInfo.nameWithOwner
    $branch = $repositoryInfo.defaultBranchRef.name
    if (-not $repository -or -not $branch) { throw 'Push an initial project commit to GitHub before running setup.' }

    $workflowPath = '.github/workflows/unity-build.yml'
    $workflowFile = Join-Path $tempDirectory 'unity-build.yml'
    $ref = [uri]::EscapeDataString($AssetRef)
    Invoke-WebRequest "https://raw.githubusercontent.com/maurovanetti/autosetup-unity-cicd/$ref/assets/unity-build.yml" -OutFile $workflowFile -UseBasicParsing
    $encodedBranch = [uri]::EscapeDataString($branch)
    $treeJson = & $gh api "repos/$repository/git/trees/$encodedBranch`?recursive=1"
    Assert-NativeSuccess 'Cannot inspect the default branch. Check that the project has been pushed to GitHub.'
    $tree = $treeJson | ConvertFrom-Json
    if ($tree.truncated) { throw 'The repository tree is too large to safely check for an existing workflow.' }
    $existingWorkflow = $tree.tree | Where-Object { $_.path -eq $workflowPath }

    Write-Host "Target: https://github.com/$repository (branch: $branch)"
    Write-Host "This will set UNITY_LICENSE, UNITY_EMAIL and UNITY_PASSWORD and commit $workflowPath."
    Write-Host 'It will also activate Unity Personal and accept its license terms: https://unity.com/legal/terms-of-service/software'
    if ($existingWorkflow) { Write-Warning 'The existing unity-build.yml workflow will be replaced.' }
    if ((Read-Host 'Continue? Type YES to confirm') -cne 'YES') { throw 'Setup cancelled; no repository changes were made.' }

    Write-Host 'Sign in interactively with the Unity Personal account you will use for CI.'
    & $UnityCli auth login
    Assert-NativeSuccess 'Unity CLI login failed. Complete browser login using a Personal account, not a service account.'
    & $UnityCli license activate --personal --accept-eula
    Assert-NativeSuccess 'Unity Personal activation failed. Check your eligibility, CLI version, and licensing-client installation.'
    & $UnityCli license status
    Assert-NativeSuccess 'Unity CLI did not report an active license.'
    if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) {
        throw "Activation did not produce a Personal .ulf at '$LicensePath'. GameCI needs a legacy Personal .ulf, not a token-based entitlement XML or .alf request. Try Unity Hub > Preferences > Licenses > Add > Get a free personal license, then rerun with -LicensePath if needed. If your account only supports token-based licensing, this hosted GameCI setup cannot proceed."
    }
    $license = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $LicensePath).Path)
    if ([string]::IsNullOrWhiteSpace($license) -or [Text.Encoding]::UTF8.GetByteCount($license) -gt 48KB) {
        throw 'The license is empty or exceeds the GitHub secret size limit (48 KB).'
    }
    $xmlSettings = New-Object System.Xml.XmlReaderSettings
    $xmlSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $xmlSettings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($license)), $xmlSettings)
    try {
        $licenseXml = New-Object System.Xml.XmlDocument
        $licenseXml.XmlResolver = $null
        $licenseXml.Load($reader)
        $developerData = $licenseXml.SelectSingleNode('//License/DeveloperData')
        if (-not $developerData -or -not $license.Contains('<DeveloperData Value="')) {
            throw 'The file is not a legacy GameCI-compatible Personal .ulf (missing DeveloperData). Entitlement XML and .alf request files cannot be used.'
        }
        $serialData = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($developerData.GetAttribute('Value')))
        if ($serialData.Length -ne 31 -or $serialData.Substring(4) -cnotmatch '^F[A-Z0-9-]{26}$') {
            throw 'The .ulf does not contain a valid legacy Personal serial for GameCI. Paid and token-based licenses are not supported by this setup.'
        }
    } finally { $reader.Dispose() }

    $license | & $gh secret set UNITY_LICENSE --repo $repository
    Assert-NativeSuccess 'Could not set UNITY_LICENSE. Repository admin access is required.'
    $license = $null
    Write-Host 'Enter the email and password for the SAME Unity account used for activation. GitHub CLI hides the secret input.'
    & $gh secret set UNITY_EMAIL --repo $repository
    Assert-NativeSuccess 'Could not set UNITY_EMAIL.'
    & $gh secret set UNITY_PASSWORD --repo $repository
    Assert-NativeSuccess 'Could not set UNITY_PASSWORD.'

    $payload = @{
        message = 'Configure Unity GameCI builds'
        branch = $branch
        content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workflowFile))
    }
    if ($existingWorkflow) { $payload.sha = $existingWorkflow.sha }
    $payload | ConvertTo-Json -Compress | & $gh api "repos/$repository/contents/$workflowPath" --method PUT --input - --silent
    Assert-NativeSuccess 'Could not commit the workflow. Check workflow write permission, branch protection, or concurrent changes. Secrets already set are retained; rerunning is safe.'
    Write-Host "Workflow committed to $branch. Pull that commit locally before pushing your Build Profiles and a tag."
    Write-Host 'Required: Assets/BuildProfiles/CI-Web.asset (Web). Optional: CI-Windows.asset (Windows), CI-macOS.asset (macOS). See the README for settings and desktop build switches.'
} finally {
    $OutputEncoding = $oldOutputEncoding
    $license = $null
    if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
