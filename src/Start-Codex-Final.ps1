param(
    [switch]$Doctor,
    [switch]$NoLaunch,
    [switch]$NoKill,
    [switch]$NoConfig,
    [switch]$UpdateConfig,
    [switch]$NoProcessProxyEnv,
    [switch]$NoGlobalGitProxy,
    [ValidateSet("low", "medium", "high", "xhigh")]
    [string]$ReasoningEffort = "medium",
    [string]$ServiceTier = "default",
    [string]$Proxy
)

$ErrorActionPreference = "Stop"

$proxyEnvNames = @(
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WS_PROXY", "WSS_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "all_proxy", "ws_proxy", "wss_proxy", "no_proxy"
)

function Normalize-ProxyEndpoint {
    param(
        [string]$Endpoint,
        [string]$SchemeHint = "http"
    )

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        return $null
    }

    $value = $Endpoint.Trim()
    if ($value -match "^(?<hint>https?|socks5?h?|socks)=(?<rest>.+)$") {
        return Normalize-ProxyEndpoint -Endpoint $Matches.rest -SchemeHint $Matches.hint
    }

    if ($value -match "^(?<scheme>https?|socks5?h?|socks)://(?<userinfo>[^@/]+@)?(?<host>[^/:]+):(?<port>\d+)(/.*)?$") {
        $scheme = $Matches.scheme.ToLowerInvariant()
        if ($scheme -eq "socks") { $scheme = "socks5" }
        $userinfo = [string]$Matches.userinfo
        return ("{0}://{1}{2}:{3}" -f $scheme, $userinfo, $Matches.host, $Matches.port)
    }

    if ($value -match "^(?<host>[^/:=;]+):(?<port>\d+)$") {
        $scheme = $SchemeHint.ToLowerInvariant()
        if ($scheme -eq "socks") { $scheme = "socks5" }
        if ($scheme -notmatch "^(https?|socks5?h?)$") { $scheme = "http" }
        return ("{0}://{1}:{2}" -f $scheme, $Matches.host, $Matches.port)
    }

    return $null
}

function Get-SystemProxyEndpoint {
    $settingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $settings = Get-ItemProperty -Path $settingsPath -ErrorAction SilentlyContinue
    if (-not $settings -or $settings.ProxyEnable -ne 1) {
        return $null
    }

    $proxyServer = [string]$settings.ProxyServer
    if ([string]::IsNullOrWhiteSpace($proxyServer)) {
        return $null
    }

    $entries = @{}
    foreach ($part in ($proxyServer -split ";")) {
        $trimmed = $part.Trim()
        if (-not $trimmed) { continue }

        if ($trimmed -match "^(?<scheme>[^=]+)=(?<endpoint>.+)$") {
            $entries[$Matches.scheme.ToLowerInvariant()] = $Matches.endpoint.Trim()
        } elseif (-not $entries.ContainsKey("default")) {
            $entries["default"] = $trimmed
        }
    }

    foreach ($key in @("https", "http", "default", "socks")) {
        if ($entries.ContainsKey($key)) {
            if ($key -eq "socks") {
                return Normalize-ProxyEndpoint -Endpoint $entries[$key] -SchemeHint "socks5"
            }
            return Normalize-ProxyEndpoint -Endpoint $entries[$key] -SchemeHint "http"
        }
    }

    return $null
}

function Get-WinHttpProxyEndpoint {
    try {
        $output = & netsh winhttp show proxy 2>$null
    } catch {
        return $null
    }

    $text = ($output -join "`n")
    if ($text -match "Direct access") {
        return $null
    }

    if ($text -match "Proxy Server\(s\)\s*:\s*(?<proxy>.+)") {
        foreach ($part in ($Matches.proxy -split ";")) {
            $candidate = Normalize-ProxyEndpoint $part.Trim()
            if ($candidate) { return $candidate }
        }
    }

    return $null
}

function Get-EnvironmentProxyEndpoint {
    $names = @(
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "WSS_PROXY", "WS_PROXY",
        "https_proxy", "http_proxy", "all_proxy", "wss_proxy", "ws_proxy"
    )

    foreach ($name in $names) {
        foreach ($target in @("Process", "User", "Machine")) {
            $candidate = Normalize-ProxyEndpoint ([Environment]::GetEnvironmentVariable($name, $target))
            if ($candidate) { return $candidate }
        }
    }

    return $null
}

