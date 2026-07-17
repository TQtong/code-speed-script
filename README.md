# Start-Codex-Final Licensed Launcher

This repository contains the source files used to build a protected Start-Codex-Final launcher and a GUI license-code generator.

## Contents

- `src/Start-Codex-Final.ps1` - Codex launcher script.
- `src/Start-Codex-Final.cmd` - Windows command wrapper for the launcher script.
- `packager/Build-DynamicLicensedCodexLauncher.ps1` - Builds the dynamically licensed customer EXE.
- `packager/StartCodexLicenseGeneratorGui.cs` - Source for the self-contained GUI license generator.
- `packager/Build-ProtectedCodexLauncher.ps1` - Older fixed-code protected build script.

## Current Behavior

- The launcher detects a usable local proxy for Codex.
- Proxy environment variables are set only for the launcher process and the Codex process it starts.
- The launcher does not modify Windows system proxy settings.
- The launcher does not write user or machine proxy environment variables.
- The launcher updates global Git proxy settings by default so Git GUI, command-line git, and IDE git can push and pull through the detected proxy.
- Pass `-NoGlobalGitProxy` to skip the global Git proxy update.
- Codex config is not modified unless `-UpdateConfig`, `-ReasoningEffort`, or `-ServiceTier` is passed.
- The customer EXE saves a valid authorization code under the current user's local app data folder after the first successful activation.
- Run the customer EXE with `--clear-license` to remove the saved authorization code and activate again.

## Build Notes

The final deliverables are two standalone executables under `outputs/`: the customer launcher and the license generator. Authorization-code TXT files may be kept separately when useful.

Important: the license generator contains the private signing key and must only be kept by the issuer. Give customers only the launcher EXE plus their authorization code. The build-time XML key is retained as a backup and must not be distributed or committed.

## Typical Build

```powershell
powershell -ExecutionPolicy Bypass -File .\packager\Build-DynamicLicensedCodexLauncher.ps1 `
  -CmdPath .\src\Start-Codex-Final.cmd `
  -Ps1Path .\src\Start-Codex-Final.ps1 `
  -OutputExe .\outputs\Start-Codex-Final-Licensed.exe `
  -LicenseGeneratorPath .\outputs\StartCodexLicenseGenerator.exe `
  -PrivateKeyPath .\work\secrets\Start-Codex-Final-LicensePrivateKey.xml `
  -WorkingDirectory .\packager\dynamic-build
```
