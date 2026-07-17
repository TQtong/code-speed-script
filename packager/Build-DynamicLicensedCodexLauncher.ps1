param(
    [Parameter(Mandatory = $true)]
    [string]$CmdPath,

    [Parameter(Mandatory = $true)]
    [string]$Ps1Path,

    [Parameter(Mandatory = $true)]
    [string]$OutputExe,

    [Parameter(Mandatory = $true)]
    [string]$LicenseGeneratorPath,

    [Parameter(Mandatory = $true)]
    [string]$PrivateKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory
)

$ErrorActionPreference = "Stop"

function New-RsaProvider {
    $csp = New-Object System.Security.Cryptography.CspParameters
    $csp.ProviderType = 24
    $csp.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider -ArgumentList 2048, $csp
    $rsa.PersistKeyInCsp = $false
    return $rsa
}

function ConvertTo-CSharpBase64Args {
    param([byte[]]$Bytes)

    $base64 = [Convert]::ToBase64String($Bytes)
    $chunks = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $base64.Length; $i += 3600) {
        $length = [Math]::Min(3600, $base64.Length - $i)
        [void]$chunks.Add('"' + $base64.Substring($i, $length) + '"')
    }
    return ($chunks -join ",`r`n        ")
}

function ConvertTo-CSharpStringLiteral {
    param([string]$Value)

    return '@"' + ($Value -replace '"', '""') + '"'
}