function Test-HttpConnectProxy {
    param(
        [string]$Proxy,
        [string]$TargetHost = "chatgpt.com",
        [int]$TargetPort = 443
    )

    $normalized = Normalize-ProxyEndpoint $Proxy
    if (-not $normalized) { return $false }

    try {
        $uri = [Uri]$normalized
    } catch {
        return $false
    }

    if ($uri.Scheme -notin @("http", "https")) {
        return $false
    }

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($uri.Host, $uri.Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(1500)) { return $false }
        $client.EndConnect($async)

        $stream = $client.GetStream()
        $stream.ReadTimeout = 1800
        $stream.WriteTimeout = 1800
        $request = "CONNECT ${TargetHost}:${TargetPort} HTTP/1.1`r`nHost: ${TargetHost}:${TargetPort}`r`nProxy-Connection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)

        $buffer = New-Object byte[] 256
        $count = $stream.Read($buffer, 0, $buffer.Length)
        if ($count -le 0) { return $false }

        $response = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $count)
        return ($response -match "^HTTP/\S+\s+200\b")
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-SocksProxy {
    param([string]$Proxy)

    $normalized = Normalize-ProxyEndpoint $Proxy
    if (-not $normalized) { return $false }

    try {
        $uri = [Uri]$normalized
    } catch {
        return $false
    }

    if ($uri.Scheme -notmatch "^socks") {
        return $false
    }

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($uri.Host, $uri.Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(1500)) { return $false }
        $client.EndConnect($async)

        $stream = $client.GetStream()
        $stream.ReadTimeout = 1800
        $stream.WriteTimeout = 1800
        $hello = [byte[]](0x05, 0x01, 0x00)
        $stream.Write($hello, 0, $hello.Length)
        $reply = New-Object byte[] 2
        $count = $stream.Read($reply, 0, 2)
        return ($count -eq 2 -and $reply[0] -eq 0x05 -and $reply[1] -ne 0xff)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-ProxyEndpoint {
    param([string]$Proxy)

    $normalized = Normalize-ProxyEndpoint $Proxy
    if (-not $normalized) { return $false }

    try {
        $uri = [Uri]$normalized
    } catch {
        return $false
    }

    if ($uri.Scheme -match "^socks") {
        return Test-SocksProxy -Proxy $normalized
    }

    return Test-HttpConnectProxy -Proxy $normalized
}

function Get-ListeningProxyCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]
    $preferredHttpPorts = @(7890, 7891, 7892, 7893, 7897, 7899, 20170, 7688)
    $preferredSocksPorts = @(1080, 10808, 10809)

    foreach ($port in $preferredHttpPorts) {
        [void]$candidates.Add("http://127.0.0.1:$port")
    }
    foreach ($port in $preferredSocksPorts) {
        [void]$candidates.Add("socks5://127.0.0.1:$port")
        [void]$candidates.Add("http://127.0.0.1:$port")
    }

    try {
        $lines = & netstat -ano -p tcp 2>$null
    } catch {
        return $candidates
    }

    $proxyProcessPattern = "clash|mihomo|verge|v2ray|xray|sing|nekoray|hiddify|proxy|vpn|tun|core|surge|loon"
    foreach ($line in $lines) {
        if ($line -notmatch "^\s*TCP\s+(?<host>127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\[::\]):(?<port>\d+)\s+\S+\s+LISTENING\s+(?<pid>\d+)\s*$") {
            continue
        }

        $port = [int]$Matches.port
        if ($port -lt 1024) { continue }

        $processName = ""
        $processPath = ""
        $process = Get-Process -Id ([int]$Matches.pid) -ErrorAction SilentlyContinue
        if ($process) {
            $processName = [string]$process.ProcessName
            try { $processPath = [string]$process.Path } catch { $processPath = "" }
        }

        if (($processName -match $proxyProcessPattern) -or ($processPath -match $proxyProcessPattern) -or ($preferredHttpPorts -contains $port) -or ($preferredSocksPorts -contains $port)) {
            [void]$candidates.Add("http://127.0.0.1:$port")
            [void]$candidates.Add("socks5://127.0.0.1:$port")
        }
    }

    return $candidates
}

