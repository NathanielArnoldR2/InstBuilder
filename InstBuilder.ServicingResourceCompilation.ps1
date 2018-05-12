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
$paths.Media = Join-Path -Path $paths.Scratch -ChildPath Media
$paths.Mount = Join-Path -Path $paths.Scratch -ChildPath Mount

$paths.InstallImage = Join-Path -Path $paths.Media -ChildPath sources\install.wim
$paths.BootImage = Join-Path -Path $paths.Media -ChildPath sources\boot.wim
$paths.ETFSBoot = Join-Path -Path $paths.Media -ChildPath boot\etfsboot.com
$paths.EFISys = Join-Path -Path $paths.Media -ChildPath efi\microsoft\boot\efisys_noprompt.bin

if ($Configuration.SelectedWorkflow -eq "BuildISO") {
  $paths.Output = $Configuration.WorkflowSettings.BuildISO.OutputPath
}
elseif ($Configuration.SelectedWorkflow -eq "VMTest") {
  $paths.Output = Join-Path -Path $InstBuilderPaths.Scratch -ChildPath "$($Configuration.Name).iso"

  $paths."VM.Base" = $InstBuilderPaths.VMTestLoads
  $paths."VM"      = Join-Path -Path $paths."VM.Base" -ChildPath $Configuration.Name

  $paths."VM.VHDs" = Join-Path -Path $Paths."VM" -ChildPath "Virtual Hard Disks"
  $paths."VM.VHD" = Join-Path -Path $paths."VM.VHDs" -ChildPath "$($Configuration.Name).vhdx"
}

$paths.GetEnumerator() |
  ForEach-Object {
    $Configuration.AppendChild(
      $Configuration.
      OwnerDocument.
      CreateElement("Paths.$($_.Key)")
    ).InnerXml = $_.Value
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