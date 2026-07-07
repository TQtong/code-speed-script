param(
    [Parameter(Mandatory = $true)]
    [string]$CmdPath,

    [Parameter(Mandatory = $true)]
    [string]$Ps1Path,

    [Parameter(Mandatory = $true)]
    [string]$OutputExe,

    [Parameter(Mandatory = $true)]
    [string]$OutputAuthCode,

    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory
)

$ErrorActionPreference = "Stop"

function New-AuthorizationCode {
    $bytes = New-Object byte[] 18
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

    $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    $chars = foreach ($b in $bytes) {
        $alphabet[$b % $alphabet.Length]
    }
    $raw = -join $chars
    return "CODEX-" + ($raw.Substring(0, 6)) + "-" + ($raw.Substring(6, 6)) + "-" + ($raw.Substring(12, 6))
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
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($OutputAuthCode)) | Out-Null
New-Item -ItemType Directory -Force -Path $WorkingDirectory | Out-Null

$authCode = New-AuthorizationCode
$iterations = 200000
$magic = "CODEX-PROTECTED-PAYLOAD-v1"

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

$salt = New-Object byte[] 32
$iv = New-Object byte[] 16
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)
} finally {
    $rng.Dispose()
}

$derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($authCode, $salt, $iterations)
$aes = [System.Security.Cryptography.Aes]::Create()
$cipherStream = New-Object System.IO.MemoryStream
try {
    $aes.KeySize = 256
    $aes.BlockSize = 128
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $derive.GetBytes(32)
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
    $derive.Dispose()
    $cipherStream.Dispose()
}

$saltArgs = ConvertTo-CSharpBase64Args -Bytes $salt
$ivArgs = ConvertTo-CSharpBase64Args -Bytes $iv
$cipherArgs = ConvertTo-CSharpBase64Args -Bytes $cipherBytes
$sourcePath = Join-Path $WorkingDirectory "ProtectedCodexLauncher.cs"

$sourceTemplate = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;

internal static class ProtectedCodexLauncher
{
    private const int Iterations = __ITERATIONS__;
    private const string Magic = "__MAGIC__";
    private const string MainScriptName = "Start-Codex-Final.ps1";

    private static readonly byte[] Salt = FromBase64(
        __SALT_ARGS__
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
            else
            {
                forwardedArgs.Add(args[i]);
            }
        }

        Console.OutputEncoding = Encoding.UTF8;
        Console.WriteLine("Start-Codex-Final protected launcher");
        Console.Write("Authorization code: ");
        string authCode = ReadSecret();

        string extractionDirectory = null;
        try
        {
            extractionDirectory = ExtractPayload(authCode);

            if (verifyOnly)
            {
                Console.WriteLine("Package verified successfully.");
                return 0;
            }

            int exitCode = RunPowerShellScript(extractionDirectory, forwardedArgs);
            if (!noPause && Environment.UserInteractive && !Console.IsInputRedirected)
            {
                Console.WriteLine();
                Console.Write("Press any key to close...");
                Console.ReadKey(true);
                Console.WriteLine();
            }
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

    private static string ReadSecret()
    {
        if (Console.IsInputRedirected)
        {
            return Console.ReadLine();
        }

        StringBuilder builder = new StringBuilder();
        while (true)
        {
            ConsoleKeyInfo key = Console.ReadKey(true);
            if (key.Key == ConsoleKey.Enter)
            {
                Console.WriteLine();
                break;
            }
            if (key.Key == ConsoleKey.Backspace)
            {
                if (builder.Length > 0)
                {
                    builder.Length--;
                    Console.Write("\b \b");
                }
                continue;
            }
            if (!Char.IsControl(key.KeyChar))
            {
                builder.Append(key.KeyChar);
                Console.Write("*");
            }
        }

        return builder.ToString();
    }

    private static string ExtractPayload(string authCode)
    {
        byte[] plainBytes = Decrypt(authCode);
        string tempRoot = Path.Combine(Path.GetTempPath(), "StartCodexFinal_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        string rootFullPath = Path.GetFullPath(tempRoot);

        using (MemoryStream stream = new MemoryStream(plainBytes))
        using (BinaryReader reader = new BinaryReader(stream, Encoding.UTF8))
        {
            string magic = reader.ReadString();
            if (!String.Equals(magic, Magic, StringComparison.Ordinal))
            {
                throw new InvalidDataException("Invalid authorization code.");
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

    private static byte[] Decrypt(string authCode)
    {
        if (String.IsNullOrEmpty(authCode))
        {
            throw new InvalidDataException("Authorization code is empty.");
        }

        using (Rfc2898DeriveBytes derive = new Rfc2898DeriveBytes(authCode, Salt, Iterations))
        using (AesManaged aes = new AesManaged())
        {
            aes.KeySize = 256;
            aes.BlockSize = 128;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            aes.Key = derive.GetBytes(32);
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
        if (value == null)
        {
            return "\"\"";
        }
        if (value.Length == 0)
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

    private static byte[] FromBase64(params string[] chunks)
    {
        return Convert.FromBase64String(String.Concat(chunks));
    }
}
'@

$source = $sourceTemplate.
    Replace("__ITERATIONS__", [string]$iterations).
    Replace("__MAGIC__", $magic).
    Replace("__SALT_ARGS__", $saltArgs).
    Replace("__IV_ARGS__", $ivArgs).
    Replace("__CIPHER_ARGS__", $cipherArgs)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($sourcePath, $source, $utf8NoBom)

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

$authText = @"
Authorization code for Start-Codex-Final-Protected.exe

$authCode

Keep this code private. The EXE decrypts its embedded scripts only after this code is entered.
"@
[System.IO.File]::WriteAllText($OutputAuthCode, $authText, $utf8NoBom)

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputExe).Hash
[PSCustomObject]@{
    Exe = $OutputExe
    AuthCodeFile = $OutputAuthCode
    AuthCode = $authCode
    Sha256 = $hash
}
