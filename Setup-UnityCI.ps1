#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $LicensePath = "$env:ProgramData\Unity\Unity_lic.ulf",
    [string] $AssetRef = 'main',
    [string] $Repository
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
        $portableGhDirectory = Join-Path $env:LOCALAPPDATA 'GitHubCLI\bin'
        New-Item -ItemType Directory -Path $portableGhDirectory -Force | Out-Null
        $gh = Join-Path $portableGhDirectory 'gh.exe'
        Copy-Item -LiteralPath $executables[0].FullName -Destination $gh -Force
    }

    $credentialHelpers = @(& git config --get-urlmatch credential.helper 'https://github.com' 2>$null)
    $hasCredentialHelper = $LASTEXITCODE -eq 0 -and @($credentialHelpers | Where-Object { $_ }).Count -gt 0
    $oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
    if ($hasCredentialHelper) {
        Write-Host 'An existing Git credential helper was found. Its persistent configuration will be protected during GitHub CLI login.'
        $env:GIT_CONFIG_GLOBAL = Join-Path $tempDirectory 'gitconfig'
    } else {
        Write-Host 'No Git credential helper was found. GitHub CLI may offer to configure one during login.'
    }
    try {
        & $gh auth login --hostname github.com --web --scopes 'repo,workflow'
        Assert-NativeSuccess 'GitHub login failed. Remove GH_TOKEN/GITHUB_TOKEN from this shell if they prevent interactive login.'
    } finally {
        $env:GIT_CONFIG_GLOBAL = $oldGitConfigGlobal
    }

    if (-not $Repository) {
        $currentBranch = & git branch --show-current 2>$null
        $pushRemote = $null
        if ($LASTEXITCODE -eq 0 -and $currentBranch) {
            $pushRemote = & git config --get "branch.$currentBranch.pushRemote" 2>$null
            if ($LASTEXITCODE -ne 0) { $pushRemote = $null }
        }
        if (-not $pushRemote) {
            $pushRemote = & git config --get remote.pushDefault 2>$null
            if ($LASTEXITCODE -ne 0) { $pushRemote = $null }
        }
        if (-not $pushRemote) { $pushRemote = 'origin' }
        $pushUrl = & git remote get-url --push $pushRemote
        Assert-NativeSuccess "Cannot resolve the push URL for Git remote '$pushRemote'. Supply -Repository owner/repo to select the target explicitly."
        $remoteMatch = [regex]::Match($pushUrl.Trim(), '^(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)(?<name>[^/]+/[^/]+?)(?:\.git)?/?$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $remoteMatch.Success) {
            throw "Cannot identify a GitHub repository from remote '$pushRemote'. Supply -Repository owner/repo to select the target explicitly."
        }
        $Repository = $remoteMatch.Groups['name'].Value
    }
    if ($Repository -notmatch '^[^/\s]+/[^/\s]+$') {
        throw 'Repository must be specified as owner/repo.'
    }
    $repositoryJson = & $gh repo view $Repository --json 'nameWithOwner,defaultBranchRef'
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
    $existingWorkflow = $tree.tree | Where-Object { $_.path -ceq $workflowPath }

    Write-Host "Target: https://github.com/$repository (branch: $branch)"
    Write-Host "This will set UNITY_LICENSE, UNITY_EMAIL and UNITY_PASSWORD and commit $workflowPath."
    Write-Host 'It will also set the Actions variable UNITY_BUILD_WEB to TRUE (Web builds enabled on tags).'
    Write-Host 'You will provide a legacy Personal .ulf license file. Setup does not install Unity CLI or activate Unity.'
    if ($existingWorkflow) { Write-Warning 'The existing unity-build.yml workflow will be replaced.' }
    if ((Read-Host 'Continue? Type YES to confirm') -cne 'YES') { throw 'Setup cancelled; no repository changes were made.' }

    Write-Host ''
    Write-Host 'Prepare your Personal license file (keep this PowerShell window open):'
    Write-Host '1. Open Unity Hub and sign in with the Personal account you will use for CI.'
    Write-Host '2. Open Preferences > Licenses (or your profile menu > Manage licenses).'
    Write-Host '3. Click Add > Get a free personal license, EVEN IF Personal already appears active.'
    Write-Host '4. Read the terms in Hub and accept them yourself if you agree. Setup does not accept them for you.'
    Write-Host '   Unity terms: https://unity.com/legal/terms-of-service/software'
    Write-Host '5. In File Explorer, paste C:\ProgramData\Unity into the address bar (ProgramData is hidden).'
    Write-Host '   Look for Unity_lic.ulf. An active/Assigned license alone does not guarantee this file exists.'
    Write-Host '   If you already have a legacy Personal .ulf for this account, you may use it instead.'
    Write-Host '   Do not rename UnityEntitlementLicense.xml or an .alf request: neither is a compatible .ulf.'
    Write-Host '   If Hub has no Personal activation option or produces no .ulf, stop here; see https://game.ci/docs/github/activation.'
    Write-Host '   Setup cannot generate or convert a license. Do not share its contents or commit it to Git.'
    Write-Host "6. Return here. Press Enter to use '$LicensePath', paste another file path, or type CANCEL."
    $licenseInput = Read-Host 'Personal .ulf file path (Enter = path above; CANCEL = stop)'
    if ($licenseInput.Trim() -ieq 'CANCEL') { throw 'Setup cancelled; no repository changes were made.' }
    if (-not [string]::IsNullOrWhiteSpace($licenseInput)) {
        $LicensePath = $licenseInput.Trim().Trim('"')
    }
    if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) {
        throw "No Personal .ulf file was found at '$LicensePath'. Follow the Unity Hub steps above, then rerun setup with -LicensePath pointing to the existing file. If Hub only provides entitlement XML, this workflow cannot use it. No repository changes were made."
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
    Write-Host 'Enter the email and password for the SAME Unity account that owns the supplied license. GitHub CLI hides the secret input.'
    & $gh secret set UNITY_EMAIL --repo $repository
    Assert-NativeSuccess 'Could not set UNITY_EMAIL.'
    & $gh secret set UNITY_PASSWORD --repo $repository
    Assert-NativeSuccess 'Could not set UNITY_PASSWORD.'

    & $gh variable set UNITY_BUILD_WEB --repo $repository --body TRUE
    Assert-NativeSuccess 'Could not set UNITY_BUILD_WEB. Repository admin access is required.'

    $payload = @{
        message = 'Configure Unity GameCI builds'
        branch = $branch
        content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($workflowFile))
    }
    if ($existingWorkflow) { $payload.sha = $existingWorkflow.sha }
    $payload | ConvertTo-Json -Compress | & $gh api "repos/$repository/contents/$workflowPath" --method PUT --input - --silent
    Assert-NativeSuccess 'Could not commit the workflow. Check workflow write permission, branch protection, or concurrent changes. Secrets already set are retained; rerunning is safe.'
    Write-Host "Workflow committed to $branch. Pull that commit locally before pushing your Build Profiles and a tag."
    Write-Host 'Enabled by default: Assets/BuildProfiles/CI-Web.asset (Web). Optional: CI-Windows.asset (Windows), CI-macOS.asset (macOS). See the README for settings and build switches.'
} finally {
    $OutputEncoding = $oldOutputEncoding
    $license = $null
    if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
