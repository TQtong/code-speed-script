# Start-Codex-Final Licensed Launcher

This repository contains the source files used to build a protected Start-Codex-Final launcher and a GUI license-code generator.

## Contents

- `src/Start-Codex-Final.ps1` - Codex launcher script.
- `src/Start-Codex-Final.cmd` - Windows command wrapper for the launcher script.
- `packager/Build-DynamicLicensedCodexLauncher.ps1` - Builds the dynamically licensed customer EXE.
- `packager/StartCodexLicenseGeneratorGui.cs` - Source for the GUI license generator.
- `packager/Build-ProtectedCodexLauncher.ps1` - Older fixed-code protected build script.

## Current Behavior

- The launcher detects a usable local proxy for Codex.
- Proxy environment variables are set only for the launcher process and the Codex process it starts.
- The launcher does not modify Windows system proxy settings.
- The launcher does not write user or machine proxy environment variables.
- The launcher updates global Git proxy settings by default so Git GUI, command-line git, and IDE git can push and pull through the detected proxy.
- Pass `-NoGlobalGitProxy` to skip the global Git proxy update.
- Codex config is not modified unless `-UpdateConfig`, `-ReasoningEffort`, or `-ServiceTier` is passed.

## Build Notes

The build process generates files under `outputs/`, including customer EXEs, license tools, authorization codes, and the private signing key. Those generated files are intentionally ignored by Git.

Important: `Start-Codex-Final-LicensePrivateKey.xml` is the private license-signing key. Do not commit it, even to a private repository. Store it separately in a secure backup location.

## Typical Build

```powershell
powershell -ExecutionPolicy Bypass -File .\packager\Build-DynamicLicensedCodexLauncher.ps1 `
  -CmdPath .\src\Start-Codex-Final.cmd `
  -Ps1Path .\src\Start-Codex-Final.ps1 `
  -OutputExe .\outputs\Start-Codex-Final-Licensed.exe `
  -LicenseGeneratorPath .\outputs\New-StartCodexLicense.ps1 `
  -PrivateKeyPath .\outputs\Start-Codex-Final-LicensePrivateKey.xml `
  -WorkingDirectory .\packager\dynamic-build
```