function Get-ProxyConfigCandidates {
    $roots = @($env:APPDATA, $env:LOCALAPPDATA, $env:PROGRAMDATA) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $namePattern = "clash|mihomo|verge|v2ray|xray|sing|nekoray|hiddify|proxy|vpn|surge|loon"

    foreach ($root in $roots) {
        $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $namePattern } |
            Select-Object -First 20

        foreach ($dir in $dirs) {
            $files = Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Include "*.yaml", "*.yml", "*.json", "*.toml", "*.ini", "*.conf" -ErrorAction SilentlyContinue |
                Select-Object -First 80

            foreach ($file in $files) {
                try {
                    $config = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                } catch {
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($config)) { continue }

                $patterns = @(
                    @{ Scheme = "http"; Pattern = "(?im)^\s*mixed-port\s*[:=]\s*(?<port>\d+)\s*$" },
                    @{ Scheme = "http"; Pattern = "(?im)^\s*http-port\s*[:=]\s*(?<port>\d+)\s*$" },
                    @{ Scheme = "http"; Pattern = "(?im)^\s*port\s*[:=]\s*(?<port>\d+)\s*$" },
                    @{ Scheme = "socks5"; Pattern = "(?im)^\s*socks-port\s*[:=]\s*(?<port>\d+)\s*$" },
                    @{ Scheme = "http"; Pattern = "(?im)`"mixed-port`"\s*:\s*(?<port>\d+)" },
                    @{ Scheme = "http"; Pattern = "(?im)`"http-port`"\s*:\s*(?<port>\d+)" },
                    @{ Scheme = "http"; Pattern = "(?im)`"port`"\s*:\s*(?<port>\d+)" },
                    @{ Scheme = "socks5"; Pattern = "(?im)`"socks-port`"\s*:\s*(?<port>\d+)" }
                )

                foreach ($entry in $patterns) {
                    foreach ($match in [regex]::Matches($config, $entry.Pattern)) {
                        "{0}://127.0.0.1:{1}" -f $entry.Scheme, $match.Groups["port"].Value
                    }
                }
            }
        }
    }
}

function Resolve-CodexProxyEndpoint {
    param([string]$OverrideProxy)

    $sources = @(
        @{ Name = "manual -Proxy argument"; Value = $OverrideProxy },
        @{ Name = "Windows system proxy (read only)"; Value = (Get-SystemProxyEndpoint) },
        @{ Name = "WinHTTP proxy (read only)"; Value = (Get-WinHttpProxyEndpoint) },
        @{ Name = "existing environment proxy (read only)"; Value = (Get-EnvironmentProxyEndpoint) }
    )

    foreach ($source in $sources) {
        $candidate = Normalize-ProxyEndpoint $source.Value
        if ($candidate -and (Test-ProxyEndpoint $candidate)) {
            Write-Host ("Detected proxy from {0}: {1}" -f $source.Name, $candidate)
            return $candidate
        }
    }

    foreach ($candidate in (Get-ListeningProxyCandidates | Where-Object { $_ } | Select-Object -Unique)) {
        $normalized = Normalize-ProxyEndpoint $candidate
        if ($normalized -and (Test-ProxyEndpoint $normalized)) {
            Write-Host "Detected proxy by local port probing: $normalized"
            return $normalized
        }
    }

    try {
        $configCandidates = Get-ProxyConfigCandidates
    } catch {
        Write-Host "Proxy config scan failed. Continuing."
        $configCandidates = @()
    }

    foreach ($candidate in ($configCandidates | Where-Object { $_ } | Select-Object -Unique)) {
        $normalized = Normalize-ProxyEndpoint $candidate
        if ($normalized -and (Test-ProxyEndpoint $normalized)) {
            Write-Host "Detected proxy from local config: $normalized"
            return $normalized
        }
    }

    return $null
}

function Set-ProcessProxyEnv {
    param([string]$Proxy)

    foreach ($name in $proxyEnvNames) {
        Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    }

    foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WS_PROXY", "WSS_PROXY", "http_proxy", "https_proxy", "all_proxy", "ws_proxy", "wss_proxy")) {
        Set-Item -Path "Env:$name" -Value $Proxy
    }

    foreach ($name in @("NO_PROXY", "no_proxy")) {
        Set-Item -Path "Env:$name" -Value "localhost,127.0.0.1,::1"
    }
}

