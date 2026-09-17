
# PeykLink FTP backup helper.
# Keep in sync with PeykLink.Application.Backup.FtpBackupGuard.
# Never log FTP or ZIP passwords.

$script:PeykLinkMinBackupBytes = 20MB
$script:PeykLinkCurrentBackupFile = "peyklink-backup.zip"
$script:PeykLinkPreviousBackupFile = "peyklink-backup-previous.zip"
$script:PeykLinkLocalBackupZip = "C:\peyklink-backup.zip"
$script:PeykLinkExtractPath = "C:\PeykLinkMongoBackup"
$script:PeykLinkValidateExtractPath = "C:\PeykLinkBackupValidate"
$script:PeykLinkCliSessionsDest = "C:\PeykLinkCliSessions"
$script:FtpUriStyle = $null
$script:FtpCurlConfig = $null

function Get-PeykLinkBackupSizeMb([long]$Bytes) {
    return "{0:N2}" -f ($Bytes / 1MB)
}

function Get-PeykLinkPreviousBackupFileName([string]$CurrentFileName) {
    if ([string]::IsNullOrWhiteSpace($CurrentFileName)) {
        return $script:PeykLinkPreviousBackupFile
    }
    $ext = [System.IO.Path]::GetExtension($CurrentFileName)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($CurrentFileName)
    if ($stem.EndsWith("-previous", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $CurrentFileName
    }
    return ($stem + "-previous" + $ext)
}

function Initialize-PeykLinkFtpSettings {
    if ([string]::IsNullOrWhiteSpace($Env:FTP_HOST) -or $Env:FTP_HOST -eq "2193182619.cloudydl.com" -or $Env:FTP_HOST -eq "linkpeyk.ir") {
        $Env:FTP_HOST = "ftp.linkpeyk.ir"
    }
    if ([string]::IsNullOrWhiteSpace($Env:FTP_PORT)) {
        $Env:FTP_PORT = "21"
    }
    if ([string]::IsNullOrWhiteSpace($Env:FTP_USERNAME) -or $Env:FTP_USERNAME -eq "pz25177") {
        $Env:FTP_USERNAME = "xuljpwea"
    }
    if ([string]::IsNullOrWhiteSpace($Env:FTP_PASSWORD)) {
        throw "FTP_PASSWORD GitHub Secret is not configured."
    }
    if ([string]::IsNullOrWhiteSpace($Env:FTP_REMOTE_DIRECTORY) -or $Env:FTP_REMOTE_DIRECTORY -match "pz25177|parspack|public_html/peyklink") {
        $Env:FTP_REMOTE_DIRECTORY = "/backupdb/linkpeyk"
    }
    if ([string]::IsNullOrWhiteSpace($Env:FTP_REMOTE_FILE)) {
        $Env:FTP_REMOTE_FILE = $script:PeykLinkCurrentBackupFile
    }

    $remoteDir = $Env:FTP_REMOTE_DIRECTORY.Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($remoteDir) -or $remoteDir -eq "/" -or $remoteDir -eq "/peyklink" -or $remoteDir -match "pz25177|parspack|public_html/peyklink") {
        $remoteDir = "/backupdb/linkpeyk"
    }
    else {
        if (-not $remoteDir.StartsWith("/")) {
            $remoteDir = "/" + $remoteDir
        }
        $remoteDir = $remoteDir.TrimEnd("/")
    }

    $remoteFile = $Env:FTP_REMOTE_FILE.Trim()
    if ([string]::IsNullOrWhiteSpace($remoteFile)) {
        $remoteFile = $script:PeykLinkCurrentBackupFile
    }

    $script:PeykLinkCurrentBackupFile = $remoteFile
    $script:PeykLinkPreviousBackupFile = Get-PeykLinkPreviousBackupFileName $remoteFile
    $script:PeykLinkRemoteDirectory = $remoteDir

    Write-Host "FTP host : $($Env:FTP_HOST)"
    Write-Host "FTP dir  : $script:PeykLinkRemoteDirectory"
    Write-Host "Current  : $script:PeykLinkCurrentBackupFile"
    Write-Host "Previous : $script:PeykLinkPreviousBackupFile"
    Write-Host "Must match bot upload path Backup.Ftp.RemoteDirectory/RemoteFileName"
}

