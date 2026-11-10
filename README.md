# autosetup-unity-cicd

One PowerShell script sets up [GameCI](https://game.ci/) builds for an existing
GitHub-hosted Unity project. Only download `Setup-UnityCI.ps1`; it fetches the
workflow from this public repository's `assets/` directory itself.

## Prerequisites

- Windows, PowerShell 5.1+, Git, and an interactive desktop; no administrator
  privileges are needed. An existing `gh` is used, otherwise the official Windows
  portable ZIP is downloaded, SHA-256 checked against its release manifest, and
  removed after setup. GitHub login remains in GitHub CLI's normal credential store.
- Unity **6 (6000.x)** and the current standalone **Unity CLI** (`unity`) already
  installed in your user account. Follow
  [Unity's CLI installation instructions](https://github.com/Unity-Technologies/skills/blob/main/skills/unity-cli/SKILL.md#install-the-cli-if-not-already-installed),
  review the installer, then reopen PowerShell so `unity` is on PATH. The CLI is
  distinct from the Unity Editor executable; do not pass `Unity.exe` as the CLI.
  The Editor version is read from `ProjectSettings/ProjectVersion.txt`.
  The Unity project must be the Git repository
  root, with an initial commit already pushed to GitHub.
- A **free Unity Personal** account eligible under Unity's terms, and repository
  admin access to set Actions secrets. GitHub Actions must be enabled and permitted
  to run the actions in the template. The selected Unity version must have GameCI
  Docker images for your target platforms.

## Run setup

Place the script in the **Unity project root**, open PowerShell there, and run:

```powershell
.\Setup-UnityCI.ps1
```

For a custom CLI installation or license location:

```powershell
.\Setup-UnityCI.ps1 -UnityCli 'C:\tools\unity.exe' -LicensePath 'C:\path\Unity_lic.ulf'
```

1. Complete `gh auth login` in your browser. The script requests repository and
   workflow permissions. Remove `GH_TOKEN`/`GITHUB_TOKEN` from the shell if they
   prevent interactive login.
2. Verify the displayed repository and default branch and read Unity's linked
   license terms, then type `YES` to consent to Personal activation and repository
   changes. Setup warns before replacing an existing `unity-build.yml`.
3. Complete the interactive browser login started by `unity auth login`. The
   script then runs `unity license activate --personal --accept-eula` and verifies
   activation using `unity license status`. Use a human Personal account, not a
   service account. CLI and Hub sign-in can be separate.
4. The resulting `C:\ProgramData\Unity\Unity_lic.ulf` is uploaded using
   `gh secret set UNITY_LICENSE` through standard input. Enter the **same Unity
   account's** email and password at the hidden `gh secret set UNITY_EMAIL` and
   `gh secret set UNITY_PASSWORD` prompts. These are repository Actions secrets,
   not environment secrets. No credentials are passed in command-line arguments,
   written into the project, or printed by the script. Do not run with a transcript
   or debug tracing enabled.
5. The script commits `.github/workflows/unity-build.yml` **directly to the remote
   default branch** using `gh api`. Pull that commit locally before pushing your
   profiles/tags. Setup never commits your local project changes. Protected branches
   or organization policies may reject this API write; in that case, add the
   `assets/unity-build.yml` template at that path through your normal PR process.
   Secrets already uploaded remain set if a later step fails; rerunning replaces
   them and asks again before replacing the workflow.

`-AssetRef <tag-or-commit>` selects a trusted revision of this setup repository
instead of `main`. Review the downloaded script/template before granting access.

### Personal licensing limitation

The standalone CLI supports interactive browser sign-in and Personal activation;
see [Unity's authentication/licensing reference](https://github.com/Unity-Technologies/skills/blob/main/skills/unity-cli/references/auth-license-cloud.md).
There is **no supported headless Personal activation using just Editor
`-username`/`-password` flags**. Local activation does not guarantee that a
reusable legacy `.ulf` is produced. This setup uses
[GameCI's Personal activation instructions](https://github.com/game-ci/documentation/blob/main/docs/03-github/02-activation.mdx):
activate locally, then provide the legacy `.ulf` and account credentials to CI.
An `.alf` is only an activation **request**, not a license.

Some CLI/Hub/account combinations only expose newer token-based licensing and do
not produce a GameCI-compatible `.ulf`. The script checks the license's legacy
`DeveloperData` Personal serial and stops before uploading secrets if incompatible.
Try **Unity Hub > Preferences > Licenses > Add > Get a free personal license** or
supply an existing valid Personal `.ulf` with `-LicensePath` if available. The script
cannot manufacture a license or bypass Unity licensing. If activation requires
elevation on your machine, have the existing Unity installation configured by its
administrator first; the script never elevates. Unity sign-in/2FA or licensing
policy changes can still require manual intervention during CI.

## Required Build Profiles

In Unity 6, use **File > Build Profiles**, add the appropriate platform profile,
and save it with the following **exact, case-sensitive asset path and name**:

| Build | Profile asset | Unity platform / GameCI target |
| --- | --- | --- |
| Web (always built) | `Assets/BuildProfiles/CI-Web.asset` | Web / `WebGL` |
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

- **Any pushed tag** runs the Web build. To also build desktop targets on tags,
  create repository **Actions variables** `UNITY_BUILD_WINDOWS` and/or
  `UNITY_BUILD_MACOS` with the exact value `true`.
- **Actions > Unity builds > Run workflow** always builds Web and offers separate
  Windows/macOS checkboxes (off by default, independent of the tag variables).
  GitHub only shows this button once the workflow is on the default branch.
- Push/merge the profiles and workflow **before** creating and pushing a tag.
  Tags build their tagged commit, not the current default branch.
- Successful jobs upload `Unity-Web`, `Unity-Windows` and/or `Unity-macOS` to the
  workflow run's **Artifacts** section. The Web artifact is a build download,
  not an automatic GitHub Pages deployment; serve it with a suitable web server.

No local Unity build or license activation is possible in this repository itself:
it contains the bootstrap script and workflow template, not a Unity project.

## Validation

With Pester 5 installed, run the focused mocked setup tests (no account access,
downloads, license activation, or secret changes):

```powershell
Invoke-Pester -Path ./assets/Setup.Tests.ps1 -Output Detailed
```