function Write-PayloadFile {
    param(
        [System.IO.BinaryWriter]$Writer,
        [string]$FilePath
    )

    $name = [System.IO.Path]::GetFileName($FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $Writer.Write($name)
    $Writer.Write([int]$bytes.Length)
    $Writer.Write($bytes)
}

if (-not (Test-Path -LiteralPath $CmdPath)) {
    throw "Missing CMD file: $CmdPath"
}
if (-not (Test-Path -LiteralPath $Ps1Path)) {
    throw "Missing PS1 file: $Ps1Path"
}

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($OutputExe)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($LicenseGeneratorPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($PrivateKeyPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $WorkingDirectory | Out-Null

$rsa = New-RsaProvider
try {
    if (Test-Path -LiteralPath $PrivateKeyPath) {
        $rsa.FromXmlString([System.IO.File]::ReadAllText($PrivateKeyPath))
    } else {
        $privateXml = $rsa.ToXmlString($true)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($PrivateKeyPath, $privateXml, $utf8NoBom)
    }
    $publicXml = $rsa.ToXmlString($false)
} finally {
    $rsa.Dispose()
}

$magic = "CODEX-DYNAMIC-LICENSED-PAYLOAD-v1"
$productName = "Start-Codex-Final"

$plainStream = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($plainStream, [System.Text.Encoding]::UTF8)
try {
    $writer.Write($magic)
    $writer.Write([int]2)
    Write-PayloadFile -Writer $writer -FilePath $CmdPath
    Write-PayloadFile -Writer $writer -FilePath $Ps1Path
    $writer.Flush()
    $plainBytes = $plainStream.ToArray()
} finally {
    $writer.Dispose()
    $plainStream.Dispose()
}

$contentKey = New-Object byte[] 32
$keyMask = New-Object byte[] 32
$iv = New-Object byte[] 16
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $rng.GetBytes($contentKey)
    $rng.GetBytes($keyMask)
    $rng.GetBytes($iv)
} finally {
    $rng.Dispose()
}

$maskedKey = New-Object byte[] $contentKey.Length
for ($i = 0; $i -lt $contentKey.Length; $i++) {
    $maskedKey[$i] = $contentKey[$i] -bxor $keyMask[$i]
}

$aes = [System.Security.Cryptography.Aes]::Create()
$cipherStream = New-Object System.IO.MemoryStream
try {
    $aes.KeySize = 256
    $aes.BlockSize = 128
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $contentKey
    $aes.IV = $iv

    $cryptoStream = New-Object System.Security.Cryptography.CryptoStream(
        $cipherStream,
        $aes.CreateEncryptor(),
        [System.Security.Cryptography.CryptoStreamMode]::Write
    )
    try {
        $cryptoStream.Write($plainBytes, 0, $plainBytes.Length)
        $cryptoStream.FlushFinalBlock()
        $cipherBytes = $cipherStream.ToArray()
    } finally {
        $cryptoStream.Dispose()
    }
} finally {
    $aes.Dispose()
    $cipherStream.Dispose()
}

$maskedKeyArgs = ConvertTo-CSharpBase64Args -Bytes $maskedKey
$keyMaskArgs = ConvertTo-CSharpBase64Args -Bytes $keyMask
$ivArgs = ConvertTo-CSharpBase64Args -Bytes $iv
$cipherArgs = ConvertTo-CSharpBase64Args -Bytes $cipherBytes
$publicKeyLiteral = ConvertTo-CSharpStringLiteral -Value $publicXml
$sourcePath = Join-Path $WorkingDirectory "DynamicLicensedCodexLauncher.cs"

$sourceTemplate = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

internal static class DynamicLicensedCodexLauncher
{
    private const string ProductName = "__PRODUCT_NAME__";
    private const string Magic = "__MAGIC__";
    private const string MainScriptName = "Start-Codex-Final.ps1";
    private const string LicenseDirectoryName = "Start-Codex-Final";
    private const string LicenseFileName = "license.txt";
    private const string PublicKeyXml = __PUBLIC_KEY_XML__;

    private static readonly byte[] MaskedKey = FromBase64(
        __MASKED_KEY_ARGS__
    );

    private static readonly byte[] KeyMask = FromBase64(
        __KEY_MASK_ARGS__
    );

    private static readonly byte[] Iv = FromBase64(
        __IV_ARGS__
    );

    private static readonly byte[] CipherText = FromBase64(
        __CIPHER_ARGS__
    );

    private static int Main(string[] args)
    {
        bool verifyOnly = false;
        bool noPause = false;
        bool showMachineId = false;
        bool clearLicense = false;
        List<string> forwardedArgs = new List<string>();

        for (int i = 0; i < args.Length; i++)
        {
            if (String.Equals(args[i], "--codex-package-verify", StringComparison.OrdinalIgnoreCase))
            {
                verifyOnly = true;
            }
            else if (String.Equals(args[i], "--codex-package-no-pause", StringComparison.OrdinalIgnoreCase))
            {
                noPause = true;
            }
            else if (String.Equals(args[i], "--show-machine-id", StringComparison.OrdinalIgnoreCase))
            {
                showMachineId = true;
            }
            else if (String.Equals(args[i], "--clear-license", StringComparison.OrdinalIgnoreCase))
            {
                clearLicense = true;
            }
            else
            {
                forwardedArgs.Add(args[i]);
            }
        }

        Console.OutputEncoding = Encoding.UTF8;

        if (showMachineId)
        {
            Console.WriteLine(GetMachineId());
            return 0;
        }

        if (clearLicense)
        {
            DeleteSavedLicense();
            Console.WriteLine("Saved authorization code was cleared.");
            return 0;
        }

        Console.WriteLine("Start-Codex-Final licensed launcher");
        Console.WriteLine("Machine ID: " + GetMachineId());

        string extractionDirectory = null;
        try
        {
            string licenseCode = GetUsableLicenseCode();
            Dictionary<string, string> claims = ValidateLicense(licenseCode);
            SaveLicenseCode(licenseCode);
            PrintLicenseSummary(claims);

            extractionDirectory = ExtractPayload();

            if (verifyOnly)
            {
                Console.WriteLine("Package verified successfully.");
                return 0;
            }

            int exitCode = RunPowerShellScript(extractionDirectory, forwardedArgs);
            return exitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine();
            Console.Error.WriteLine("Authorization failed or package could not be opened.");
            Console.Error.WriteLine(ex.Message);
            if (!noPause && Environment.UserInteractive && !Console.IsInputRedirected)
            {
                Console.Error.Write("Press any key to close...");
                Console.ReadKey(true);
                Console.Error.WriteLine();
            }
            return 1;
        }
        finally
        {
            if (!String.IsNullOrEmpty(extractionDirectory))
            {
                TryDeleteDirectory(extractionDirectory);
            }
        }
    }

    private static string GetUsableLicenseCode()
    {
        string savedLicense = LoadSavedLicense();
        if (!String.IsNullOrWhiteSpace(savedLicense))
        {
            try
            {
                ValidateLicense(savedLicense);
                Console.WriteLine("Using saved authorization code.");
                return savedLicense.Trim();
            }
            catch (Exception ex)
            {
                Console.WriteLine("Saved authorization code is no longer valid: " + ex.Message);
                DeleteSavedLicense();
            }
        }

        Console.Write("Authorization code: ");
        string enteredLicense = Console.ReadLine();
        if (String.IsNullOrWhiteSpace(enteredLicense))
        {
            throw new InvalidDataException("Authorization code is empty.");
        }
        return enteredLicense.Trim();
    }

    private static string GetLicensePath()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (String.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Path.GetTempPath();
        }
        return Path.Combine(localAppData, LicenseDirectoryName, LicenseFileName);
    }

    private static string LoadSavedLicense()
    {
        string path = GetLicensePath();
        try
        {
            if (File.Exists(path))
            {
                return File.ReadAllText(path, Encoding.UTF8).Trim();
            }
        }
        catch
        {
        }
        return "";
    }

    private static void SaveLicenseCode(string licenseCode)
    {
        try
        {
            string path = GetLicensePath();
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, licenseCode.Trim(), Encoding.UTF8);
        }
        catch
        {
            Console.WriteLine("Warning: authorization code could not be saved for next launch.");
        }
    }

    private static void DeleteSavedLicense()
    {
        try
        {
            string path = GetLicensePath();
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }

    private static Dictionary<string, string> ValidateLicense(string licenseCode)
    {
        if (String.IsNullOrWhiteSpace(licenseCode))
        {
            throw new InvalidDataException("Authorization code is empty.");
        }

        string normalized = licenseCode.Trim().Replace(" ", "").Replace("\r", "").Replace("\n", "");
        string[] parts = normalized.Split('.');
        if (parts.Length != 3 || !String.Equals(parts[0], "SCF1", StringComparison.Ordinal))
        {
            throw new InvalidDataException("Authorization code format is invalid.");
        }

        byte[] payloadBytes = Base64UrlDecode(parts[1]);
        byte[] signatureBytes = Base64UrlDecode(parts[2]);

        CspParameters csp = new CspParameters();
        csp.ProviderType = 24;
        csp.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider";
        using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider(csp))
        {
            rsa.PersistKeyInCsp = false;
            rsa.FromXmlString(PublicKeyXml);
            bool ok = rsa.VerifyData(payloadBytes, CryptoConfig.MapNameToOID("SHA256"), signatureBytes);
            if (!ok)
            {
                throw new InvalidDataException("Authorization code signature is invalid.");
            }
        }

        string payload = Encoding.UTF8.GetString(payloadBytes);
        Dictionary<string, string> claims = ParseClaims(payload);

        string product;
        if (!claims.TryGetValue("product", out product) || !String.Equals(product, ProductName, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Authorization code is for a different product.");
        }

        string expiresUtc;
        if (claims.TryGetValue("expiresUtc", out expiresUtc) && !String.IsNullOrWhiteSpace(expiresUtc))
        {
            DateTime expires = ParseUtc(expiresUtc);
            if (DateTime.UtcNow > expires)
            {
                throw new InvalidDataException("Authorization code has expired.");
            }
        }

        string machineId;
        if (claims.TryGetValue("machineId", out machineId) && !String.IsNullOrWhiteSpace(machineId) && !String.Equals(machineId, "ANY", StringComparison.OrdinalIgnoreCase))
        {
            if (!String.Equals(machineId.Trim(), GetMachineId(), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Authorization code is not valid for this machine.");
            }
        }

        return claims;
    }

    private static Dictionary<string, string> ParseClaims(string payload)
    {
        Dictionary<string, string> claims = new Dictionary<string, string>(StringComparer.Ordinal);
        string[] lines = payload.Replace("\r\n", "\n").Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i];
            if (String.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            int equals = line.IndexOf('=');
            if (equals <= 0)
            {
                throw new InvalidDataException("Authorization code payload is invalid.");
            }
            string key = line.Substring(0, equals);
            string value = line.Substring(equals + 1);
            claims[key] = value;
        }
        return claims;
    }

    private static DateTime ParseUtc(string value)
    {
        DateTime result;
        string[] formats = new string[] { "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd" };
        if (!DateTime.TryParseExact(value, formats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out result))
        {
            throw new InvalidDataException("Authorization expiry date is invalid.");
        }
        return result.ToUniversalTime();
    }

    private static void PrintLicenseSummary(Dictionary<string, string> claims)
    {
        string customer;
        string licenseId;
        string expiresUtc;

        if (claims.TryGetValue("customer", out customer) && !String.IsNullOrWhiteSpace(customer))
        {
            Console.WriteLine("Authorized customer: " + customer);
        }
        if (claims.TryGetValue("licenseId", out licenseId) && !String.IsNullOrWhiteSpace(licenseId))
        {
            Console.WriteLine("License ID: " + licenseId);
        }
        if (claims.TryGetValue("expiresUtc", out expiresUtc) && !String.IsNullOrWhiteSpace(expiresUtc))
        {
            Console.WriteLine("Expires UTC: " + expiresUtc);
        }
    }

    private static string ExtractPayload()
    {
        byte[] plainBytes = DecryptPayload();
        string tempRoot = Path.Combine(Path.GetTempPath(), "StartCodexFinal_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        string rootFullPath = Path.GetFullPath(tempRoot);

        using (MemoryStream stream = new MemoryStream(plainBytes))
        using (BinaryReader reader = new BinaryReader(stream, Encoding.UTF8))
        {
            string magic = reader.ReadString();
            if (!String.Equals(magic, Magic, StringComparison.Ordinal))
            {
                throw new InvalidDataException("Protected package is invalid.");
            }

            int fileCount = reader.ReadInt32();
            if (fileCount < 1 || fileCount > 20)
            {
                throw new InvalidDataException("Invalid package layout.");
            }

            for (int i = 0; i < fileCount; i++)
            {
                string name = reader.ReadString();
                int length = reader.ReadInt32();
                if (length < 0 || length > 10 * 1024 * 1024)
                {
                    throw new InvalidDataException("Invalid packaged file length.");
                }

                byte[] contents = reader.ReadBytes(length);
                if (contents.Length != length)
                {
                    throw new InvalidDataException("Packaged file is incomplete.");
                }

                string destination = Path.GetFullPath(Path.Combine(tempRoot, name));
                if (!destination.StartsWith(rootFullPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("Invalid packaged file path.");
                }

                File.WriteAllBytes(destination, contents);
            }
        }

        string mainScript = Path.Combine(tempRoot, MainScriptName);
        if (!File.Exists(mainScript))
        {
            throw new FileNotFoundException("Main script was not extracted.", mainScript);
        }

        return tempRoot;
    }

    private static byte[] DecryptPayload()
    {
        byte[] key = GetContentKey();
        using (AesManaged aes = new AesManaged())
        {
            aes.KeySize = 256;
            aes.BlockSize = 128;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            aes.Key = key;
            aes.IV = Iv;

            using (MemoryStream input = new MemoryStream(CipherText))
            using (CryptoStream crypto = new CryptoStream(input, aes.CreateDecryptor(), CryptoStreamMode.Read))
            using (MemoryStream output = new MemoryStream())
            {
                crypto.CopyTo(output);
                return output.ToArray();
            }
        }
    }

    private static byte[] GetContentKey()
    {
        if (MaskedKey.Length != KeyMask.Length)
        {
            throw new InvalidDataException("Protected package key is invalid.");
        }

        byte[] key = new byte[MaskedKey.Length];
        for (int i = 0; i < MaskedKey.Length; i++)
        {
            key[i] = (byte)(MaskedKey[i] ^ KeyMask[i]);
        }
        return key;
    }

    private static int RunPowerShellScript(string extractionDirectory, List<string> forwardedArgs)
    {
        string scriptPath = Path.Combine(extractionDirectory, MainScriptName);
        StringBuilder arguments = new StringBuilder();
        arguments.Append("-NoProfile -ExecutionPolicy Bypass -File ");
        arguments.Append(QuoteArgument(scriptPath));
        foreach (string argument in forwardedArgs)
        {
            arguments.Append(' ');
            arguments.Append(QuoteArgument(argument));
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = "powershell.exe";
        startInfo.Arguments = arguments.ToString();
        startInfo.WorkingDirectory = extractionDirectory;
        startInfo.UseShellExecute = false;

        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static string QuoteArgument(string value)
    {
        if (value == null || value.Length == 0)
        {
            return "\"\"";
        }

        bool needsQuotes = false;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (Char.IsWhiteSpace(c) || c == '"')
            {
                needsQuotes = true;
                break;
            }
        }

        if (!needsQuotes)
        {
            return value;
        }

        StringBuilder result = new StringBuilder();
        result.Append('"');
        int backslashes = 0;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\\')
            {
                backslashes++;
            }
            else if (c == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
            }
            else
            {
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(c);
            }
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static string GetMachineId()
    {
        string machineGuid = "";
        try
        {
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography"))
            {
                if (key != null)
                {
                    object value = key.GetValue("MachineGuid");
                    if (value != null)
                    {
                        machineGuid = Convert.ToString(value, CultureInfo.InvariantCulture);
                    }
                }
            }
        }
        catch
        {
            machineGuid = "";
        }

        string raw = String.IsNullOrWhiteSpace(machineGuid)
            ? ("fallback|" + Environment.MachineName + "|" + Environment.UserName)
            : ("machine-guid|" + machineGuid);

        using (SHA256 sha = SHA256.Create())
        {
            byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(raw));
            StringBuilder builder = new StringBuilder();
            for (int i = 0; i < hash.Length; i++)
            {
                builder.Append(hash[i].ToString("X2", CultureInfo.InvariantCulture));
            }
            return builder.ToString().Substring(0, 24);
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, true);
            }
        }
        catch
        {
            // Temporary extraction cleanup is best effort.
        }
    }

    private static byte[] Base64UrlDecode(string value)
    {
        string padded = value.Replace('-', '+').Replace('_', '/');
        switch (padded.Length % 4)
        {
            case 0:
                break;
            case 2:
                padded += "==";
                break;
            case 3:
                padded += "=";
                break;
            default:
                throw new FormatException("Invalid base64url value.");
        }
        return Convert.FromBase64String(padded);
    }

    private static byte[] FromBase64(params string[] chunks)
    {
        return Convert.FromBase64String(String.Concat(chunks));
    }
}
'@

$source = $sourceTemplate.
    Replace("__PRODUCT_NAME__", $productName).
    Replace("__MAGIC__", $magic).
    Replace("__PUBLIC_KEY_XML__", $publicKeyLiteral).
    Replace("__MASKED_KEY_ARGS__", $maskedKeyArgs).
    Replace("__KEY_MASK_ARGS__", $keyMaskArgs).
    Replace("__IV_ARGS__", $ivArgs).
    Replace("__CIPHER_ARGS__", $cipherArgs)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($sourcePath, $source, $utf8NoBom)

$generatorTemplate = @'
param(
    [Parameter(Mandatory = $true)]
    [string]$Customer,

    [string]$MachineId = "ANY",

    [int]$Days = 0,

    [datetime]$Expires,

    [switch]$NoExpiry,

    [string]$OutFile
)

$ErrorActionPreference = "Stop"

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function New-RsaProvider {
    $csp = New-Object System.Security.Cryptography.CspParameters
    $csp.ProviderType = 24
    $csp.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider -ArgumentList 2048, $csp
    $rsa.PersistKeyInCsp = $false
    return $rsa
}

$privateKeyPath = Join-Path $PSScriptRoot "__PRIVATE_KEY_FILE_NAME__"
if (-not (Test-Path -LiteralPath $privateKeyPath)) {
    throw "Private key file not found: $privateKeyPath"
}

if ($NoExpiry) {
    $expiresUtc = ""
} elseif ($PSBoundParameters.ContainsKey("Expires")) {
    $expiresUtc = $Expires.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
} elseif ($Days -gt 0) {
    $expiresUtc = ([DateTime]::UtcNow.AddDays($Days)).ToString("yyyy-MM-ddTHH:mm:ssZ")
} else {
    $expiresUtc = ""
}

if ([string]::IsNullOrWhiteSpace($MachineId)) {
    $MachineId = "ANY"
}

$licenseId = ([Guid]::NewGuid().ToString("N")).Substring(0, 16).ToUpperInvariant()
$issuedUtc = ([DateTime]::UtcNow).ToString("yyyy-MM-ddTHH:mm:ssZ")

$payload = @(
    "product=__PRODUCT_NAME__",
    "licenseId=$licenseId",
    "customer=$Customer",
    "issuedUtc=$issuedUtc",
    "expiresUtc=$expiresUtc",
    "machineId=$($MachineId.Trim().ToUpperInvariant())"
) -join "`n"

$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$rsa = New-RsaProvider
try {
    $rsa.FromXmlString([System.IO.File]::ReadAllText($privateKeyPath))
    $signature = $rsa.SignData($payloadBytes, [System.Security.Cryptography.CryptoConfig]::MapNameToOID("SHA256"))
} finally {
    $rsa.Dispose()
}

$licenseCode = "SCF1." + (ConvertTo-Base64Url $payloadBytes) + "." + (ConvertTo-Base64Url $signature)

$result = @"
Customer: $Customer
LicenseId: $licenseId
IssuedUtc: $issuedUtc
ExpiresUtc: $expiresUtc
MachineId: $($MachineId.Trim().ToUpperInvariant())

AuthorizationCode:
$licenseCode
"@

if ($OutFile) {
    $parent = Split-Path -Parent $OutFile
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $result, $utf8NoBom)
}

$result
'@

$privateKeyFileName = [System.IO.Path]::GetFileName($PrivateKeyPath)
$generator = $generatorTemplate.
    Replace("__PRIVATE_KEY_FILE_NAME__", $privateKeyFileName).
    Replace("__PRODUCT_NAME__", $productName)
[System.IO.File]::WriteAllText($LicenseGeneratorPath, $generator, $utf8NoBom)

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw "Could not find .NET Framework csc.exe."
}

& $csc /nologo /target:exe /platform:anycpu /optimize+ /out:$OutputExe $sourcePath
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE"
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputExe).Hash
[PSCustomObject]@{
    Exe = $OutputExe
    LicenseGenerator = $LicenseGeneratorPath
    PrivateKey = $PrivateKeyPath
    Sha256 = $hash
}