function Get-PeykLinkFtpUris([string]$RemotePath) {
    $rel = "ftp://$($Env:FTP_HOST):$($Env:FTP_PORT)$RemotePath"
    $abs = "ftp://$($Env:FTP_HOST):$($Env:FTP_PORT)/%2F$($RemotePath.TrimStart('/'))"
    if ($script:FtpUriStyle -eq "absolute") { return @($abs, $rel) }
    return @($rel, $abs)
}

function Get-PeykLinkRemotePath([string]$FileName) {
    return "$script:PeykLinkRemoteDirectory/$FileName"
}

function New-PeykLinkFtpCurlConfig {
    if ($null -ne $script:FtpCurlConfig -and (Test-Path $script:FtpCurlConfig)) {
        return $script:FtpCurlConfig
    }
    $script:FtpCurlConfig = Join-Path $env:TEMP ("peyklink-ftp-" + [guid]::NewGuid().ToString("N") + ".conf")
    "user = `"$($Env:FTP_USERNAME):$($Env:FTP_PASSWORD)`"" |
        Set-Content -Path $script:FtpCurlConfig -Encoding ascii
    return $script:FtpCurlConfig
}

function Remove-PeykLinkFtpCurlConfig {
    if ($null -ne $script:FtpCurlConfig -and (Test-Path $script:FtpCurlConfig)) {
        Remove-Item $script:FtpCurlConfig -Force -ErrorAction SilentlyContinue
    }
    $script:FtpCurlConfig = $null
}

function New-PeykLinkFtpRequest([string]$Uri, [string]$Method) {
    $request = [System.Net.FtpWebRequest]::Create($Uri)
    $request.Credentials = New-Object System.Net.NetworkCredential($Env:FTP_USERNAME, $Env:FTP_PASSWORD)
    $request.Method = $Method
    $request.UsePassive = $true
    $request.UseBinary = $true
    $request.KeepAlive = $false
    $request.EnableSsl = $false
    $request.Timeout = 180000
    $request.ReadWriteTimeout = 180000
    return $request
}

function Test-PeykLinkFtpFileExists([string]$FileName) {
    $remotePath = Get-PeykLinkRemotePath $FileName
    foreach ($uri in (Get-PeykLinkFtpUris $remotePath)) {
        try {
            $request = New-PeykLinkFtpRequest $uri ([System.Net.WebRequestMethods+Ftp]::GetFileSize)
            $response = $request.GetResponse()
            $response.Close()
            if ($uri -like "*%2F*") { $script:FtpUriStyle = "absolute" } else { $script:FtpUriStyle = "relative" }
            return $true
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match "550|not found|cannot find|File unavailable") {
                continue
            }
        }
    }
    return $false
}

function Get-PeykLinkFtpFileSize([string]$FileName) {
    $remotePath = Get-PeykLinkRemotePath $FileName
    foreach ($uri in (Get-PeykLinkFtpUris $remotePath)) {
        try {
            $request = New-PeykLinkFtpRequest $uri ([System.Net.WebRequestMethods+Ftp]::GetFileSize)
            $response = $request.GetResponse()
            $size = [long]$response.ContentLength
            $response.Close()
            if ($size -ge 0) {
                if ($uri -like "*%2F*") { $script:FtpUriStyle = "absolute" } else { $script:FtpUriStyle = "relative" }
                return $size
            }
        }
        catch {
            # try next uri / fallback
        }
    }

    $cfg = New-PeykLinkFtpCurlConfig
    foreach ($uri in (Get-PeykLinkFtpUris $remotePath)) {
        try {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $head = & curl.exe --config $cfg --silent --show-error --head --connect-timeout 30 --ftp-pasv $uri 2>$null
            $ErrorActionPreference = $prev
            if ($LASTEXITCODE -eq 0 -and $head) {
                $line = @($head) | Where-Object { $_ -match "^(Content-Length|content-length):" } | Select-Object -First 1
                if ($line -match ":\s*(\d+)") {
                    if ($uri -like "*%2F*") { $script:FtpUriStyle = "absolute" } else { $script:FtpUriStyle = "relative" }
                    return [long]$Matches[1]
                }
            }
        }
        catch {
            # next fallback
        }
    }

    return $null
}

function Invoke-PeykLinkFtpDownload {
    param(
        [string]$FileName,
        [string]$OutFile
    )
    $remotePath = Get-PeykLinkRemotePath $FileName
    $cfg = New-PeykLinkFtpCurlConfig
    if (Test-Path $OutFile) {
        Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    }

    $uris = Get-PeykLinkFtpUris $remotePath
    $exitCode = 1
    foreach ($uri in $uris) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & curl.exe `
            --config $cfg `
            --show-error `
            --fail `
            --connect-timeout 30 `
            --ftp-pasv `
            -o $OutFile `
            $uri
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($exitCode -eq 0 -and (Test-Path $OutFile)) {
            if ($uri -like "*%2F*") { $script:FtpUriStyle = "absolute" } else { $script:FtpUriStyle = "relative" }
            return $true
        }
        if (Test-Path $OutFile) {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
        }
        Write-Host "FTP download failed for $FileName (curl $exitCode). Trying next URI..." -ForegroundColor Yellow
    }
    return $false
}

