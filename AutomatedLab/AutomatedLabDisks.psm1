#region New-LabBaseImages
function New-LabBaseImages
{
    
    [cmdletBinding()]
    param ()

    Write-LogFunctionEntry

    $lab = Get-Lab
    if (-not $lab)
    {
        Write-Error 'No definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $oses = (Get-LabVm -All).OperatingSystem

    if (-not $lab.Sources.AvailableOperatingSystems)
    {
        throw "There isn't a single operating system ISO available in the lab. Please call 'Get-LabAvailableOperatingSystem' to see what AutomatedLab has found and check the LabSources folder location by calling 'Get-LabSourcesLocation'."
    }

    $osesProcessed = @()
    $BaseImagesCreated = 0

    foreach ($os in $oses)
    {
        if (-not $os.ProductKey)
        {
            $message = "The product key is unknown for the OS '$($os.OperatingSystemName)' in ISO image '$($os.OSName)'. Cannot install lab until this problem is solved."
            Write-LogFunctionExitWithError -Message $message
            throw $message
        }

        $baseDiskPath = Join-Path -Path $lab.Target.Path -ChildPath "BASE_$($os.OperatingSystemName.Replace(' ', ''))_$($os.Version).vhdx"
        $os.BaseDiskPath = $baseDiskPath

        $hostOsVersion = [System.Version]((Get-CimInstance -ClassName Win32_OperatingSystem).Version)

        if ($hostOsVersion -ge [System.Version]'6.3' -and $os.Version -ge [System.Version]'6.2')
        {
            Write-PSFMessage -Message "Host OS version is '$($hostOsVersion)' and OS to create disk for is version '$($os.Version)'. So, setting partition style to GPT."
            $partitionStyle = 'GPT'
        }
        else
        {
            Write-PSFMessage -Message "Host OS version is '$($hostOsVersion)' and OS to create disk for is version '$($os.Version)'. So, KEEPING partition style as MBR."
            $partitionStyle = 'MBR'
        }

        if ($osesProcessed -notcontains $os)
        {
            $osesProcessed += $os

            if (-not (Test-Path $baseDiskPath))
            {
                Stop-ShellHWDetectionService

                New-LWReferenceVHDX -IsoOsPath $os.IsoPath `
                    -ReferenceVhdxPath $baseDiskPath `
                    -OsName $os.OperatingSystemName `
                    -ImageName $os.OperatingSystemImageName `
                    -SizeInGb $lab.Target.ReferenceDiskSizeInGB `
                    -PartitionStyle $partitionStyle

                $BaseImagesCreated++
            }
            else
            {
                Write-PSFMessage -Message "The base image $baseDiskPath already exists"
            }
        }
        else
        {
            Write-PSFMessage -Message "Base disk for operating system '$os' already created previously"
        }
    }

    if (-not $BaseImagesCreated)
    {
        Write-ScreenInfo -Message 'All base images were created previously'
    }

    Start-ShellHWDetectionService

    Write-LogFunctionExit
}
#endregion New-LabBaseImages


function Stop-ShellHWDetectionService
{
    

    Write-LogFunctionEntry

    $service = Get-Service -Name ShellHWDetection -ErrorAction SilentlyContinue
    if (-not $service)
    {
        Write-PSFMessage "The service 'ShellHWDetection' is not installed, exiting."
        Write-LogFunctionExit
        return
    }

    Write-PSFMessage 'Stopping the ShellHWDetection service (Shell Hardware Detection) to prevent the OS from responding to the new disks.'

    $retries = 5
    while ($retries -gt 0 -and ((Get-Service -Name ShellHWDetection).Status -ne 'Stopped'))
    {
        Write-Debug -Message 'Trying to stop ShellHWDetection'

        Stop-Service -Name ShellHWDetection | Out-Null
        Start-Sleep -Seconds 1
        if ((Get-Service -Name ShellHWDetection).Status -eq 'Running')
        {
            Write-Debug -Message "Could not stop service ShellHWDetection. Retrying."
            Start-Sleep -Seconds 5
        }
        $retries--
    }

    Write-LogFunctionExit
}

function Start-ShellHWDetectionService
{
    

    Write-LogFunctionEntry

    $service = Get-Service -Name ShellHWDetection -ErrorAction SilentlyContinue
    if (-not $service)
    {
        Write-PSFMessage "The service 'ShellHWDetection' is not installed, exiting."
        Write-LogFunctionExit
        return
    }

    if ((Get-Service -Name ShellHWDetection).Status -eq 'Running')
    {
        Write-PSFMessage -Message "'ShellHWDetection' Service is already running."
        Write-LogFunctionExit
        return
    }

    Write-PSFMessage 'Starting the ShellHWDetection service (Shell Hardware Detection) again.'

    $retries = 5
    while ($retries -gt 0 -and ((Get-Service -Name ShellHWDetection).Status -ne 'Running'))
    {
        Write-Debug -Message 'Trying to start ShellHWDetection'
        Start-Service -Name ShellHWDetection -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if ((Get-Service -Name ShellHWDetection).Status -ne 'Running')
        {
            Write-Debug -Message 'Could not start service ShellHWDetection. Retrying.'
            Start-Sleep -Seconds 5
        }
        $retries--
    }

    Write-LogFunctionExit
}


#region New-LabVHDX
function New-LabVHDX
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'ByName')]
        [string[]]$Name,

        [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'All')]
        [switch]$All
    )

    Write-LogFunctionEntry

    $lab = Get-Lab
    if (-not $lab)
    {
        Write-Error 'No definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    Write-PSFMessage 'Stopping the ShellHWDetection service (Shell Hardware Detection) to prevent the OS from responding to the new disks.'
    Stop-ShellHWDetectionService

    if ($Name)
    {
        $disks = $lab.Disks | Where-Object Name -in $Name
    }
    else
    {
        $disks = $lab.Disks
    }

    if (-not $disks)
    {
        Write-PSFMessage 'No disks found to create. Either the given name is wrong or there is no disk defined yet'
        Write-LogFunctionExit
        return
    }

    $disksPath = Join-Path -Path $lab.Target.Path -ChildPath Disks

    foreach ($disk in $disks)
    {
        Write-ScreenInfo -Message "Creating disk '$($disk.Name)'" -TaskStart -NoNewLine
        $diskPath = Join-Path -Path $disksPath -ChildPath ($disk.Name + '.vhdx')
        if (-not (Test-Path -Path $diskPath))
        {
            $params = @{
                VhdxPath = $diskPath
                SizeInGB = $disk.DiskSize
                SkipInitialize = $disk.SkipInitialization
                Label = $disk.Label
                UseLargeFRS = $disk.UseLargeFRS
                AllocationUnitSize = $disk.AllocationUnitSize
            }
            if ($disk.DriveLetter)
            {
                $params.DriveLetter = $disk.DriveLetter
            }
            New-LWVHDX @params
            Write-ScreenInfo -Message 'Done' -TaskEnd
        }
        else
        {
            Write-ScreenInfo "The disk '$diskPath' does already exist, no new disk is created." -Type Warning -TaskEnd
        }
    }

    Write-PSFMessage 'Starting the ShellHWDetection service (Shell Hardware Detection) again.'
    Start-ShellHWDetectionService

    Write-LogFunctionExit
}
#endregion New-LabVHDX

#region Get-LabVHDX
function Get-LabVHDX
{
    
    [OutputType([AutomatedLab.Machine])]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch]$All
    )

    Write-LogFunctionEntry

    $lab = Get-Lab
    if (-not $lab)
    {
        Write-Error 'No definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    if ($PSCmdlet.ParameterSetName -eq 'ByName')
    {
        $results = $lab.Disks | Where-Object -FilterScript {
            $_.Name -in $Name
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'All')
    {
        $results = $lab.Disks
    }

    if ($results)
    {
        $diskPath = Join-Path -Path $lab.Target.Path -ChildPath Disks
        foreach ($result in $results)
        {
            $result.Path = Join-Path -Path $diskPath -ChildPath ($result.Name + '.vhdx')
        }

        Write-LogFunctionExit -ReturnValue $results.ToString()

        return $results
    }
    else
    {
        return
    }
}
#endregion Get-LabVHDX

#region Update-LabIsoImage
function Update-LabIsoImage
{
    
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)]
        [string]$SourceIsoImagePath,

        [Parameter(Mandatory)]
        [string]$TargetIsoImagePath,

        [Parameter(Mandatory)]
        [string]$UpdateFolderPath,

        [Parameter(Mandatory)]
        [int]$SourceImageIndex
    )

    #region Extract-IsoImage
    function Extract-IsoImage
    {
        param(
            [Parameter(Mandatory)]
            [string]$SourceIsoImagePath,

            [Parameter(Mandatory)]
            [string]$OutputPath,

            [switch]$Force
        )

        if (-not (Test-Path -Path $SourceIsoImagePath -PathType Leaf))
        {
            Write-Error "The specified ISO image '$SourceIsoImagePath' could not be found"
            return
        }

        if ((Test-Path -Path $OutputPath) -and -not $Force)
        {
            Write-Error "The output folder does already exist" -TargetObject $OutputPath
            return
        }
        else
        {
            Remove-Item -Path $OutputPath -Force -Recurse -ErrorAction Ignore
        }

        New-Item -ItemType Directory -Path $OutputPath | Out-Null


        $image = Mount-DiskImage -ImagePath $SourceIsoImagePath -PassThru
        Get-PSDrive | Out-Null #This is just to refresh the drives. Somehow if this cmdlet is not called, PowerShell does not see the new drives.

        if($image)
        {

            $volume = Get-DiskImage -ImagePath $image.ImagePath | Get-Volume
            $source = $volume.DriveLetter + ':\*'

            Write-PSFMessage "Extracting ISO image '$source' to '$OutputPath'"
            Copy-Item -Path $source -Destination $OutputPath -Recurse -Force
            [void] (Dismount-DiskImage -ImagePath $SourceIsoImagePath)
            Write-PSFMessage 'Copy complete'
        }
        else
        {
            Write-Error "Could not mount ISO image '$SourceIsoImagePath'" -TargetObject $SourceIsoImagePath
            return
        }
    }
    #endregion Extract-IsoImage

    #region Get-IsoImageName
    function Get-IsoImageName
    {
        param(
            [Parameter(Mandatory)]
            [string]$IsoImagePath
        )

        if (-not (Test-Path -Path $IsoImagePath -PathType Leaf))
        {
            Write-Error "The specified ISO image '$IsoImagePath' could not be found"
            return
        }

        $image = Mount-DiskImage $IsoImagePath -PassThru
        $image | Get-Volume | Select-Object -ExpandProperty FileSystemLabel
        [void] ($image | Dismount-DiskImage)
    }
    #endregion Get-IsoImageName

    $isUefi = try
    {
        Get-SecureBootUEFI -Name SetupMode
    }
    catch { }

    if (-not $isUefi)
    {
        throw "Updating ISO files does only work on UEFI systems due to a limitation of oscdimg.exe"
    }

    if (-not (Test-Path -Path $SourceIsoImagePath -PathType Leaf))
    {
        Write-Error "The specified ISO image '$SourceIsoImagePath' could not be found"
        return
    }

    if (Test-Path -Path $TargetIsoImagePath -PathType Leaf)
    {
        Write-Error "The specified target ISO image '$TargetIsoImagePath' does already exist"
        return
    }

    if ([System.IO.Path]::GetExtension($TargetIsoImagePath) -ne '.iso')
    {
        Write-Error "The specified target ISO image path must have the extension '.iso'"
        return
    }

    Write-PSFMessage -Level Host 'Creating an updated ISO from'
    Write-PSFMessage -Level Host "Target path             $TargetIsoImagePath"
    Write-PSFMessage -Level Host "Source path             $SourceIsoImagePath"
    Write-PSFMessage -Level Host "with updates from path  $UpdateFolderPath"    
    Write-PSFMessage -Level Host "This process can take a long time, depending on the number of updates"
    $start = Get-Date
    Write-PSFMessage -Level Host "Start time: $start"

    $extractTempFolder = New-Item -ItemType Directory -Path $labSources -Name ([guid]::NewGuid())
    $mountTempFolder = New-Item -ItemType Directory -Path $labSources -Name ([guid]::NewGuid())

    $isoImageName = Get-IsoImageName -IsoImagePath $SourceIsoImagePath

    Write-PSFMessage -Level Host "Extracting ISO image '$SourceIsoImagePath' to '$extractTempFolder'"
    Extract-IsoImage -SourceIsoImagePath $SourceIsoImagePath -OutputPath $extractTempFolder -Force

    $installWim = Get-ChildItem -Path $extractTempFolder -Filter install.wim -Recurse
    Write-PSFMessage -Level Host "Working with '$installWim'"
    Write-PSFMessage -Level Host "Exporting install.wim to $labSources"
    Export-WindowsImage -SourceImagePath $installWim.FullName -DestinationImagePath $labSources\install.wim -SourceIndex $SourceImageIndex

    $windowsImage = Get-WindowsImage -ImagePath $labSources\install.wim
    Write-PSFMessage -Level Host "The Windows Image exported is named '$($windowsImage.ImageName)'"

    $patches = Get-ChildItem -Path $UpdateFolderPath\* -Include *.msu, *.cab
    Write-PSFMessage -Level Host "Found $($patches.Count) patches in the UpdateFolderPath '$UpdateFolderPath'"

    Write-PSFMessage -Level Host "Mounting Windows Image '$($windowsImage.ImagePath)' to folder "
    Mount-WindowsImage -Path $mountTempFolder -ImagePath $windowsImage.ImagePath -Index 1

    Write-PSFMessage -Level Host "Adding patches to the mounted Windows Image. This can take quite some time..."
    foreach ($patch in $patches)
    {
        Write-PSFMessage -Level Host "Adding patch '$($patch.Name)'..." -NoNewline
        Add-WindowsPackage -PackagePath $patch.FullName -Path $mountTempFolder | Out-Null
        Write-PSFMessage -Level Host 'finished'
    }

    Write-PSFMessage -Level Host "Dismounting Windows Image from path '$mountTempFolder' and saving the changes. This can take quite some time again..." -NoNewline
    Dismount-WindowsImage -Path $mountTempFolder -Save
    Write-PSFMessage -Level Host 'finished'

    Write-PSFMessage -Level Host "Moving updated Windows Image '$labsources\install.wim' to '$extractTempFolder'"
    Move-Item -Path $labsources\install.wim -Destination $extractTempFolder\sources -Force

    Write-PSFMessage -Level Host "Calling oscdimg.exe to create a new bootable ISO image '$TargetIsoImagePath'..." -NoNewline
    $cmd = "$labSources\Tools\oscdimg.exe -m -o -u2 -l$isoImageName -udfver102 -bootdata:2#p0,e,b$extractTempFolder\boot\etfsboot.com#pEF,e,b$extractTempFolder\efi\microsoft\boot\efisys.bin $extractTempFolder $TargetIsoImagePath"
    Write-PSFMessage $cmd
    $global:oscdimgResult = Invoke-Expression -Command $cmd 2>&1
    Write-PSFMessage -Level Host 'finished'

    Write-PSFMessage -Level Host "Deleting temp folder '$extractTempFolder'"
    Remove-Item -Path $extractTempFolder -Recurse -Force

    Write-PSFMessage -Level Host "Deleting temp folder '$mountTempFolder'"
    Remove-Item -Path $mountTempFolder -Recurse -Force

    $end = Get-Date
    Write-PSFMessage -Level Host "finished at $end. Runtime: $($end - $start)"
}
#endregion Update-LabIsoImage

#region Update-LabBaseImage
function Update-LabBaseImage
{
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)]
        [string]$BaseImagePath,

        [Parameter(Mandatory)]
        [string]$UpdateFolderPath
    )

    if (-not (Test-Path -Path $BaseImagePath -PathType Leaf))
    {
        Write-Error "The specified image '$BaseImagePath' could not be found"
        return
    }

    if ([System.IO.Path]::GetExtension($BaseImagePath) -ne '.vhdx')
    {
        Write-Error "The specified image must have the extension '.vhdx'"
        return
    }

    $patchesCab = Get-ChildItem -Path $UpdateFolderPath\* -Include *.cab -ErrorAction SilentlyContinue
    $patchesMsu = Get-ChildItem -Path $UpdateFolderPath\* -Include *.msu -ErrorAction SilentlyContinue

    if (($patchesCab -eq $null) -and ($patchesMsu -eq $null))
    {
        Write-Error "No .cab and .msu files found in '$UpdateFolderPath'"
        return
    }

    Write-PSFMessage -Level Host 'Updating base image'
    Write-PSFMessage -Level Host $BaseImagePath
    Write-PSFMessage -Level Host "with $($patchesCab.Count + $patchesMsu.Count) updates from"
    Write-PSFMessage -Level Host $UpdateFolderPath
    Write-PSFMessage -Level Host 'This process can take a long time, depending on the number of updates'

    $start = Get-Date
    Write-PSFMessage -Level Host "Start time: $start"

    Write-PSFMessage -Level Host 'Creating temp folder (mount point)'
    $mountTempFolder = New-Item -ItemType Directory -Path $labSources -Name ([guid]::NewGuid())

    Write-PSFMessage -Level Host "Mounting Windows Image '$BaseImagePath'"
    Write-PSFMessage -Level Host "to folder '$mountTempFolder'"
    Mount-WindowsImage -Path $mountTempFolder -ImagePath $BaseImagePath -Index 1

    Write-PSFMessage -Level Host 'Adding patches to the mounted Windows Image.'
    $patchesCab | ForEach-Object {

        $UpdateReady = Get-WindowsPackage -PackagePath $_ -Path $mountTempFolder | Select-Object -Property PackageState, PackageName, Applicable

        if ($UpdateReady.PackageState -eq 'Installed')
        {
            Write-PSFMessage -Level Host "$($UpdateReady.PackageName) is already installed"
        }
        elseif ($UpdateReady.Applicable -eq $true)
        {
            Add-WindowsPackage -PackagePath $_.FullName -Path $mountTempFolder
        }
    }
    $patchesMsu | ForEach-Object {

        Add-WindowsPackage -PackagePath $_.FullName -Path $mountTempFolder
    }

    Write-PSFMessage -Level Host "Dismounting Windows Image from path '$mountTempFolder' and saving the changes. This can take quite some time again..." -NoNewline
    Dismount-WindowsImage -Path $mountTempFolder -Save
    Write-PSFMessage -Level Host 'finished'

    Write-PSFMessage -Level Host "Deleting temp folder '$mountTempFolder'"
    Remove-Item -Path $mountTempFolder -Recurse -Force

    $end = Get-Date
    Write-PSFMessage -Level Host "finished at $end. Runtime: $($end - $start)"
}
#endregion Update-LabBaseImage
