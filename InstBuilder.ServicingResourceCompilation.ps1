[CmdletBinding(
  PositionalBinding = $false
)]
param(
  [Parameter(
    Mandatory = $true
  )]
  [System.Xml.XmlElement]
  $Configuration,

  [Parameter(
    Mandatory = $true
  )]
  $InstBuilderPaths
)

Write-Verbose "Compiling servicing paths."

$paths = [ordered]@{
  Scratch = $InstBuilderPaths.Scratch
}
$mediaPath = $paths.Media = Join-Path -Path $paths.Scratch -ChildPath Media
$paths.Mount = Join-Path -Path $paths.Scratch -ChildPath Mount
$paths.InstallImage = Join-Path -Path $paths.Media -ChildPath sources\install.wim
$paths.BootImage = Join-Path -Path $paths.Media -ChildPath sources\boot.wim

$pathsNode = $Configuration.SelectSingleNode("Paths")

$paths.GetEnumerator() |
  ForEach-Object {
    $pathsNode.AppendChild(
      $Configuration.
      OwnerDocument.
      CreateElement($_.Key)
    ).InnerXml = $_.Value
  }

if ($Configuration.SelectedWorkflow -eq "VMTest") {
  $paths = [ordered]@{
    VMBase = $InstBuilderPaths.VMTestLoads
  }

  $paths.VM = Join-Path -Path $paths.VMBase -ChildPath $Configuration.Name
  $paths.VHDs = Join-Path -Path $paths.VM -ChildPath "Virtual Hard Disks"
  $paths.VHD = Join-Path -Path $paths.VHDs -ChildPath "$($Configuration.Name).vhdx"

  $vmTestNode = $pathsNode.AppendChild(
    $Configuration.
    OwnerDocument.
    CreateElement("VMTest")
  )

  $paths.GetEnumerator() |
    ForEach-Object {
      $vmTestNode.AppendChild(
        $Configuration.
        OwnerDocument.
        CreateElement($_.Key)
      ).InnerXml = $_.Value
    }
}

if ($Configuration.SelectedWorkflow -in "VMTest","BuildISO") {
  $paths = [ordered]@{
    Output   = $null
    ETFSBoot = Join-Path -Path $mediaPath -ChildPath boot\etfsboot.com
    EFISys   = Join-Path -Path $mediaPath -ChildPath efi\microsoft\boot\efisys_noprompt.bin    
  }

  if ($Configuration.SelectedWorkflow -eq "BuildISO") {
    $paths.Output = $Configuration.WorkflowSettings.BuildISO.OutputPath
  }
  elseif ($Configuration.SelectedWorkflow -eq "VMTest") {
    $paths.Output = Join-Path -Path $InstBuilderPaths.Scratch -ChildPath "$($Configuration.Name).iso"
  }

  $buildIsoNode = $pathsNode.AppendChild(
    $Configuration.
    OwnerDocument.
    CreateElement("BuildISO")
  )

  $paths.GetEnumerator() |
    ForEach-Object {
      $buildIsoNode.AppendChild(
        $Configuration.
        OwnerDocument.
        CreateElement($_.Key)
      ).InnerXml = $_.Value
    }
}

if ($Configuration.SelectedWorkflow -eq "BuildUSB") {
  Write-Verbose "Finding usb targets."

  $targetsNode = $Configuration.AppendChild(
    $Configuration.
    OwnerDocument.
    CreateElement("USBTargets")
  )

  $usbs = @(
    Get-Disk |
      Where-Object BusType -eq USB |
      Where-Object Size -gt 7gb |
      Where-Object Size -lt 128gb |
      Where-Object NumberOfPartitions -in 1,2 |
      Where-Object {
        $partitions = @(
          $_ |
            Get-Partition
        )

        $letteredPartitions = @(
          $partitions |
            Where-Object DriveLetter
        )

        if ($partitions.Count -ne $letteredPartitions.Count) {
          return $false
        }

        $hasLogFile = @(
          $partitions |
            Where-Object {Test-Path -LiteralPath "$($_.DriveLetter):\createdMedia.log" -PathType Leaf}
        )

        if ($partitions.Count -ne $hasLogFile.Count) {
          return $false
        }

        return $true
      } |
      ForEach-Object UniqueId
  )

  if ($usbs.Count -eq 0) {
    throw "No usb drives were attached matching the required specifications: Size -gt 7gb and -lt 128, with one or two partitions, all mounted at a drive letter, and each with a 'createdMedia.log' signing file at their root."
  }

  $usbs |
    ForEach-Object {
      $targetsNode.AppendChild(
        $Configuration.
        OwnerDocument.
        CreateElement("USBTarget")
      ).InnerText = $_
    }
}