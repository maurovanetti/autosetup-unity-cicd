BeforeAll {
    $script:setup = Join-Path (Split-Path $PSScriptRoot -Parent) 'Setup-UnityCI.ps1'
    function Invoke-TestGh {
        $arguments = @($args)
        $global:UnityCiTest.Calls.Add([pscustomobject]@{ Arguments = $arguments; Input = (@($input) -join "`n"); GitConfigGlobal = $env:GIT_CONFIG_GLOBAL })
        $global:LASTEXITCODE = 0
        switch ($arguments[0]) {
            'repo' { '{"nameWithOwner":"example/project","defaultBranchRef":{"name":"main"}}' }
            'variable' {
                if ($global:UnityCiTest.VariableFails) { $global:LASTEXITCODE = 1 }
            }
            'api' {
                if ($arguments[1] -like '*/git/trees/*') {
                    @{ truncated = $false; tree = $global:UnityCiTest.RemoteFiles } | ConvertTo-Json -Depth 4
                } elseif ($global:UnityCiTest.UploadFails) {
                    $global:LASTEXITCODE = 1
                }
            }
        }
    }
}

Describe 'Guided Unity CI setup' {
    BeforeEach {
        $script:oldOS = $env:OS
        $script:oldArchitecture = $env:PROCESSOR_ARCHITECTURE
        $script:oldWowArchitecture = $env:PROCESSOR_ARCHITEW6432
        $script:oldLocalAppData = $env:LOCALAPPDATA
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
            GitCalls = [Collections.Generic.List[object]]::new()
            RemoteFiles = @()
            UploadFails = $false
            VariableFails = $false
            DownloadDirectory = $null
            CredentialHelper = $null
            BranchPushRemote = $null
            DefaultPushRemote = $null
            PushUrl = 'git@github.com:example/project.git'
            InstalledGhPath = $null
            LicensePath = $script:licensePath
            LicenseText = $script:licenseText
        }
        Push-Location $script:project
        $script:oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
        Mock git {
            $arguments = @($args)
            $global:UnityCiTest.GitCalls.Add([pscustomobject]@{ Arguments = $arguments })
            $global:LASTEXITCODE = 0
            if ($arguments[0] -eq 'rev-parse') {
                (Get-Location).Path
            } elseif ($arguments[0] -eq 'branch') {
                'feature'
            } elseif ($arguments[0] -eq 'config' -and $arguments[1] -eq '--get-urlmatch') {
                if ($global:UnityCiTest.CredentialHelper) { $global:UnityCiTest.CredentialHelper } else { $global:LASTEXITCODE = 1 }
            } elseif ($arguments[0] -eq 'config' -and $arguments[2] -eq 'branch.feature.pushRemote') {
                if ($global:UnityCiTest.BranchPushRemote) { $global:UnityCiTest.BranchPushRemote } else { $global:LASTEXITCODE = 1 }
            } elseif ($arguments[0] -eq 'config' -and $arguments[2] -eq 'remote.pushDefault') {
                if ($global:UnityCiTest.DefaultPushRemote) { $global:UnityCiTest.DefaultPushRemote } else { $global:LASTEXITCODE = 1 }
            } elseif ($arguments[0] -eq 'remote') {
                $global:UnityCiTest.PushUrl
            }
        }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-TestGh' } } -ParameterFilter { $Name -eq 'gh' }
        Mock Get-Command { throw 'Unity CLI must not be discovered.' } -ParameterFilter { $Name -eq 'unity' }
        Mock Read-Host { 'YES' } -ParameterFilter { $Prompt -like 'Continue?*' }
        Mock Read-Host { '' } -ParameterFilter { $Prompt -like 'Personal .ulf file path*' }
        Mock Write-Host {}
        Mock Start-Process { throw 'Setup must not launch installers or Unity.' }
        Mock Invoke-WebRequest {
            $global:UnityCiTest.DownloadDirectory = Split-Path $OutFile -Parent
            Set-Content -LiteralPath $OutFile 'name: test workflow'
        }
    }
    AfterEach {
        Pop-Location
        $env:GIT_CONFIG_GLOBAL = $script:oldGitConfigGlobal
        $env:OS = $script:oldOS
        $env:PROCESSOR_ARCHITECTURE = $script:oldArchitecture
        $env:PROCESSOR_ARCHITEW6432 = $script:oldWowArchitecture
        $env:LOCALAPPDATA = $script:oldLocalAppData
        Remove-Variable UnityCiTest -Scope Global
    }

    It 'guides the user, pipes the validated license and commits without Unity CLI' {
        & $script:setup -LicensePath $script:licensePath
        $script:calls[0].Arguments -join ' ' | Should -Be 'auth login --hostname github.com --web --scopes repo,workflow'
        ($script:calls | Where-Object { $_.Arguments[0] -eq 'repo' }).Arguments -join ' ' | Should -Be 'repo view example/project --json nameWithOwner,defaultBranchRef'
        @($global:UnityCiTest.GitCalls | Where-Object { $_.Arguments -join ' ' -eq 'remote get-url --push origin' }).Count | Should -Be 1
        $secretCalls = @($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' })
        $secretCalls.Count | Should -Be 3
        $secretCalls[0].Input | Should -BeExactly $script:licenseText
        $secretCalls[0].Arguments -join ' ' | Should -Be 'secret set UNITY_LICENSE --repo example/project'
        $secretCalls[1].Arguments[2] | Should -Be 'UNITY_EMAIL'
        $secretCalls[2].Arguments[2] | Should -Be 'UNITY_PASSWORD'
        ($script:calls | Where-Object { $_.Arguments[0] -eq 'variable' }).Arguments -join ' ' | Should -Be 'variable set UNITY_BUILD_WEB --repo example/project --body TRUE'
        $payload = $script:calls[-1].Input | ConvertFrom-Json
        $payload.branch | Should -Be 'main'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.content)) | Should -Match 'name: test workflow'
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
        Test-Path "$script:project/.github" | Should -BeFalse
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Get-Command -Times 0 -Exactly -ParameterFilter { $Name -eq 'unity' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*EVEN IF Personal already appears active*' }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*Do not rename UnityEntitlementLicense.xml*' }
    }

    It 'requires explicit consent before license preparation or repository writes' {
        Mock Read-Host { 'no' } -ParameterFilter { $Prompt -like 'Continue?*' }
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*cancelled*'
        Should -Invoke Read-Host -Times 0 -Exactly -ParameterFilter { $Prompt -like 'Personal .ulf file path*' }
        @($script:calls | Where-Object { $_.Arguments[0] -in @('secret', 'variable') -or $_.Arguments -contains 'PUT' }).Count | Should -Be 0
    }

    It 'waits for Hub preparation before checking the license file' {
        Remove-Item -LiteralPath $script:licensePath
        Mock Read-Host {
            Set-Content -LiteralPath $global:UnityCiTest.LicensePath $global:UnityCiTest.LicenseText -NoNewline
            ''
        } -ParameterFilter { $Prompt -like 'Personal .ulf file path*' }
        & $script:setup -LicensePath $script:licensePath
        ($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' })[0].Input | Should -BeExactly $script:licenseText
    }

    It 'uses the standard ProgramData license path when Enter is pressed without -LicensePath' {
        $oldProgramData = $env:ProgramData
        try {
            $env:ProgramData = Join-Path $TestDrive 'ProgramData'
            $directory = Join-Path $env:ProgramData 'Unity'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            Copy-Item -LiteralPath $script:licensePath -Destination (Join-Path $directory 'Unity_lic.ulf')
            & $script:setup
            ($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' })[0].Input | Should -BeExactly $script:licenseText
        } finally {
            $env:ProgramData = $oldProgramData
        }
    }

    It 'accepts a quoted path with spaces entered at the prompt' {
        $alternatePath = Join-Path $TestDrive 'License folder/Personal.ulf'
        New-Item -ItemType Directory -Path (Split-Path $alternatePath) | Out-Null
        Copy-Item -LiteralPath $script:licensePath -Destination $alternatePath
        $global:UnityCiTest.LicensePath = $alternatePath
        Mock Read-Host { '"' + $global:UnityCiTest.LicensePath + '"' } -ParameterFilter { $Prompt -like 'Personal .ulf file path*' }
        & $script:setup -LicensePath (Join-Path $TestDrive 'missing.ulf')
        ($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' })[0].Input | Should -BeExactly $script:licenseText
    }

    It 'allows cancellation at the license prompt before repository writes' {
        Mock Read-Host { ' cancel ' } -ParameterFilter { $Prompt -like 'Personal .ulf file path*' }
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*cancelled*'
        @($script:calls | Where-Object { $_.Arguments[0] -in @('secret', 'variable') -or $_.Arguments -contains 'PUT' }).Count | Should -Be 0
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
    }

    It 'updates an existing workflow using its SHA' {
        $global:UnityCiTest.RemoteFiles = @(@{ path = '.github/workflows/unity-build.yml'; sha = 'previous-blob' })
        & $script:setup -LicensePath $script:licensePath
        ($script:calls[-1].Input | ConvertFrom-Json).sha | Should -Be 'previous-blob'
    }

    It 'does not reuse a differently-cased workflow path SHA' {
        $global:UnityCiTest.RemoteFiles = @(@{ path = '.github/workflows/Unity-Build.yml'; sha = 'different-blob' })
        & $script:setup -LicensePath $script:licensePath
        ($script:calls[-1].Input | ConvertFrom-Json).sha | Should -BeNullOrEmpty
    }

    It 'accepts an explicit repository instead of inferring the push remote' {
        & $script:setup -LicensePath $script:licensePath -Repository 'my-fork/project'
        ($script:calls | Where-Object { $_.Arguments[0] -eq 'repo' }).Arguments -join ' ' | Should -Be 'repo view my-fork/project --json nameWithOwner,defaultBranchRef'
    }

    It 'protects an existing Git credential helper during interactive login' {
        $global:UnityCiTest.CredentialHelper = 'manager-core'
        $env:GIT_CONFIG_GLOBAL = 'original-gitconfig'
        & $script:setup -LicensePath $script:licensePath
        $script:calls[0].GitConfigGlobal | Should -Match 'gitconfig$'
        $env:GIT_CONFIG_GLOBAL | Should -Be 'original-gitconfig'
    }

    It 'rejects a missing license without repository writes' {
        Remove-Item -LiteralPath $script:licensePath
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*No Personal .ulf file was found*No repository changes*'
        @($script:calls | Where-Object { $_.Arguments[0] -in @('secret', 'variable') -or $_.Arguments -contains 'PUT' }).Count | Should -Be 0
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

    It 'rejects a non-Personal serial without uploading secrets' {
        $data = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('TEST' + 'P' + ('0' * 26)))
        Set-Content $script:licensePath "<root><License><DeveloperData Value=`"$data`"/></License></root>"
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*valid legacy Personal serial*'
        @($script:calls | Where-Object { $_.Arguments[0] -eq 'secret' }).Count | Should -Be 0
    }

    It 'reports a remote commit failure and cleans up the download' {
        $global:UnityCiTest.UploadFails = $true
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*Could not commit the workflow*'
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
    }

    It 'stops before committing the workflow if the Web variable cannot be set' {
        $global:UnityCiTest.VariableFails = $true
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*Could not set UNITY_BUILD_WEB*'
        @($script:calls | Where-Object { $_.Arguments -contains 'PUT' }).Count | Should -Be 0
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

    It 'keeps the verified portable CLI at a stable per-user path' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
        $env:LOCALAPPDATA = Join-Path $TestDrive 'Local App Data'
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
        Mock Copy-Item {
            $global:UnityCiTest.InstalledGhPath = $Destination
            New-Item -ItemType Directory -Path (Split-Path $Destination) -Force | Out-Null
            Set-Content -LiteralPath $Destination 'portable executable'
            throw 'Portable CLI installed for test.'
        }
        { & $script:setup -LicensePath $script:licensePath } | Should -Throw '*Portable CLI installed for test*'
        Should -Invoke Expand-Archive -Times 1 -Exactly
        $global:UnityCiTest.InstalledGhPath | Should -Be (Join-Path $env:LOCALAPPDATA 'GitHubCLI\bin\gh.exe')
        Test-Path -LiteralPath $global:UnityCiTest.InstalledGhPath | Should -BeTrue
        Test-Path -LiteralPath $global:UnityCiTest.DownloadDirectory | Should -BeFalse
    }
}
