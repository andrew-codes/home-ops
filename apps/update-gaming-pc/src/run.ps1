function UpdateNVIDIADriver {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$Clean
    )

    # Helper function for consistent logging
    function Write-Log {
        param($Message)

        $timestamp = Get-Date -Format 'HH:mm:ss'
        $logMessage = "${timestamp}: $Message"

        # Write to console
        Write-Host $logMessage

        # Write to log file
        $LogDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $LogFile = Join-Path $LogDir 'log.txt'
        Add-Content -Path $LogFile -Value $logMessage
    }

    # Function to detect NVIDIA GPU or prompt user to select one
    function Get-NvidiaGpuInfo {
        try {
            # Try CIM first
            $CimGpuInfo = Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -match "NVIDIA" }
            if ($CimGpuInfo) {
                Write-Log "Detected GPU using CIM: $($CimGpuInfo.Name)"
                return @{ Name = $CimGpuInfo.Name; ParentID = $null; Value = $null }
            }

            # If CIM fails, try WMI
            $WmiGpuInfo = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -match "NVIDIA" }
            if ($WmiGpuInfo) {
                Write-Log "Detected GPU using WMI: $($WmiGpuInfo.Name)"
                return @{ Name = $WmiGpuInfo.Name; ParentID = $null; Value = $null }
            }

            # If both fail, try to read GPU name from config file
            Write-Log "Unable to automatically detect an NVIDIA GPU. Checking config file..."

            $ConfigDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
            $ConfigPath = Join-Path $ConfigDir "config.json"

            if (-not (Test-Path $ConfigPath)) {
                Write-Log "Config file not found at $ConfigPath. Please create config.json with your GPU name."
                return $null
            }

            $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if (-not $Config.gpuName) {
                Write-Log "Config file does not contain 'gpuName' property."
                return $null
            }

            $SelectedGpu = $Config.gpuName
            Write-Log "Using GPU from config file: $SelectedGpu"

            # Fetch list of GPUs from NVIDIA API to get ParentID and Value
            $LookupURL = "https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3"
            [xml]$LookupData = Invoke-WebRequest -Uri $LookupURL -UseBasicParsing

            # Fetch the first matching GPU entry
            $SelectedGpuInfo = $LookupData.LookupValueSearch.LookupValues.LookupValue | Where-Object {
                $_.Name -eq $SelectedGpu
            } | Select-Object -First 1

            if ($SelectedGpuInfo) {
                Write-Log "Found GPU in NVIDIA database: $($SelectedGpuInfo.Name)"
                return @{
                    Name     = $SelectedGpuInfo.Name
                    ParentID = $SelectedGpuInfo.ParentID
                    Value    = $SelectedGpuInfo.Value
                }
            }
            else {
                Write-Log "No match found for configured GPU: $SelectedGpu. Check config.json."
                return $null
            }
        }
        catch {
            Write-Log "Error while detecting GPU: $($_.Exception.Message)"
            return $null
        }
    }

    try {
        Clear-Host
        Write-Log "Starting NVIDIA driver update process..."

        # Check Windows version
        if ([System.Version][Environment]::OSVersion.Version.ToString() -lt [System.Version]"10.0") {
            Write-Log "Your Windows version is unsupported. Upgrade to Windows 10 or higher."
            return
        }

        # Check Windows bitness
        if (-not [Environment]::Is64BitOperatingSystem) {
            Write-Log "Your Windows architecture is x86. x64 is required."
            return
        }

        # Check for NVIDIA GPU
        $NvidiaGpuInfo = Get-NvidiaGpuInfo
        if (-not $NvidiaGpuInfo) {
            Write-Log "Exiting script as no NVIDIA GPU was detected or selected."
            return
        }

        #Write-Log "GPU: $($NvidiaGpuInfo.Name)"

        # Get current version using nvidia-smi if available
        if (Test-Path -Path "$env:SystemRoot\System32\DriverStore\FileRepository\nv*\nvidia-smi.exe") {
            $nvidiaSmiPath = (Get-ChildItem -Path "$env:SystemRoot\System32\DriverStore\FileRepository\nv*\nvidia-smi.exe" -Recurse -Force)[0].FullName
            $nvidiaSmiOutput = & $nvidiaSmiPath --format=csv,noheader --query-gpu=driver_version 2>&1

            if ($nvidiaSmiOutput -match "NVIDIA-SMI has failed") {
                Write-Verbose -Message "nvidia-smi encountered an issue: $nvidiaSmiOutput"
                $CurrentVersion = "Unknown"
            }
            else {
                $CurrentVersion = $nvidiaSmiOutput.Trim()
            }
        }
        else {
            if ($CurrentDriver -and $CurrentDriver.DriverVersion) {
                [System.Version]$ver = $CurrentDriver.DriverVersion
                $CurrentVersion = ("{0}{1}" -f $ver.Build, $ver.Revision)

                # Ensure the combined string is long enough
                if ($CurrentVersion.Length -ge 1) {
                    $CurrentVersion = $CurrentVersion.Substring(1).Insert(3, '.')
                }
                else {
                    Write-Log "Driver version format is invalid. Unable to parse version."
                    $CurrentVersion = "Unknown"
                }
            }
            else {
                Write-Log "CurrentDriver or DriverVersion is undefined. Skipping version processing."
                $CurrentVersion = "Unknown"
            }
        }

        Write-Log "Current Driver Version: $CurrentVersion"

        # Strip "NVIDIA" from the GPU name before checking against NVIDIA DB
        $GPUName = "$($NvidiaGpuInfo.Name)"
        $GPUNameNormalized = $GPUName -replace "^NVIDIA\s+", ""
        #Write-Log "Normalized GPU Name: $GPUNameNormalized"

        # If PSID and PFID are missing, fetch them dynamically
        if (-not $NvidiaGpuInfo.ParentID -or -not $NvidiaGpuInfo.Value) {
            Write-Log "Fetching PSID and PFID from NVIDIA API..."
            $LookupURL = "https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3"
            [xml]$LookupData = Invoke-WebRequest -Uri $LookupURL -UseBasicParsing
            $SelectedGpuInfo = $LookupData.LookupValueSearch.LookupValues.LookupValue | Where-Object { $_.Name -eq $NvidiaGpuInfo.Name -or $_.Name -eq $GPUNameNormalized } | Select-Object -First 1
            $NvidiaGpuInfo.ParentID = $SelectedGpuInfo.ParentID
            $NvidiaGpuInfo.Value = $SelectedGpuInfo.Value
        }

        if (-not $NvidiaGpuInfo) {
            Write-Log "Failed to find a matching GPU entry in NVIDIA's database for '$GPUName' or '$GPUNameNormalized'. Exiting."
            return
        }

        Write-Log "GPU SID: $($NvidiaGpuInfo.ParentID), PFID: $($NvidiaGpuInfo.Value)"

        # Build driver query URL
        $OSID = if ([Environment]::OSVersion.Version.Build -ge 22000) { 135 } else { 57 }
        $URL = "https://www.nvidia.com/Download/processDriver.aspx?psid=$($NvidiaGpuInfo.ParentID)&pfid=$($NvidiaGpuInfo.Value)&osid=$OSID&dtcid=1&dtid=1"

        Write-Log "Fetching driver information..."
        Write-Log "Driver URL: $URL"
        $Response = (Invoke-WebRequest -Uri $URL -UseBasicParsing).Content.Trim()
        Write-Log "Response: $Response"

        if ($Response -match '(\d+)/en-us') {
            $downloadID = $Matches[1]
            $AjaxURL = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=GetDownloadDetails&downloadID=$downloadID"

            Write-Log "Getting download link..."
            $json = Invoke-RestMethod -Uri $AjaxURL -Method Get

            if ($json.IDS -and $json.IDS[0].downloadInfo.DownloadURL) {
                $DownloadLink = $json.IDS[0].downloadInfo.DownloadURL
                
                # Extract the latest driver version from the JSON response
                if ($DownloadLink -match '(\d{3}\.\d{2})') {
                    $LatestDriverVersion = $Matches[1]
                    Write-Log "Latest Driver Version: $LatestDriverVersion"
                }
                else {
                    Write-Log "Failed to parse the latest driver version from the download link. Proceeding with download..."
                    $LatestDriverVersion = "Unknown"
                }

                if ($CurrentVersion -and $CurrentVersion -ne "Unknown") {

                    # Compare current driver version with the latest version
                    if ($LatestDriverVersion -eq $CurrentVersion) {
                        Write-Log "The latest NVIDIA driver ($LatestDriverVersion) is already installed. No update needed."
                        exit
                    }
                    Write-Log "A newer NVIDIA driver ($LatestDriverVersion) is available. Proceeding with the download and installation..."
                }
                else {
                    Write-Log "Current driver version could not be determined. Proceeding with the download and installation of $LatestDriverVersion..."
                }
				
                Write-Log "Download Link: $DownloadLink"

                # Setup folder paths
                $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
                $DownloadFolder = Join-Path $ScriptDir 'Temp'
                
                Write-Log "Creating download folder at: $DownloadFolder"
                if (!(Test-Path $DownloadFolder)) {
                    New-Item -ItemType Directory -Path $DownloadFolder | Out-Null
                }
                
                $FileName = Split-Path $DownloadLink -Leaf
                $DestinationPath = Join-Path $DownloadFolder $FileName

                Write-Log "`nChecking if file is already downloaded..."
                try {
                    $response = Invoke-WebRequest -Uri $DownloadLink -Method Head -ErrorAction Stop
                    $remoteFileSize = $response.Headers["Content-Length"] -as [int]
                    $localFileExists = Test-Path -Path $DestinationPath

                    if ($localFileExists) {
                        $localFileSize = (Get-Item $DestinationPath).Length

                        if ($localFileSize -eq $remoteFileSize) {
                            Write-Log "File already exists and matches the expected size. Skipping download."
                            $skipDownload = $true
                        }
                        else {
                            Write-Log "File exists but does not match the expected size. Redownloading..."
                            $skipDownload = $false
                        }
                    }
                    else {
                        Write-Log "File does not exist. Proceeding with download."
                        $skipDownload = $false
                    }
                }
                catch {
                    Write-Log "Error checking file size: $($_.Exception.Message). Proceeding with download."
                    $skipDownload = $false
                }

                # Download the file if needed
                if (-not $skipDownload) {
                    Write-Log "`nDownloading driver to $DestinationPath..."

                    #Download :D
                    Start-BitsTransfer -Source $DownloadLink -Destination $DestinationPath -RetryInterval 60

                    Write-Log "Download complete!"
                }
                else {
                    Write-Log "Using existing file: $DestinationPath"
                }
                
                # Download 7-Zip
                $SevenZipPath = Join-Path $DownloadFolder '7z.exe'
                if (-not (Test-Path $SevenZipPath)) {
                    Write-Log "Downloading 7-Zip..."
                    Start-BitsTransfer -Source "https://www.7-zip.org/a/7zr.exe" -Destination $SevenZipPath
                }

                # Extract
                $ExtractedPath = Join-Path $DownloadFolder 'NVIDIA-Driver-Extracted'
                Write-Log "Extracting to: $ExtractedPath"
                
                if (!(Test-Path $ExtractedPath)) {
                    New-Item -ItemType Directory -Path $ExtractedPath | Out-Null
                }

                $process = Start-Process -FilePath $SevenZipPath -ArgumentList "x -aoa -y `"$DestinationPath`" -o`"$ExtractedPath`"" -Wait -PassThru
                if ($process.ExitCode -eq 0) {
                    Write-Log "Extraction successful!"
                    
                    # Install
                    $InstallArgs = if ($Clean) { "-passive -clean -noeula -nofinish" } else { "-passive -noeula -nofinish" }
                    Write-Log "Installing driver..."

                    Start-Process -FilePath (Join-Path $ExtractedPath 'setup.exe') -ArgumentList $InstallArgs -Wait
                    
                    Write-Log "Installation complete!"

                    #
                    # TODO: CLEANUP THE FILES! :D
                    #

                }
                else {
                    Write-Log "Extraction failed with exit code: $($process.ExitCode)"
                }
            }
            else {
                Write-Log "Failed to get download URL from NVIDIA."
            }
        }
        else {
            Write-Log "Failed to parse driver information."
        }
    }
    catch {
        Write-Log "Error: $($_.Exception.Message)"
        Write-Log "Stack Trace: $($_.ScriptStackTrace)"
    }
}

# Actually run the function
UpdateNVIDIADriver -Clean