function Clear-ProcessProxyEnv {
    foreach ($name in $proxyEnvNames) {
        Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    }
}

function Set-GlobalGitProxy {
    param([string]$Proxy)

    $normalized = Normalize-ProxyEndpoint $Proxy
    if (-not $normalized) {
        Write-Host "Git proxy was not updated because the proxy endpoint is invalid."
        return
    }

    $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) {
        $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $git) {
        Write-Host "Git was not found. Skipping global Git proxy update."
        return
    }

    & $git.Source config --global http.proxy $normalized
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set global Git http.proxy."
    }

    & $git.Source config --global https.proxy $normalized
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set global Git https.proxy."
    }

    Write-Host "Updated global Git proxy for Git GUI, command-line git, and IDE git:"
    Write-Host "  http.proxy=$normalized"
    Write-Host "  https.proxy=$normalized"
}

function Get-CodexExe {
    $configPath = Join-Path $env:USERPROFILE ".codex\config.toml"
    if (Test-Path -LiteralPath $configPath) {
        $match = Select-String -LiteralPath $configPath -Pattern "^\s*CODEX_CLI_PATH\s*=\s*'([^']+)'" | Select-Object -First 1
        if ($match -and (Test-Path -LiteralPath $match.Matches[0].Groups[1].Value)) {
            return $match.Matches[0].Groups[1].Value
        }
    }

    $command = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($package) {
        $candidate = Join-Path $package.InstallLocation "app\resources\codex.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Could not find codex.exe."
}

function Get-CodexDesktopExe {
    $packages = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending
    foreach ($package in $packages) {
        try {
            $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
            $manifestExecutable = $manifest.Package.Applications.Application |
                Where-Object { $_.Executable } |
                Select-Object -ExpandProperty Executable -First 1
            if ($manifestExecutable) {
                $relativePath = ([string]$manifestExecutable).Replace("/", "\")
                $candidate = Join-Path $package.InstallLocation $relativePath
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        } catch {
            # Fall back to known desktop entry points below.
        }

        foreach ($relativePath in @("app\Codex.exe", "app\ChatGPT.exe")) {
            $candidate = Join-Path $package.InstallLocation $relativePath
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    $running = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -in @("Codex", "ChatGPT") -and
            $_.MainWindowHandle -ne 0 -and
            $_.Path -and
            $_.Path -notmatch '[\\/]resources[\\/]codex\.exe$' -and
            (Test-Path -LiteralPath $_.Path)
        } |
        Select-Object -First 1
    if ($running) {
        return $running.Path
    }

    return $null
}

function Get-CodexAppUserModelId {
    $packages = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending
    foreach ($package in $packages) {
        try {
            $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
            $application = $manifest.Package.Applications.Application |
                Where-Object { $_.Id -and $_.Executable } |
                Select-Object -First 1
            if ($application) {
                return ("{0}!{1}" -f $package.PackageFamilyName, [string]$application.Id)
            }
        } catch {
            # A direct executable launch remains available as a fallback.
        }
    }

    return $null
}

function Start-CodexPackagedApp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppUserModelId,
        [string[]]$ArgumentList
    )

    if (-not ("CodexLauncher.PackageApplicationActivator" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexLauncher
{
    [ComImport]
    [Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            uint options,
            out uint processId);
    }

    [ComImport]
    [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    internal class ApplicationActivationManager
    {
    }

    public static class PackageApplicationActivator
    {
        public static uint Activate(string appUserModelId, string arguments)
        {
            IApplicationActivationManager manager =
                (IApplicationActivationManager)new ApplicationActivationManager();
            try
            {
                uint processId;
                int result = manager.ActivateApplication(appUserModelId, arguments, 0, out processId);
                if (result < 0)
                {
                    Marshal.ThrowExceptionForHR(result);
                }
                return processId;
            }
            finally
            {
                Marshal.ReleaseComObject(manager);
            }
        }
    }
}
'@
    }

    $arguments = @($ArgumentList | Where-Object { $_ }) -join " "
    return [CodexLauncher.PackageApplicationActivator]::Activate($AppUserModelId, $arguments)
}

function Update-CodexConfig {
    param(
        [string]$ReasoningEffort,
        [string]$ServiceTier
    )

    $configPath = Join-Path $env:USERPROFILE ".codex\config.toml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host "Codex config not found. Skipping config update: $configPath"
        return
    }

    $text = Get-Content -LiteralPath $configPath -Raw
    $original = $text

    if ($text -match '(?m)^model_reasoning_effort\s*=') {
        $text = [regex]::Replace($text, '(?m)^model_reasoning_effort\s*=\s*".*?"\s*$', "model_reasoning_effort = `"$ReasoningEffort`"")
    } elseif ($text -match '(?m)^model\s*=') {
        $text = [regex]::Replace($text, '(?m)^(model\s*=\s*".*?"\s*)$', "`$1`r`nmodel_reasoning_effort = `"$ReasoningEffort`"", 1)
    } else {
        $text = "model_reasoning_effort = `"$ReasoningEffort`"`r`n$text"
    }

    if ($text -match '(?m)^service_tier\s*=') {
        $text = [regex]::Replace($text, '(?m)^service_tier\s*=\s*".*?"\s*$', "service_tier = `"$ServiceTier`"")
    } elseif ($text -match '(?m)^model_reasoning_effort\s*=') {
        $text = [regex]::Replace($text, '(?m)^(model_reasoning_effort\s*=\s*".*?"\s*)$', "`$1`r`nservice_tier = `"$ServiceTier`"", 1)
    } else {
        $text = "service_tier = `"$ServiceTier`"`r`n$text"
    }

    if ($text -ne $original) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        Copy-Item -LiteralPath $configPath -Destination "$configPath.bak-$stamp" -Force
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($configPath, $text, $utf8NoBom)
        Write-Host "Updated Codex config:"
    } else {
        Write-Host "Codex config already matches:"
    }
    Write-Host "  model_reasoning_effort=$ReasoningEffort"
    Write-Host "  service_tier=$ServiceTier"
}

function Stop-CodexProcesses {
    param([string]$DesktopExe)

    $desktopFullPath = $null
    $desktopDirectory = $null
    if ($DesktopExe) {
        try {
            $desktopFullPath = [System.IO.Path]::GetFullPath($DesktopExe)
            $desktopDirectory = [System.IO.Path]::GetDirectoryName($desktopFullPath)
        } catch {
            $desktopFullPath = $null
            $desktopDirectory = $null
        }
    }

    $processes = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $processPath = $null
        try { $processPath = $_.Path } catch { $processPath = $null }
        if (-not $processPath) { return $false }

        if ($desktopFullPath -and $processPath -ieq $desktopFullPath) {
            return $true
        }

        if ($desktopDirectory -and
            [System.IO.Path]::GetDirectoryName($processPath) -ieq $desktopDirectory -and
            [System.IO.Path]::GetFileName($processPath) -in @("Codex.exe", "ChatGPT.exe")) {
            return $true
        }

        return $false
    }

    if (-not $processes) {
        Write-Host "No running Codex process found."
        return
    }

    Write-Host "Stopping existing Codex processes..."
    $processes | ForEach-Object {
        Write-Host ("  {0} pid={1}" -f $_.ProcessName, $_.Id)
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 300
        $processIds = @($processes | Select-Object -ExpandProperty Id)
        $left = Get-Process -Id $processIds -ErrorAction SilentlyContinue
    } while ($left -and (Get-Date) -lt $deadline)
}

function Get-ChromiumProxyArgument {
    param([string]$Proxy)

    $normalized = Normalize-ProxyEndpoint $Proxy
    if (-not $normalized) { return $null }
    return "--proxy-server=$normalized"
}

Write-Host "Codex safe launcher"
Write-Host "  This script does NOT modify Windows system proxy."
Write-Host "  This script does NOT write user proxy environment variables."
Write-Host "  This script updates global Git proxy unless -NoGlobalGitProxy is set."
Write-Host "  Proxy environment variables are set only for this launcher process and the Codex process it starts."
Write-Host ""

Write-Host "Detecting Codex proxy endpoint..."
$proxy = Resolve-CodexProxyEndpoint -OverrideProxy $Proxy
if ([string]::IsNullOrWhiteSpace($proxy)) {
    throw "Could not auto-detect a usable local HTTP/SOCKS proxy. Start your proxy app or pass -Proxy http://127.0.0.1:PORT."
}
Write-Host "Detected proxy: $proxy"

if (-not $NoProcessProxyEnv) {
    Write-Host "Setting proxy for this launcher process and child Codex process..."
    Set-ProcessProxyEnv -Proxy $proxy
    Write-Host "  HTTP_PROXY=$env:HTTP_PROXY"
    Write-Host "  HTTPS_PROXY=$env:HTTPS_PROXY"
    Write-Host "  ALL_PROXY=$env:ALL_PROXY"
    Write-Host "  WSS_PROXY=$env:WSS_PROXY"
    Write-Host "  NO_PROXY=$env:NO_PROXY"
} else {
    Write-Host "NoProcessProxyEnv was set. Clearing proxy environment variables for Codex child processes."
    Clear-ProcessProxyEnv
}

if (-not $NoGlobalGitProxy) {
    Set-GlobalGitProxy -Proxy $proxy
} else {
    Write-Host "NoGlobalGitProxy was set. Skipping global Git proxy update."
}

$shouldUpdateConfig = $UpdateConfig -or
    $PSBoundParameters.ContainsKey("ReasoningEffort") -or
    $PSBoundParameters.ContainsKey("ServiceTier")

if ($NoConfig) {
    $shouldUpdateConfig = $false
}

if ($shouldUpdateConfig) {
    Write-Host "Checking Codex config..."
    Update-CodexConfig -ReasoningEffort $ReasoningEffort -ServiceTier $ServiceTier
} else {
    Write-Host "Skipping Codex config update. Pass -UpdateConfig, -ReasoningEffort, or -ServiceTier to change it."
}

$codexExe = Get-CodexExe
$codexDesktopExe = Get-CodexDesktopExe
$codexAppUserModelId = Get-CodexAppUserModelId

if ($Doctor) {
    Write-Host ""
    Write-Host "Running Codex doctor with process-only proxy..."
    & $codexExe --strict-config doctor --summary
    if ($LASTEXITCODE -ne 0) {
        throw "Codex doctor failed. Check the output above. No system network settings were changed."
    }
    if ($NoProcessProxyEnv) {
        Clear-ProcessProxyEnv
    }
}

if (-not $NoKill) {
    Stop-CodexProcesses -DesktopExe $codexDesktopExe
} else {
    Write-Host "NoKill was set. Existing Codex processes were left running."
    if (-not $NoLaunch) {
        Write-Host "Warning: existing Codex may keep old network settings until it is fully restarted."
    }
}

if ($NoLaunch) {
    Write-Host "NoLaunch was set. Skipping Codex desktop launch."
    exit 0
}

Write-Host ""
Write-Host "Launching Codex desktop app..."
if ($codexDesktopExe) {
    $proxyArg = Get-ChromiumProxyArgument -Proxy $proxy
    $bypassArg = "--proxy-bypass-list=localhost;127.0.0.1;::1;<local>"
    if ($codexAppUserModelId) {
        $desktopProcessId = Start-CodexPackagedApp `
            -AppUserModelId $codexAppUserModelId `
            -ArgumentList @($proxyArg, $bypassArg)
        Write-Host "  AppX: $codexAppUserModelId"
        Write-Host "  Process ID: $desktopProcessId"
    } else {
        Start-Process -FilePath $codexDesktopExe -ArgumentList @($proxyArg, $bypassArg)
        Write-Host "  $codexDesktopExe"
    }
    Write-Host "  $proxyArg"
} else {
    Start-Process -FilePath $codexExe -ArgumentList "app"
    Write-Host "  $codexExe app"
}

Write-Host "Done. If an old thread keeps reconnecting, start a fresh thread after Codex opens."