function Invoke-PeykLinkFtpUpload {
    param(
        [string]$LocalFile,
        [string]$FileName
    )
    $remotePath = Get-PeykLinkRemotePath $FileName
    $cfg = New-PeykLinkFtpCurlConfig
    $uris = Get-PeykLinkFtpUris $remotePath
    $exitCode = 1
    foreach ($uri in $uris) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & curl.exe `
            --config $cfg `
            --show-error `
            --fail `
            --connect-timeout 30 `
            --retry 3 `
            --retry-delay 5 `
            --ftp-pasv `
            --ftp-create-dirs `
            -T $LocalFile `
            $uri
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($exitCode -eq 0) {
            if ($uri -like "*%2F*") { $script:FtpUriStyle = "absolute" } else { $script:FtpUriStyle = "relative" }
            return $true
        }
        Write-Host "FTP upload failed for $FileName (curl $exitCode). Trying next URI..." -ForegroundColor Yellow
    }
    return $false
}

function Invoke-PeykLinkFtpDelete([string]$FileName) {
    $remotePath = Get-PeykLinkRemotePath $FileName
    foreach ($uri in (Get-PeykLinkFtpUris $remotePath)) {
        try {
            $request = New-PeykLinkFtpRequest $uri ([System.Net.WebRequestMethods+Ftp]::DeleteFile)
            $response = $request.GetResponse()
            $response.Close()
            if ($uri -like "*%2F*") { $script:FtpUriStyle = "absolute" } else { $script:FtpUriStyle = "relative" }
            return $true
        }
        catch {
            # try next
        }
    }
    return $false
}

