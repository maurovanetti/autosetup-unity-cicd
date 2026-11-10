BeforeAll {
    $script:setup = Join-Path (Split-Path $PSScriptRoot -Parent) 'Setup-UnityCI.ps1'
    function Invoke-TestGh {
        $arguments = @($args)
        $global:UnityCiTest.Calls.Add([pscustomobject]@{ Tool = 'gh'; Arguments = $arguments; Input = (@($input) -join "`n") })
        $global:LASTEXITCODE = 0
        switch ($arguments[0]) {
            'repo' { '{"nameWithOwner":"example/project","defaultBranchRef":{"name":"main"}}' }
            'api' {
                if ($arguments[1] -like '*/git/trees/*') {
                    @{ truncated = $false; tree = $global:UnityCiTest.RemoteFiles } | ConvertTo-Json -Depth 4
                } elseif ($global:UnityCiTest.UploadFails) {
                    $global:LASTEXITCODE = 1
                }
            }
        }
    }
    function Invoke-TestUnity {
        $global:UnityCiTest.Calls.Add([pscustomobject]@{ Tool = 'unity'; Arguments = @($args) })
        $global:LASTEXITCODE = if ($global:UnityCiTest.ActivationFails -and $args[0] -eq 'license') { 1 } else { 0 }
    }
}

