# autosetup-unity-cicd

One PowerShell script guides you through supplying a Unity Personal license and
sets up [GameCI](https://game.ci/) builds for an existing GitHub-hosted Unity project.
Only download `Setup-UnityCI.ps1`; it fetches the
workflow from this public repository's `assets/` directory itself.

## Prerequisites

- Windows, PowerShell 5.1+, Git, and an interactive desktop; no administrator
  privileges are needed. An existing `gh` is used, otherwise the official Windows
  portable ZIP is downloaded and SHA-256 checked against its release manifest.
  The verified executable is kept at `%LOCALAPPDATA%\GitHubCLI\bin\gh.exe` so a
  Git credential helper configured by `gh` will not point to a deleted file.
  GitHub login remains in GitHub CLI's normal credential store.
- Unity **6 (6000.x)** already installed, plus either **Unity Hub** for manual
  activation or an existing GameCI-compatible legacy Personal `.ulf` license file.
  **Unity CLI is not required:** setup does not download, update or run it,
  sign in to Unity, or activate a license automatically.
  The Editor version is read from `ProjectSettings/ProjectVersion.txt`.
  The Unity project must be the Git repository
  root, with an initial commit already pushed to GitHub.
- A **free Unity Personal** account eligible under Unity's terms, and repository
  admin access to set Actions secrets and variables. GitHub Actions must be enabled and permitted
  to run the actions in the template. The selected Unity version must have GameCI
  Docker images for your target platforms.

## Run setup

Place the script in the **Unity project root**, open PowerShell there, and run:

```powershell
.\Setup-UnityCI.ps1
```

For an existing license in a custom location:

```powershell
.\Setup-UnityCI.ps1 -LicensePath 'C:\path\Unity_lic.ulf'
```

Use `-Repository owner/repo` to select the target explicitly. Otherwise, setup
resolves the current branch's push remote, the configured default push remote, or
`origin` (in that order), then targets that remote's GitHub repository.

1. Complete `gh auth login` in your browser. The script requests repository and
   workflow permissions without forcing a Git credential helper change. If a helper
   is already configured, its persistent global configuration is isolated during
   login. Remove `GH_TOKEN`/`GITHUB_TOKEN` from the shell if they prevent interactive
   login.
2. Verify the displayed repository and default branch, then type `YES` to consent
   to repository changes. Setup warns before replacing an existing `unity-build.yml`.
3. Keep PowerShell open and follow the displayed Unity Hub license-preparation
   instructions, detailed below. At the file-path prompt, press **Enter** to use
   `C:\ProgramData\Unity\Unity_lic.ulf` (or your `-LicensePath`), paste another
   file path, or type **CANCEL** to stop. Paths containing spaces are supported,
   with or without surrounding double quotes.
4. The supplied file is validated, then uploaded using
   `gh secret set UNITY_LICENSE` through standard input. Enter the **same Unity
   account's** email and password at the hidden `gh secret set UNITY_EMAIL` and
   `gh secret set UNITY_PASSWORD` prompts. These are repository Actions secrets,
   not environment secrets. No credentials are passed in command-line arguments,
   written into the project, or printed by the script. Do not run with a transcript
   or debug tracing enabled.
5. The script sets the repository Actions variable `UNITY_BUILD_WEB` to `TRUE`
   (including on reruns), then commits `.github/workflows/unity-build.yml` **directly to the remote
   default branch** using `gh api`. Pull that commit locally before pushing your
   profiles/tags. Setup never commits your local project changes. Protected branches
   or organization policies may reject this API write; in that case, add the
   `assets/unity-build.yml` template at that path through your normal PR process.
   Secrets already uploaded remain set if a later step fails; rerunning replaces
   them and asks again before replacing the workflow.

`-AssetRef <tag-or-commit>` selects a trusted revision of this setup repository
instead of `main`. Review the downloaded script/template before granting access.

### Preparing the Personal license file

Follow [GameCI's Personal activation instructions](https://game.ci/docs/github/activation).
The script displays these steps and waits while you carry them out:

1. Open **Unity Hub** and sign in with the Personal account you will use for CI.
2. Open **Preferences > Licenses**, or your profile menu > **Manage licenses**.
3. Click **Add > Get a free personal license**, **even if a Personal license already
   appears active**. Read and accept the terms in Hub yourself if you agree.
   The script does not accept Unity's license terms on your behalf.
4. Open File Explorer and paste `C:\ProgramData\Unity` into its address bar.
   `ProgramData` is hidden by default. Look for **`Unity_lic.ulf`**.
5. Return to PowerShell and supply the file path at the prompt. If you already
   have a legacy Personal `.ulf` for the same account, you may use it instead.

**An active license is not enough:** successful sign-in or Personal activation
can leave you with an Assigned/entitlement license but no legacy `.ulf`.
If Hub has no Personal activation option or does not generate the file, type
`CANCEL` and consult the GameCI activation guidance. This setup cannot proceed
without a compatible file; the Hub steps are not a guarantee of file generation.

**Do not rename or upload `UnityEntitlementLicense.xml` or an `.alf` file.**
An `.alf` is only an activation request, and entitlement XML is not a legacy
Personal license. Setup checks the file's legacy `DeveloperData` Personal serial
before uploading any secrets, setting variables or committing the workflow.
A missing or incompatible file stops setup without those repository changes.
Do not share license contents or commit the license file to Git.

The script cannot manufacture or convert a license or bypass Unity licensing.
If Hub activation needs administrator assistance, have your existing Unity
installation configured by its administrator; setup never elevates.
Unity sign-in/2FA or licensing policy changes can still require manual intervention
during CI. The old `-UnityCli` and `-SkipUnityActivation` parameters have been removed;
manual license preparation is now the only setup path.

## Required Build Profiles

In Unity 6, use **File > Build Profiles**, add the appropriate platform profile,
and save it with the following **exact, case-sensitive asset path and name**:

| Build | Profile asset | Unity platform / GameCI target |
| --- | --- | --- |
| Web (enabled by default) | `Assets/BuildProfiles/CI-Web.asset` | Web / `WebGL` |
| Windows (optional) | `Assets/BuildProfiles/CI-Windows.asset` | Windows x86_64 / `StandaloneWindows64` |
| macOS (optional) | `Assets/BuildProfiles/CI-macOS.asset` | macOS / `StandaloneOSX` |

Install the corresponding Unity build-support modules locally to configure these
profiles. Configure the scenes to build (enabled global scenes, or the profile's
scene-list override), platform settings and player settings, and test each profile
locally. **Commit both `.asset` and `.meta` files**, as well as referenced scenes
and other project assets. The workflow passes the selected profile to GameCI, so
these are actual Unity Build Profiles, not just output names.

All CI builds run on Ubuntu using GameCI Docker images. Optional Windows and macOS
profiles must use the **Mono scripting backend** (not IL2CPP), and Windows must
target **64-bit Intel**. Native platform plugins must support cross-compilation.
macOS artifacts are unsigned/unnotarized; this is not an App Store/signing pipeline.
Configure a native runner separately if your project needs IL2CPP, signing or
platform-specific build tools.

Missing profiles fail the relevant build job with the naming convention and
creation instructions. Unity/GameCI reports invalid profile contents or unavailable
modules during the build. Jobs and workflow runs are serialized to avoid
simultaneous use of the same Personal license in this repository. GitHub keeps at
most one pending run in the concurrency group; a newer run can replace an older
pending run. Avoid concurrent builds using that account in other repositories.

## Triggers and downloads

- **Any pushed tag** builds the targets enabled by repository **Actions variables**
  `UNITY_BUILD_WEB`, `UNITY_BUILD_WINDOWS` and `UNITY_BUILD_MACOS`. Set a variable
  to `TRUE` to enable that target or `FALSE` to disable it (case-insensitive).
  Setup initializes `UNITY_BUILD_WEB` to `TRUE`; Windows and macOS are off unless
  their variables are enabled. Missing variables disable their targets.
- **Actions > Unity builds > Run workflow** offers separate Web, Windows and macOS
  checkboxes (Web on by default, Windows/macOS off, independent of the tag variables).
  GitHub only shows this button once the workflow is on the default branch.
- If no targets are selected or enabled, the build job is skipped.
- Push/merge the profiles and workflow **before** creating and pushing a tag.
  Tags build their tagged commit, not the current default branch.
- Successful jobs upload `Unity-Web`, `Unity-Windows` and/or `Unity-macOS` to the
  workflow run's **Artifacts** section. The macOS artifact is a `.tar.gz`; extract
  it with `tar` to preserve the app's executable permissions. The Web artifact is a build download,
  not an automatic GitHub Pages deployment; serve it with a suitable web server.

No local Unity build or license activation is possible in this repository itself:
it contains the bootstrap script and workflow template, not a Unity project.

## Validation

With Pester 5 installed, run the focused mocked setup tests (no account access,
downloads, Unity Hub interaction, license activation, or secret changes):

```powershell
Invoke-Pester -Path ./assets/Setup.Tests.ps1 -Output Detailed
```