function Invoke-PeykLinkFtpRename {
    param(
        [string]$FromFileName,
        [string]$ToFileName
    )
    $fromPath = Get-PeykLinkRemotePath $FromFileName
    foreach ($uri in (Get-PeykLinkFtpUris $fromPath)) {
        try {
            $request = New-PeykLinkFtpRequest $uri ([System.Net.WebRequestMethods+Ftp]::Rename)
            $request.RenameTo = $ToFileName
            $response = $request.GetResponse()
            $response.Close()
            if ($uri -like "*%2F*") { $script:FtpUriStyle = "absolute" } else { $script:FtpUriStyle = "relative" }
            Write-Host "FTP rename: $FromFileName -> $ToFileName"
            return $true
        }
        catch {
            $err = $_.Exception.Message
            Write-Host "FTP rename via FtpWebRequest failed for $FromFileName -> $ToFileName : $err" -ForegroundColor Yellow
        }
    }

    $cfg = New-PeykLinkFtpCurlConfig
    $fromRemote = Get-PeykLinkRemotePath $FromFileName
    $toRemote = Get-PeykLinkRemotePath $ToFileName
    $baseUris = Get-PeykLinkFtpUris ($script:PeykLinkRemoteDirectory + "/")
    foreach ($uri in $baseUris) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & curl.exe `
            --config $cfg `
            --silent `
            --show-error `
            --ftp-pasv `
            -Q "RNFR $fromRemote" `
            -Q "RNTO $toRemote" `
            $uri
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -eq 0) {
            Write-Host "FTP rename (curl): $FromFileName -> $ToFileName"
            return $true
        }
    }
    throw "FTP rename failed: $FromFileName -> $ToFileName"
}

function Get-PeykLinkSevenZip {
    $paths = @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe"
    )
    foreach ($path in $paths) {
        if (Test-Path $path) { return $path }
    }

    Write-Host "7-Zip not found. Installing 7-Zip..."
    winget install --id 7zip.7zip --exact --silent --accept-package-agreements --accept-source-agreements
    Start-Sleep -Seconds 5
    foreach ($path in $paths) {
        if (Test-Path $path) { return $path }
    }
    throw "7-Zip installation failed."
}

function Clear-PeykLinkDirectory([string]$Path) {
    if (Test-Path $Path) {
        Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restore-PeykLinkCliSessionsFromExtract {
    param(
        [string]$ExtractPath,
        [string]$SevenZip
    )
    $dest = $script:PeykLinkCliSessionsDest
    if (Test-Path $dest) {
        Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    }

    $cliZip = Get-ChildItem $ExtractPath -Recurse -Filter "peyklink-cli-sessions.zip" -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $cliZip) {
        Write-Host "No peyklink-cli-sessions.zip in selected backup (older backup or first run)."
        return
    }

    Write-Host "Restoring CLI session files from the selected backup..."
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    & $SevenZip x $cliZip.FullName "-o$dest" "-y"
    Write-Host "CLI sessions staged at $dest"
}

function Test-PeykLinkBackupArchive {
    param(
        [string]$ZipPath,
        [string]$ExtractPath,
        [switch]$RestoreCliSessions
    )

    $result = [ordered]@{
        Valid     = $false
        Reason    = "unknown"
        SizeBytes = 0
        SizeMb    = "0.00"
        SevenZip  = "FAIL"
        Bson      = "FAIL"
        BsonCount = 0
    }

    if (!(Test-Path $ZipPath)) {
        $result.Reason = "file missing"
        return [pscustomobject]$result
    }

    $size = [long](Get-Item $ZipPath).Length
    $result.SizeBytes = $size
    $result.SizeMb = Get-PeykLinkBackupSizeMb $size
    Write-Host ("Local backup size: {0} bytes ({1} MB)" -f $size, $result.SizeMb)

    if ($size -lt $script:PeykLinkMinBackupBytes) {
        $result.Reason = "Size below 20 MB"
        Write-Host "INVALID BACKUP: Size below 20 MB." -ForegroundColor Yellow
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($Env:BACKUP_PASSWORD)) {
        throw "BACKUP_PASSWORD GitHub Secret is not configured."
    }

    $sevenZip = Get-PeykLinkSevenZip
    Write-Host "Testing ZIP archive..."
    & $sevenZip t $ZipPath "-p$Env:BACKUP_PASSWORD"
    if ($LASTEXITCODE -ne 0) {
        $result.Reason = "7z test failed"
        Write-Host "INVALID BACKUP: 7-Zip archive test failed." -ForegroundColor Yellow
        return [pscustomobject]$result
    }
    $result.SevenZip = "PASS"
    Write-Host "ZIP archive test passed." -ForegroundColor Green

    Clear-PeykLinkDirectory $ExtractPath
    New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null
    Write-Host "Extracting backup with 7-Zip..."
    & $sevenZip x $ZipPath "-o$ExtractPath" "-p$Env:BACKUP_PASSWORD" "-y"
    if ($LASTEXITCODE -ne 0) {
        $result.Reason = "extraction failed"
        Clear-PeykLinkDirectory $ExtractPath
        Write-Host "INVALID BACKUP: archive extraction failed." -ForegroundColor Yellow
        return [pscustomobject]$result
    }

    $bsonFiles = @(Get-ChildItem $ExtractPath -Recurse -Filter "*.bson" -File -ErrorAction SilentlyContinue)
    $result.BsonCount = $bsonFiles.Count
    if ($bsonFiles.Count -eq 0) {
        $result.Reason = "BSON missing"
        Clear-PeykLinkDirectory $ExtractPath
        Write-Host "INVALID BACKUP: MongoDB BSON files are missing." -ForegroundColor Yellow
        return [pscustomobject]$result
    }

    $result.Bson = "PASS"
    $result.Valid = $true
    $result.Reason = "valid"
    Write-Host ("BSON files found: {0}" -f $bsonFiles.Count) -ForegroundColor Green

    if ($RestoreCliSessions) {
        Restore-PeykLinkCliSessionsFromExtract -ExtractPath $ExtractPath -SevenZip $sevenZip
    }

    return [pscustomobject]$result
}

function Get-PeykLinkFtpBackupProbe([string]$Label, [string]$FileName) {
    $report = [ordered]@{
        Label     = $Label
        FileName  = $FileName
        Exists    = $false
        SizeBytes = 0
        SizeMb    = "n/a"
        Valid     = $false
        Reason    = "missing"
        SevenZip  = "n/a"
        Bson      = "n/a"
    }
    if (-not (Test-PeykLinkFtpFileExists $FileName)) {
        return [pscustomobject]$report
    }
    $report.Exists = $true
    $size = Get-PeykLinkFtpFileSize $FileName
    if ($null -ne $size) {
        $report.SizeBytes = [long]$size
        $report.SizeMb = Get-PeykLinkBackupSizeMb ([long]$size)
    }
    $report.Reason = "not fully validated this run (current restore selected)"
    return [pscustomobject]$report
}

function Import-PeykLinkBackupCandidate {
    param(
        [string]$Label,
        [string]$FileName
    )

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ("Trying {0} backup: {1}" -f $Label.ToUpper(), $FileName) -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    $report = [ordered]@{
        Label     = $Label
        FileName  = $FileName
        Exists    = $false
        SizeBytes = 0
        SizeMb    = "n/a"
        Valid     = $false
        Reason    = "missing"
        SevenZip  = "n/a"
        Bson      = "n/a"
    }

    $downloaded = Invoke-PeykLinkFtpDownload -FileName $FileName -OutFile $script:PeykLinkLocalBackupZip
    if (-not $downloaded -or !(Test-Path $script:PeykLinkLocalBackupZip)) {
        $report.Reason = "file missing"
        Write-Host ("{0} backup is missing on FTP." -f $Label) -ForegroundColor Yellow
        return [pscustomobject]$report
    }

    $report.Exists = $true
    $archive = Test-PeykLinkBackupArchive `
        -ZipPath $script:PeykLinkLocalBackupZip `
        -ExtractPath $script:PeykLinkExtractPath `
        -RestoreCliSessions
    $report.SizeBytes = $archive.SizeBytes
    $report.SizeMb = $archive.SizeMb
    $report.SevenZip = $archive.SevenZip
    $report.Bson = $archive.Bson
    $report.Valid = $archive.Valid
    $report.Reason = $archive.Reason

    if (-not $archive.Valid) {
        Write-Host ("{0} backup = invalid ({1}). Local copy will be deleted. FTP file is not deleted." -f $Label, $archive.Reason) -ForegroundColor Yellow
        if (Test-Path $script:PeykLinkLocalBackupZip) {
            Remove-Item $script:PeykLinkLocalBackupZip -Force -ErrorAction SilentlyContinue
        }
        Clear-PeykLinkDirectory $script:PeykLinkExtractPath
        if (Test-Path $script:PeykLinkCliSessionsDest) {
            Remove-Item $script:PeykLinkCliSessionsDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]$report
}

function Write-PeykLinkRestoreDecisionLog {
    param($Current, $Previous, $SelectedSource)
    $currentValidText = if ($Current.Valid) { "true" } else { "false" }
    $previousValidText = if ($Previous.Valid) {
        "true"
    }
    elseif ($Previous.Reason -like "*not fully validated*") {
        "n/a (not tested this run)"
    }
    else {
        "false"
    }
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "BACKUP RECOVERY" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "FTP current backup:"
    Write-Host ("Exists: {0}" -f ($(if ($Current.Exists) { "true" } else { "false" })))
    Write-Host ("Size: {0} MB" -f $Current.SizeMb)
    Write-Host ("Valid: {0}" -f $currentValidText)
    if (-not $Current.Valid) {
        Write-Host ("Reason: {0}" -f $Current.Reason)
    }
    Write-Host ""
    Write-Host "FTP previous backup:"
    Write-Host ("Exists: {0}" -f ($(if ($Previous.Exists) { "true" } else { "false" })))
    Write-Host ("Size: {0} MB" -f $Previous.SizeMb)
    Write-Host ("Valid: {0}" -f $previousValidText)
    if (-not $Previous.Valid) {
        Write-Host ("Reason: {0}" -f $Previous.Reason)
    }
    Write-Host ""
    $selectedText = switch ($SelectedSource) {
        "current" { "CURRENT" }
        "previous" { "PREVIOUS" }
        default { "NONE" }
    }
    Write-Host ("Selected restore source: {0}" -f $selectedText)
}

function Set-PeykLinkBackupGithubEnv {
    param(
        [hashtable]$Values
    )
    foreach ($key in $Values.Keys) {
        $raw = [string]$Values[$key]
        $safe = $raw.Replace("`r", " ").Replace("`n", " ")
        Add-Content -Path $Env:GITHUB_ENV -Value ("{0}={1}" -f $key, $safe)
    }
}

function Select-PeykLinkRestoreBackup {
    Initialize-PeykLinkFtpSettings

    $current = Import-PeykLinkBackupCandidate -Label "current" -FileName $script:PeykLinkCurrentBackupFile
    $previous = $null
    $source = "none"
    $restoreFile = ""

    if ($current.Valid) {
        $source = "current"
        $restoreFile = $script:PeykLinkCurrentBackupFile
        $previous = Get-PeykLinkFtpBackupProbe -Label "previous" -FileName $script:PeykLinkPreviousBackupFile
    }
    else {
        $previous = Import-PeykLinkBackupCandidate -Label "previous" -FileName $script:PeykLinkPreviousBackupFile
        if ($previous.Valid) {
            $source = "previous"
            $restoreFile = $script:PeykLinkPreviousBackupFile
        }
    }

    Write-PeykLinkRestoreDecisionLog -Current $current -Previous $previous -SelectedSource $source

    $found = $source -ne "none"
    Set-PeykLinkBackupGithubEnv @{
        BACKUP_FOUND            = ($(if ($found) { "true" } else { "false" }))
        BACKUP_SOURCE           = $source
        BACKUP_RESTORE_FILE     = $restoreFile
        BACKUP_CURRENT_EXISTS   = ($(if ($current.Exists) { "true" } else { "false" }))
        BACKUP_CURRENT_SIZE_MB  = $current.SizeMb
        BACKUP_CURRENT_VALID    = ($(if ($current.Valid) { "true" } else { "false" }))
        BACKUP_CURRENT_REASON   = $current.Reason
        BACKUP_PREVIOUS_EXISTS  = ($(if ($previous.Exists) { "true" } else { "false" }))
        BACKUP_PREVIOUS_SIZE_MB = $previous.SizeMb
        BACKUP_PREVIOUS_VALID   = ($(if ($previous.Valid) { "true" } else { "false" }))
        BACKUP_PREVIOUS_REASON  = $previous.Reason
    }

    if ($source -eq "current") {
        Write-Host "MongoDB will be restored from CURRENT backup." -ForegroundColor Green
    }
    elseif ($source -eq "previous") {
        Write-Host "MongoDB will be restored from PREVIOUS backup." -ForegroundColor Yellow
        Write-Host "Reason: current backup invalid"
    }
    else {
        Write-Host "No valid backup available on FTP." -ForegroundColor Yellow
        Write-Host "Starting with empty MongoDB." -ForegroundColor Yellow
        Write-Host "WARNING: No valid backup available on FTP" -ForegroundColor Yellow
    }

    return [pscustomobject]@{
        Source     = $source
        RestoreFile = $restoreFile
        Found      = $found
        Current    = $current
        Previous   = $previous
    }
}

function Publish-PeykLinkBackupToFtp {
    param(
        [string]$LocalZip
    )

    Initialize-PeykLinkFtpSettings
    if (!(Test-Path $LocalZip)) {
        throw "Local backup zip was not found: $LocalZip"
    }

    $archive = Test-PeykLinkBackupArchive -ZipPath $LocalZip -ExtractPath $script:PeykLinkValidateExtractPath
    Write-Host ""
    Write-Host "New local backup:"
    Write-Host ("Size: {0} MB" -f $archive.SizeMb)
    Write-Host ("7z test: {0}" -f $archive.SevenZip)
    Write-Host ("BSON validation: {0}" -f $archive.Bson)

    if (-not $archive.Valid) {
        Write-Host "New backup rejected" -ForegroundColor Red
        Write-Host ("Reason: {0}" -f $archive.Reason)
        Write-Host "Previous FTP backup preserved"
        Write-Host "DO NOT TOUCH FTP CURRENT BACKUP"
        Write-Host "DO NOT DELETE CURRENT BACKUP"
        Write-Host "DO NOT DELETE PREVIOUS BACKUP"
        throw ("New backup rejected: {0}. Previous FTP backup preserved." -f $archive.Reason)
    }

    Clear-PeykLinkDirectory $script:PeykLinkValidateExtractPath

    $runId = $Env:GITHUB_RUN_ID
    if ([string]::IsNullOrWhiteSpace($runId)) {
        $runId = [guid]::NewGuid().ToString("N")
    }
    $uploadingName = "{0}.{1}.uploading" -f $script:PeykLinkCurrentBackupFile, $runId
    $rotatingName = "{0}.rotating" -f $script:PeykLinkPreviousBackupFile
    $localSize = [long](Get-Item $LocalZip).Length

    Write-Host ("Uploading new backup to temporary FTP file: {0}" -f $uploadingName)
    $uploaded = Invoke-PeykLinkFtpUpload -LocalFile $LocalZip -FileName $uploadingName
    if (-not $uploaded) {
        Write-Host "FTP upload: Verified: FAIL"
        [void](Invoke-PeykLinkFtpDelete $uploadingName)
        throw "FTP upload failed. Current and previous backups were not changed."
    }

    $remoteSize = $null
    $verified = $false
    for ($attempt = 0; $attempt -lt 5 -and -not $verified; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 2 }
        $remoteSize = Get-PeykLinkFtpFileSize $uploadingName
        $verified = ($null -ne $remoteSize -and [long]$remoteSize -eq $localSize)
    }
    Write-Host "FTP upload:"
    Write-Host ("Local size: {0}" -f $localSize)
    Write-Host ("Remote size: {0}" -f ($(if ($null -eq $remoteSize) { "unknown" } else { $remoteSize })))
    Write-Host ("Verified: {0}" -f ($(if ($verified) { "PASS" } else { "FAIL" })))

    if (-not $verified) {
        [void](Invoke-PeykLinkFtpDelete $uploadingName)
        throw "FTP upload rejected: remote size does not match local size. Current and previous backups were not changed."
    }

    $currentToPrevious = "SKIP"
    $newToCurrent = "FAIL"
    try {
        $previousExists = Test-PeykLinkFtpFileExists $script:PeykLinkPreviousBackupFile
        $currentExists = Test-PeykLinkFtpFileExists $script:PeykLinkCurrentBackupFile

        if ($previousExists) {
            if (Test-PeykLinkFtpFileExists $rotatingName) {
                [void](Invoke-PeykLinkFtpDelete $rotatingName)
            }
            Invoke-PeykLinkFtpRename -FromFileName $script:PeykLinkPreviousBackupFile -ToFileName $rotatingName
        }

        if ($currentExists) {
            try {
                Invoke-PeykLinkFtpRename -FromFileName $script:PeykLinkCurrentBackupFile -ToFileName $script:PeykLinkPreviousBackupFile
                $currentToPrevious = "SUCCESS"
            }
            catch {
                if (Test-PeykLinkFtpFileExists $rotatingName) {
                    Invoke-PeykLinkFtpRename -FromFileName $rotatingName -ToFileName $script:PeykLinkPreviousBackupFile
                }
                throw
            }
        }

        try {
            Invoke-PeykLinkFtpRename -FromFileName $uploadingName -ToFileName $script:PeykLinkCurrentBackupFile
            $newToCurrent = "SUCCESS"
        }
        catch {
            if ((Test-PeykLinkFtpFileExists $script:PeykLinkPreviousBackupFile) -and -not (Test-PeykLinkFtpFileExists $script:PeykLinkCurrentBackupFile)) {
                Invoke-PeykLinkFtpRename -FromFileName $script:PeykLinkPreviousBackupFile -ToFileName $script:PeykLinkCurrentBackupFile
            }
            if ((Test-PeykLinkFtpFileExists $rotatingName) -and -not (Test-PeykLinkFtpFileExists $script:PeykLinkPreviousBackupFile)) {
                Invoke-PeykLinkFtpRename -FromFileName $rotatingName -ToFileName $script:PeykLinkPreviousBackupFile
            }
            throw
        }

        if (Test-PeykLinkFtpFileExists $rotatingName) {
            [void](Invoke-PeykLinkFtpDelete $rotatingName)
        }
    }
    catch {
        Write-Host ("FTP rotation: Current -> Previous: {0}" -f $currentToPrevious)
        Write-Host ("FTP rotation: New -> Current: {0}" -f $newToCurrent)
        [void](Invoke-PeykLinkFtpDelete $uploadingName)
        throw ("FTP rotation failed. Last known good backup was preserved if possible. {0}" -f $_.Exception.Message)
    }

    Write-Host ("FTP rotation: Current -> Previous: {0}" -f $currentToPrevious)
    Write-Host ("FTP rotation: New -> Current: {0}" -f $newToCurrent) -ForegroundColor Green

    return [pscustomobject]@{
        LocalSize            = $localSize
        RemoteSize           = [long]$remoteSize
        Verified             = "PASS"
        SevenZip             = $archive.SevenZip
        Bson                 = $archive.Bson
        BsonCount            = $archive.BsonCount
        CurrentToPrevious    = $currentToPrevious
        NewToCurrent         = $newToCurrent
        RemotePath           = (Get-PeykLinkRemotePath $script:PeykLinkCurrentBackupFile)
        PreviousRemotePath   = (Get-PeykLinkRemotePath $script:PeykLinkPreviousBackupFile)
    }
}

function Clear-PeykLinkLocalBackupArtifacts {
    if (Test-Path $script:PeykLinkLocalBackupZip) {
        Remove-Item $script:PeykLinkLocalBackupZip -Force -ErrorAction SilentlyContinue
    }
    Clear-PeykLinkDirectory $script:PeykLinkExtractPath
    Clear-PeykLinkDirectory $script:PeykLinkValidateExtractPath
    Get-ChildItem "C:\" -Filter "*.uploading" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