Describe 'Standalone Unity CI setup' {
    BeforeEach {
        $script:oldOS = $env:OS
        $script:oldArchitecture = $env:PROCESSOR_ARCHITECTURE
        $script:oldWowArchitecture = $env:PROCESSOR_ARCHITEW6432
        $env:OS = 'Windows_NT'
        $script:project = Join-Path $TestDrive 'Project with spaces'
        New-Item -ItemType Directory -Path "$script:project/Assets", "$script:project/Packages", "$script:project/ProjectSettings" -Force | Out-Null
        Set-Content "$script:project/Packages/manifest.json" '{}'
        Set-Content "$script:project/ProjectSettings/ProjectVersion.txt" 'm_EditorVersion: 6000.0.60f1'
        $script:licensePath = Join-Path $TestDrive 'Unity_lic.ulf'
        $data = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('TEST' + 'F' + ('0' * 26)))
        $script:licenseText = "<root><License><DeveloperData Value=`"$data`"/></License></root>"
        Set-Content $script:licensePath $script:licenseText -NoNewline
        $script:calls = [Collections.Generic.List[object]]::new()
        $global:UnityCiTest = @{
            Calls = $script:calls
            RemoteFiles = @()
            UploadFails = $false
            ActivationFails = $false
            DownloadDirectory = $null
        }
        Push-Location $script:project
        Mock git { $global:LASTEXITCODE = 0; (Get-Location).Path }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-TestGh' } } -ParameterFilter { $Name -eq 'gh' }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-TestUnity' } } -ParameterFilter { $Name -eq 'unity' }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'Invoke-TestUnity' }
        Mock Read-Host { 'YES' }
        Mock Invoke-WebRequest {
            $global:UnityCiTest.DownloadDirectory = Split-Path $OutFile -Parent
            Set-Content -LiteralPath $OutFile 'name: test workflow'
        }
    }
    AfterEach {
        Pop-Location
        $env:OS = $script:oldOS
        $env:PROCESSOR_ARCHITECTURE = $script:oldArchitecture
        $env:PROCESSOR_ARCHITEW6432 = $script:oldWowArchitecture
        Remove-Variable UnityCiTest -Scope Global
    }

    It 'logs in, activates Personal, pipes the raw license and commits the workflow' {
        & $script:setup -LicensePath $script:licensePath
        $script:calls[0].Arguments -join ' ' | Should -Be 'auth login --hostname github.com --git-protocol https --web --scopes repo,workflow'
        $unityCalls = @($script:calls | Where-Object Tool -eq unity)
        $unityCalls.Count | Should -Be 3
        $unityCalls[0].Arguments -join ' ' | Should -Be 'auth login'
        $unityCalls[1].Arguments -join ' ' | Should -Be 'license activate --personal --accept-eula'
        $secretCalls = @($script:calls | Where-Object { $_.Tool -eq 'gh' -and $_.Arguments[0] -eq 'secret' })
        $secretCalls.Count | Should -Be 3
        $secretCalls[0].Input | Should -BeExactly $script:licenseText
        $secretCalls[0].Arguments -join ' ' | Should -Be 'secret set UNITY_LICENSE --repo example/project'
        $secretCalls[1].Arguments[2] | Should -Be 'UNITY_EMAIL'
        $secretCalls[2].Arguments[2] | Should -Be 'UNITY_PASSWORD'
        $payload = $script:calls[-1].Input | ConvertFrom-Json
        $payload.branch | Should -Be 'main'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.content)) | Should -Match 'name: test workflow'
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
        Test-Path "$script:project/.github" | Should -BeFalse
    }

    It 'requires explicit consent before changing secrets or activating Unity' {
        Mock Read-Host { 'no' }
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*cancelled*'
        @($script:calls | Where-Object { $_.Tool -eq 'unity' -or $_.Arguments[0] -eq 'secret' }).Count | Should -Be 0
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
    }

    It 'updates an existing workflow using its SHA' {
        $global:UnityCiTest.RemoteFiles = @(@{ path = '.github/workflows/unity-build.yml'; sha = 'previous-blob' })
        & $script:setup -LicensePath $script:licensePath
        ($script:calls[-1].Input | ConvertFrom-Json).sha | Should -Be 'previous-blob'
    }

    It 'rejects a missing license without uploading secrets' {
        Remove-Item -LiteralPath $script:licensePath
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*Activation did not produce*'
        @($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' }).Count | Should -Be 0
    }

    It 'rejects entitlement XML and activation requests without uploading secrets' {
        Set-Content $script:licensePath '<root><License/></root>'
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*missing DeveloperData*'
        @($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' }).Count | Should -Be 0
    }

    It 'rejects XML external entities' {
        Set-Content $script:licensePath '<!DOCTYPE root [<!ENTITY xxe SYSTEM "file:///nonexistent">]><root>&xxe;</root>'
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*DTD*'
        @($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' }).Count | Should -Be 0
    }

    It 'stops when Unity activation fails' {
        $global:UnityCiTest.ActivationFails = $true
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*activation failed*'
        @($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' }).Count | Should -Be 0
    }

    It 'reports a remote commit failure and cleans up the download' {
        $global:UnityCiTest.UploadFails = $true
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*Could not commit the workflow*'
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
    }

    It 'rejects pre-Unity-6 projects before authentication' {
        Set-Content "$script:project/ProjectSettings/ProjectVersion.txt" 'm_EditorVersion: 2022.3.60f1'
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*Unity 6*'
        $script:calls.Count | Should -Be 0
    }

    It 'rejects unsupported operating systems' {
        $env:OS = 'other'
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*Windows*'
        $script:calls.Count | Should -Be 0
    }

    It 'refuses a portable CLI archive with a mismatched checksum' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
        Mock Invoke-RestMethod {
            @{ assets = @(
                @{ name = 'gh_test_windows_amd64.zip'; browser_download_url = 'https://example.invalid/archive' },
                @{ name = 'gh_test_checksums.txt'; browser_download_url = 'https://example.invalid/checksums' }
            ) }
        }
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*checksum verification failed*'
        $script:calls.Count | Should -Be 0
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
    }

    It 'verifies and runs a portable CLI when gh is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
        Mock Invoke-RestMethod {
            @{ assets = @(
                @{ name = 'gh_test_windows_amd64.zip'; browser_download_url = 'https://example.invalid/archive' },
                @{ name = 'gh_test_checksums.txt'; browser_download_url = 'https://example.invalid/checksums' }
            ) }
        }
        Mock Invoke-WebRequest {
            $global:UnityCiTest.DownloadDirectory = Split-Path $OutFile -Parent
            if ($Uri -eq 'https://example.invalid/checksums') {
                $archivePath = Join-Path (Split-Path $OutFile) 'gh_test_windows_amd64.zip'
                $hash = (Get-FileHash -LiteralPath $archivePath).Hash
                Set-Content -LiteralPath $OutFile "$hash  gh_test_windows_amd64.zip"
            } else {
                Set-Content -LiteralPath $OutFile 'name: test workflow'
            }
        }
        Mock Expand-Archive {}
        Mock Get-ChildItem { [pscustomobject]@{ FullName = 'Invoke-TestGh' } } -ParameterFilter { $Filter -eq 'gh.exe' }
        & $script:setup -LicensePath $script:licensePath
        Should -Invoke Expand-Archive -Times 1 -Exactly
        @($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' }).Count | Should -Be 3
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
    }
}
