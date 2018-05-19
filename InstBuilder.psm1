param(
  [Parameter(
    Position = 0
  )]
  [bool]
  $ExportConfigurationCommands,

  [Parameter(
    Position = 1
  )]
  [bool]
  $ExportRealizationCommands,

  [Parameter(
    Position = 2
  )]
  [bool]
  $UseDefaultResourcePaths
)



# Override Microsoft.PowerShell.Utility\Write-Verbose to timestamp all verbose
# output written by this module.
function Write-Verbose ($Message) {
  $stored = $Host.PrivateData.VerboseForegroundColor
  $Host.PrivateData.VerboseForegroundColor = "White"
  $Host.PrivateData.VerboseBackgroundColor = $Host.UI.RawUI.BackgroundColor

  Microsoft.PowerShell.Utility\Write-Verbose -Message "[$([datetime]::Now.ToString("HH:mm"))] $($Message)"

  $Host.PrivateData.VerboseForegroundColor = $stored
  $Host.PrivateData.VerboseBackgroundColor = $Host.UI.RawUI.BackgroundColor
}

function Write-Warning ($Message) {
  $stored = $Host.PrivateData.WarningForegroundColor
  $Host.PrivateData.WarningForegroundColor = "Yellow"
  $Host.PrivateData.WarningBackgroundColor = $Host.UI.RawUI.BackgroundColor

  Microsoft.PowerShell.Utility\Write-Warning -Message "[$([datetime]::Now.ToString("HH:mm"))] $($Message)"

  $Host.PrivateData.WarningForegroundColor = $stored
  $Host.PrivateData.WarningBackgroundColor = $Host.UI.RawUI.BackgroundColor
}

. $PSScriptRoot\InstBuilder.ResourcePathManager.ps1

if ((-not ($PSBoundParameters.ContainsKey("UseDefaultResourcePaths"))) -or $UseDefaultResourcePaths) {
  . $PSScriptRoot\InstBuilder.ResourcePaths.ps1
}

$resources = @{}

$resources.ConfigurationCommands = Get-Content -LiteralPath $PSScriptRoot\InstBuilder.ConfigurationCommands.ps1 -Raw
$resources.ConfigurationAliases = Get-Content -LiteralPath $PSScriptRoot\InstBuilder.ConfigurationAliases.ps1 -Raw

$resources.ConfigurationSchema = [System.Xml.Schema.XmlSchema]::Read(
  [System.Xml.XmlNodeReader]::new(
    [xml](Get-Content -LiteralPath $PSScriptRoot\InstBuilder.Configuration.xsd -Raw)
  ),
  $null
)

$resources.ModuleImportScript = {

param(
  [string[]]
  $Filter = @()
)

$directories = Get-ChildItem -LiteralPath $PSScriptRoot |
                 Where-Object {$_ -is [System.IO.DirectoryInfo]}

if ($Filter.Count -gt 0) {
  $directories = $directories |
                   Where-Object {$_.Name -in $Filter}
}

$directories |
  ForEach-Object {
    $directory = $_

    $directory |
      Get-ChildItem |
      Where-Object {
        $_.BaseName -eq $directory.Name -and
        $_.Extension -in ".psd1",".psm1"
      } |
      Sort-Object {$_.Extension -eq ".psd1"} -Descending |
      Select-Object -First 1 |
      ForEach-Object {$_.FullName} |
      Import-Module
  }

if ((Get-Module).Name -contains "CTPackage") {
  Add-CTPackageSource -Name Local -Path C:\CT\Packages
}

}.ToString().Trim()

#region Resolution & Validation
function Resolve-InstBuilderConfiguration_EachPass {
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlDocument]
    $Xml,

    [Parameter(
      Mandatory = $true
    )]
    [ValidateSet("NamedConfiguration","SuppliedConfiguration")]
    [string]
    $ResolveMode
  )
  try {
    . $PSScriptRoot\InstBuilder.RuleEvaluator.ps1

    New-Alias -Name rule -Value New-EvaluationRule

    . $PSScriptRoot\InstBuilder.RuleEvaluator.Rules.ps1

    Remove-Item alias:\rule

    Invoke-EvaluationRules -Xml $Xml -Rules $Rules
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Select-InstBuilderWorkflow {
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
    [AllowEmptyString()]
    [string]
    $Workflow
  )

  if ($Workflow.Length -eq 0) {
    Write-Verbose "Prompting selection of a supported workflow, if needed."
  }
  else {
    Write-Verbose "Validating supplied workflow against supported options."
  }

  $Workflows = @(
    & $PSScriptRoot\InstBuilder.Workflows.ps1
  )

  # Normalize Capitalization of supported workflows.
  $SupportedWorkflows = @(
    $Configuration.SelectNodes("SupportedWorkflows/SupportedWorkflow") |
      ForEach-Object {
        $WorkflowName = $_.InnerXml

        $Workflows |
          Where-Object {$_.Name -eq $WorkflowName}
      }
  )

  if ($Workflow.Length -gt 0 -and $Workflow -notin @($Workflows | ForEach-Object Name)) {
    throw "Provided workflow is unknown to this module."
  }
  elseif ($Workflow.Length -gt 0 -and $Workflow -notin @($SupportedWorkflows | ForEach-Object Name)) {
    throw "Provided workflow is not supported by this configuration."
  }
  elseif ($Workflow.Length -gt 0) {
    # Normalize capitalization of provided workflow.
    return $SupportedWorkflows |
             Where-Object Name -eq $Workflow |
             ForEach-Object Name
  }

  if ($SupportedWorkflows.Count -eq 1) {
    return $SupportedWorkflows[0].Name
  }

  $inc = 1

  $choices = @(
    $SupportedWorkflows |
      ForEach-Object {
        [System.Management.Automation.Host.ChoiceDescription]::new(
          "&$($inc): $($_.DisplayName)",
          $_.Description
        )
        $inc++
      }
  )

  $result = $Host.UI.PromptForChoice(
    $null,
    "Select a supported workflow.",
    $choices,
    0
  )

  return $SupportedWorkflows[$result].Name
}

function Test-InstBuilderServicingPath {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNode]
    $Configuration
  )

  Write-Verbose "Validating servicing paths."

  if (
    $Configuration.Paths.VMTest -is [System.Xml.XmlElement] -and
    (Test-Path -LiteralPath $Configuration.Paths.VMTest.VM)
  ) {
    $VM = Get-VM |
            Where-Object Path -like "$($Configuration.Paths.VMTest.VM)*"

    $VM |
      ForEach-Object {
        Invoke-InstBuilderVMAction_Stop $VM
      }

    Remove-Item -LiteralPath $Configuration.Paths.VMTest.VM -Recurse -Force -ErrorAction Stop
  }

  if (
    $Configuration.Paths.BuildISO -is [System.Xml.XmlElement] -and
    (Test-Path -LiteralPath $Configuration.Paths.BuildISO.Output)
  ) {
    $imgObj = Get-DiskImage -ImagePath $Configuration.Paths.BuildISO.Output -ErrorAction Stop

    if ($imgObj.Attached) {
      Dismount-DiskImage -ImagePath $Configuration.Paths.BuildISO.Output -ErrorAction Stop
    }

    Remove-Item -LiteralPath $Configuration.Paths.BuildISO.Output -ErrorAction Stop
  }

  if (Test-Path -LiteralPath $Configuration.Paths.Scratch) {
    Remove-Item -LiteralPath $Configuration.Paths.Scratch -Recurse -Force -ErrorAction Stop
  }

  New-Item -Path $Configuration.Paths.Mount -ItemType Directory -Force |
    Out-Null
}
#endregion

#region Media Assembly
function Build-InstBuilderMedia {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )

  Write-Verbose "Building install media content."

  Write-Verbose "  - Copying iso content to media path."

  $isoRoot = Mount-DiskImage -ImagePath $Configuration.Paths.Source.ISO -PassThru |
               Get-Volume |
               ForEach-Object {$_.DriveLetter + ":\"}

  do {
    Start-Sleep -Milliseconds 250
  } until ((Get-PSDrive | Where-Object Root -eq $isoRoot) -ne $null)

  Copy-Item -LiteralPath $isoRoot -Destination $Configuration.Paths.Media -Recurse

  Dismount-DiskImage -ImagePath $Configuration.Paths.Source.ISO

  Write-Verbose "  - Overwriting pristine install image."

  Copy-Item -LiteralPath $Configuration.Paths.Source.WIM `
            -Destination $Configuration.Paths.InstallImage `
            -Force

  Build-InstBuilderMedia_ServiceInstallImage -Configuration $Configuration

  Build-InstBuilderMedia_ServiceBootImage -Configuration $Configuration

  Build-InstBuilderMedia_ServiceMedia -Configuration $Configuration
}

function Build-InstBuilderMedia_ServiceInstallImage {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )

  $Drivers = $Configuration.SelectNodes("Drivers/Package") |
               ForEach-Object GetAttribute Source
  $OfflinePackages = $Configuration.SelectNodes("OfflinePackages/Package") |
                       ForEach-Object GetAttribute Source
  $Modules = $Configuration.SelectNodes("Modules/Package")
  $Packages = $Configuration.SelectNodes("Packages/Package")

  if (
    $Configuration.ServicingScripts.InstallImage -eq 'none' -and
    $Configuration.UsrClass -eq "none" -and
    $Configuration.Script -eq "none" -and
    $Drivers.Count -eq 0 -and
    $OfflinePackages.Count -eq 0 -and
    $Modules.Count -eq 0 -and
    $Packages.Count -eq 0
  ) {
    return
  }

  Write-Verbose "  - Servicing install image."

  Mount-WindowsImage -ImagePath $Configuration.Paths.InstallImage `
                     -Path $Configuration.Paths.Mount `
                     -Index 1 |
    Out-Null

  $paths = @{
    Def_NTUSER_OL = Join-Path -Path $Configuration.Paths.Mount -ChildPath Users\Default\NTUSER.DAT
    Def_UsrClass_Staged_REL = "Users\Default\AppData\Local\Microsoft\Windows\UsrClass.dat.Staged"
    Def_UsrClass_Final_OS = "C:\Users\Default\AppData\Local\Microsoft\Windows\UsrClass.dat"
    SetupComplete = Join-Path -Path $Configuration.Paths.Mount -ChildPath Windows\Setup\Scripts\SetupComplete.cmd
  }

  $paths.Def_UsrClass_Staged_OL = Join-Path -Path $Configuration.Paths.Mount -ChildPath $paths.Def_UsrClass_Staged_REL
  $paths.Def_UsrClass_Staged_OS = Join-Path -Path C:\ -ChildPath $paths.Def_UsrClass_Staged_REL

  if ($Configuration.UsrClass -ne "none") {
    Copy-Item -LiteralPath $Configuration.UsrClass -Destination $paths.Def_UsrClass_Staged_OL

    New-Item -Path $paths.SetupComplete `
             -ItemType File `
             -Value "move $($paths.Def_UsrClass_Staged_OS) $($paths.Def_UsrClass_Final_OS)" `
             -Force |
      Out-Null
  }

  if ($Configuration.ServicingScripts.InstallImage -ne "none") {
    $paths.Hive_Backup = New-Item -Path (Join-Path -Path $Configuration.Paths.Mount -ChildPath 'CT\Temp\Hive Backup') `
                                  -ItemType Directory `
                                  -Force |
                           ForEach-Object FullName

    $paths.Def_NTUSER_OL,
    $paths.Def_UsrClass_Staged_OL |
      Where-Object {Test-Path -LiteralPath $_} |
      Copy-Item -Destination $paths.Hive_Backup

    Invoke-InstBuilderServicingScript `
    -ImageRoot $Configuration.Paths.Mount `
    -ImageRootName IMG `
    -ServicingScript $Configuration.ServicingScripts.InstallImage `
    -ScriptParameters (Get-InstBuilderScriptParameterObject -Configuration $Configuration) `
    -MountRegistryResources
  }

  if ($Configuration.Script -ne "none") {
    $scriptPath = Join-Path -Path $Configuration.Paths.Mount -ChildPath CT\script.ps1

    New-Item -Path $scriptPath -Value $Configuration.Script -Force |
      Out-Null
  }

  if ($Drivers.Count -gt 0) {
    $Drivers |
      ForEach-Object {
        Add-WindowsDriver -Driver $_ `
                          -Path $Configuration.Paths.Mount `
                          -Recurse `
                          -ForceUnsigned `
                          -WarningAction SilentlyContinue `
                          -Verbose:$false
      } |
      Out-Null
  }

  if ($OfflinePackages.Count -gt 0) {
    $OfflinePackages |
      ForEach-Object {
        Add-WindowsPackage -PackagePath $_ -Path $Configuration.Paths.Mount
      } |
      Out-Null
  }

  if ($Modules.Count -gt 0) {
    $ModulesPath = Join-Path -Path $Configuration.Paths.Mount -ChildPath $Modules[0].GetAttribute("Destination")

    $Modules |
      Copy-InstBuilderImagePackage -ImageRoot $Configuration.Paths.Mount

    New-Item -Path $ModulesPath `
             -Name import.ps1 `
             -Value $script:resources.ModuleImportScript `
             -Force |
      Out-Null

    $commonPath = Join-Path -Path $ModulesPath -ChildPath Common
    $scriptParameters = Get-InstBuilderScriptParameterObject -Configuration $Configuration

    if ((Test-Path -LiteralPath $commonPath -PathType Container) -and $scriptParameters -is [PSCustomObject]) {
        New-Item -Path $commonPath `
                 -Name ScriptParameters.json `
                 -ItemType File `
                 -Value ($scriptParameters | ConvertTo-Json) `
                 -Force |
          Out-Null
    }
  }

  if ($Packages.Count -gt 0) {
    $Packages |
      Copy-InstBuilderImagePackage -ImageRoot $Configuration.Paths.Mount
  }

  Dismount-WindowsImage -Path $Configuration.Paths.Mount -Save |
    Out-Null
}
function Build-InstBuilderMedia_ServiceBootImage {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )

  $PEDrivers = $Configuration.SelectNodes("PEDrivers/Package") |
                 ForEach-Object GetAttribute Source

  if (
    $Configuration.ServicingScripts.BootImage -eq "none" -and
    $Configuration.Unattend -eq "none" -and
    $PEDrivers.Count -eq 0
  ) {
    return
  }

  Write-Verbose "  - Servicing boot image."

  $imageItem = Get-Item -LiteralPath $Configuration.Paths.BootImage

  if ($imageItem.Attributes.HasFlag([System.IO.FileAttributes]::ReadOnly)) {
    $imageItem.Attributes = $imageItem.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
  }

  Mount-WindowsImage -ImagePath $Configuration.Paths.BootImage `
                     -Path $Configuration.Paths.Mount `
                     -Index 2 | # Haven't investigated why index "2" instead of "1" is needed.
    Out-Null

  if ($Configuration.ServicingScripts.BootImage -ne "none") {
    Invoke-InstBuilderServicingScript `
    -ImageRoot $Configuration.Paths.Mount `
    -ImageRootName IMG `
    -ServicingScript $Configuration.ServicingScripts.BootImage `
    -ScriptParameters (Get-InstBuilderScriptParameterObject -Configuration $Configuration) `
    -MountRegistryResources
  }

  if ($Configuration.Unattend -ne "none") {
    New-Item -Path $Configuration.Paths.Mount `
             -Name autounattend.xml `
             -Value $Configuration.Unattend `
             -Force |
      Out-Null
  }

  if ($PEDrivers.Count -gt 0) {
    $PEDrivers |
      ForEach-Object {
        Add-WindowsDriver -Driver $_ `
                          -Path $Configuration.Paths.Mount `
                          -Recurse `
                          -ForceUnsigned `
                          -WarningAction Ignore |
          Out-Null
      }
  }

  Dismount-WindowsImage -Path $Configuration.Paths.Mount -Save |
    Out-Null
}
function Build-InstBuilderMedia_ServiceMedia {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )

  if (
    $Configuration.BootMode -eq "Both" -and
    $Configuration.ServicingScripts.Media -eq "none"
  ) {
    return
  }

  Write-Verbose "  - Servicing media."

  if ($Configuration.BootMode -eq "UEFI") {
    $pathToRemove = Join-Path -Path $Configuration.Paths.Media -ChildPath bootmgr

    Remove-Item -LiteralPath $pathToRemove -Recurse -Force
  }
  elseif ($Configuration.BootMode -eq "Legacy") {
    $pathToRemove = Join-Path -Path $Configuration.Paths.Media -ChildPath efi

    Remove-Item -LiteralPath $pathToRemove -Recurse -Force
  }

  Invoke-InstBuilderServicingScript `
  -ImageRoot $Configuration.Paths.Media `
  -ImageRootName MEDIA `
  -ServicingScript $Configuration.ServicingScripts.Media `
  -ScriptParameters (Get-InstBuilderScriptParameterObject -Configuration $Configuration)
}

function Get-InstBuilderScriptParameterObject {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )

  $ScriptParameters = $Configuration.SelectNodes("ScriptParameters/ScriptParameter")

  if ($ScriptParameters.Count -eq 0) {
    return
  }

  $outHash = @{}

  foreach ($parameter in $ScriptParameters) {
    $val = $parameter.GetAttribute("Value")

    if ($val -ceq "true") {
      $val = $true
    }
    elseif ($val -ceq "false") {
      $val = $false
    }

    $outHash.$($parameter.GetAttribute("Name")) = $val
  }

  return [PSCustomObject]$outHash
}
function Invoke-InstBuilderServicingScript {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $ImageRoot,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $ImageRootName,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $ServicingScript,

    [PSCustomObject]
    $ScriptParameters,

    [switch]
    $MountRegistryResources
  )

  function New-PSDriveObj ($Name, $PSProvider, $Root, $Description) {
    [PSCustomObject]@{
      Name        = $Name
      PSProvider  = $PSProvider
      Root        = $Root
      Description = $Description
    }
  }

  $drives = @(
    New-PSDriveObj -Name $ImageRootName `
                   -PSProvider FileSystem `
                   -Root $ImageRoot `
                   -Description "FileSystem Root"
  )

  if ($MountRegistryResources) {
    $drives += @(
      New-PSDriveObj -Name "$($ImageRootName)_REG_SYS" `
                     -PSProvider Registry `
                     -Root (Join-Path -Path $ImageRoot -ChildPath Windows\System32\config\SYSTEM) `
                     -Description "System Registry"

      New-PSDriveObj -Name "$($ImageRootName)_REG_SW" `
                     -PSProvider Registry `
                     -Root (Join-Path -Path $ImageRoot -ChildPath Windows\System32\config\SOFTWARE) `
                     -Description "Software Registry"

      New-PSDriveObj -Name "$($ImageRootName)_REG_DEF" `
                     -PSProvider Registry `
                     -Root (Join-Path -Path $ImageRoot -ChildPath Users\Default\NTUSER.DAT) `
                     -Description "Default Profile Registry"

      New-PSDriveObj -Name "$($ImageRootName)_REG_DEF_CLS" `
                     -PSProvider Registry `
                     -Root (Join-Path -Path $ImageRoot -ChildPath Users\Default\AppData\Local\Microsoft\Windows\UsrClass.dat.Staged) `
                     -Description "Default Profile Classes Registry"
    )
  }

  foreach ($drive in $drives) {
    if (-not (Test-Path -LiteralPath $drive.Root)) {
      continue
    }

    if ($drive.PSProvider -eq "Registry") {
      & reg load "HKLM\$($drive.Name)" $drive.Root |
        Out-Null

      $drive.Root = "HKLM:\$($drive.Name)"
    }

    New-PSDrive -Name $drive.Name `
                -PSProvider $drive.PSProvider `
                -Root $drive.Root `
                -Description $drive.Description |
      Out-Null
  }

  $pl = $Host.Runspace.CreateNestedPipeline()
  $cmd = [System.Management.Automation.Runspaces.Command]::new('param($scriptParameters)', $true)
  $cmd.Parameters.Add(
    [System.Management.Automation.Runspaces.CommandParameter]::new(
      'scriptParameters',
      $ScriptParameters
    )
  )
  $pl.Commands.Add($cmd)
  $pl.Commands.AddScript('$scriptParams = $scriptParameters')
  $pl.Commands.AddScript($ServicingScript)
  $pl.Invoke() | Out-Null

  # Mandatory before registry unload.
  [System.GC]::Collect()

  foreach ($drive in $drives) {
    if ((Get-PSDrive | where-Object Name -eq $drive.Name) -eq $null) {
      continue
    }

    Remove-PSDrive -Name $drive.Name

    if ($drive.PSProvider -eq "Registry") {
      & reg unload "HKLM\$($drive.Name)" |
        Out-Null
    }
  }
}
function Copy-InstBuilderImagePackage {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Package,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $ImageRoot
  )
  process {
    $DestinationPath = Join-Path -Path $ImageRoot -ChildPath $Package.GetAttribute("Destination")

    $Destination = Join-Path -Path $DestinationPath `
                             -ChildPath (Split-Path -Path $Package.GetAttribute("Source") -Leaf)

    if (Test-Path -LiteralPath $Destination) {
      throw "Package already exists at intended destination."
    }

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
      New-Item -Path $DestinationPath -ItemType Directory -Force |
        Out-Null
    }

    Copy-Item -LiteralPath $Package.GetAttribute("Source") `
              -Destination $DestinationPath `
              -Recurse
  }
}
#endregion

#region Media Write to ISO/USB
function Write-InstBuilderISO {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )

  Write-Verbose "Writing install media content to iso."

  $cmpParams = New-Object System.CodeDom.Compiler.CompilerParameters -Property @{
    CompilerOptions = "/unsafe"
    WarningLevel = 4
    TreatWarningsAsErrors = $true
  }

  Add-Type -CompilerParameters $cmpParams -TypeDefinition @"
  using System;
  using System.IO;
  using System.Runtime.InteropServices.ComTypes;

  namespace InstBuilder {
    public static class ISOWriter {
      public static void WriteIStreamToFile (object comObject, string fileName) {
        IStream inputStream = comObject as IStream;
        FileStream outputStream = File.OpenWrite(fileName);

        byte[] data;
        int bytesRead;

        do {
          data = Read(inputStream, 2048, out bytesRead);
          outputStream.Write(data, 0, bytesRead);
        } while (bytesRead == 2048);

        outputStream.Flush();
        outputStream.Close();
      }

      unsafe static private byte[] Read(IStream stream, int toRead, out int read) {
        byte[] buffer = new byte[toRead];

        int bytesRead = 0;

        int* ptr = &bytesRead;

        stream.Read(buffer, toRead, (IntPtr)ptr);

        read = bytesRead;

        return buffer;
      }
    }
  }
"@

  $fs = @{
    ISO9660 = 1
    Joliet  = 2
    UDF     = 4
  }

  $platformId = @{
    x86 = 0
    EFI = 0xEF
  }

  $emulationType = @{
    None = 0
  }

  $imgCreator = New-Object -ComObject IMAPI2FS.MsftFileSystemImage

  $imgCreator.FileSystemsToCreate = $fs.UDF
  $imgCreator.FreeMediaBlocks = 0 # No size limit on ISO.

  # I use more verbose means of constructing the $bootOptions array according
  # to BootMode than is normal for me because I'm dealing with COM objects
  # here, with their attendant finickiness w/r/t references. Best to make
  # sure there is only one variable in which to find each COM object.

  if ($Configuration.BootMode -in "Both","Legacy") {
    $bootOptionsMbr = New-Object -ComObject IMAPI2FS.BootOptions
    $bootStreamMbr = New-Object -ComObject ADODB.Stream
    $bootStreamMbr.Open()
    $bootStreamMbr.Type = 1 # Binary
    $bootStreamMbr.LoadFromFile($Configuration.Paths.BuildISO.ETFSBoot)
    $bootOptionsMbr.AssignBootImage($bootStreamMbr)
    $bootOptionsMbr.PlatformId = $platformId.x86
    $bootOptionsMbr.Emulation = $emulationType.None
  }
  if ($Configuration.BootMode -in "Both","UEFI") {
    $bootOptionsEfi = New-Object -ComObject IMAPI2FS.BootOptions
    $bootStreamEfi = New-Object -ComObject ADODB.Stream
    $bootStreamEfi.Open()
    $bootStreamEfi.Type = 1 # Binary
    $bootStreamEfi.LoadFromFile($Configuration.Paths.BuildISO.EFISys)
    $bootOptionsEfi.AssignBootImage($bootStreamEfi)
    $bootOptionsEfi.PlatformId = $platformId.EFI
    $bootOptionsEfi.Emulation = $emulationType.None
  }

  if ($Configuration.BootMode -eq "Legacy") {
    $bootOptions = [System.Array]::CreateInstance([Object], 1)
    $bootOptions.SetValue($bootOptionsMbr, 0)
  }
  elseif ($Configuration.BootMode -eq "UEFI") {
    $bootOptions = [System.Array]::CreateInstance([Object], 1)
    $bootOptions.SetValue($bootOptionsEfi, 0)
  }
  elseif ($Configuration.BootMode -eq "Both") {
    $bootOptions = [System.Array]::CreateInstance([Object], 2)
    $bootOptions.SetValue($bootOptionsMbr, 0)
    $bootOptions.SetValue($bootOptionsEfi, 1)
  }

  $imgCreator.BootImageOptionsArray = $bootOptions

  $imgCreatorRoot = $imgCreator.Root

  $imgCreatorRoot.AddTree($Configuration.Paths.Media, $false)

  $resultImage = $imgCreator.CreateResultImage()

  [InstBuilder.ISOWriter]::WriteIStreamToFile(
    $resultImage.ImageStream,
    $Configuration.Paths.BuildISO.Output
  )

  while ([System.Runtime.Interopservices.Marshal]::ReleaseComObject($resultImage) -gt 0) {}
  while ([System.Runtime.Interopservices.Marshal]::ReleaseComObject($imgCreatorRoot) -gt 0) {}

  if ($Configuration.BootMode -in "Both","Legacy") {
    while ([System.Runtime.Interopservices.Marshal]::ReleaseComObject($bootOptionsMbr) -gt 0) {}
    while ([System.Runtime.Interopservices.Marshal]::ReleaseComObject($bootStreamMbr) -gt 0) {}
  }

  if ($Configuration.BootMode -in "Both","UEFI") {
    while ([System.Runtime.Interopservices.Marshal]::ReleaseComObject($bootOptionsEfi) -gt 0) {}
    while ([System.Runtime.Interopservices.Marshal]::ReleaseComObject($bootStreamEfi) -gt 0) {}
  }

  while ([System.Runtime.Interopservices.Marshal]::ReleaseComObject($imgCreator) -gt 0) {}

  [System.GC]::Collect()
  [System.GC]::WaitForPendingFinalizers()
}

function Write-InstBuilderUSB_All {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )
 
  $imageIsOversized = (Get-Item -LiteralPath $Configuration.Paths.InstallImage).Length -ge 4gb

  if ($imageIsOversized) {
    Write-Warning "Install image is oversized (-ge 4gb)."

    $WriteMode = $Configuration.WorkflowSettings.BuildUSB.BigImageMode
  }
  else {
    $WriteMode = "Normal"
  }

  if ($WriteMode -eq "ExFAT") {
    Write-Warning "USB will have a single 'ExFAT' volume, and will be incompatible with UEFI Boot Mode."
  }
  elseif ($WriteMode -eq "DualPartition") {
    Write-Warning "USB will have separate boot and data volumes. Builds -lt 15063 are incompatible."

    $pathsNode = $Configuration.SelectSingleNode("Paths")

    $pathsNode.AppendChild(
      $Configuration.
      OwnerDocument.
      CreateElement("Media_Boot")
    ).InnerXml = New-Item -Path $Configuration.Paths.Scratch `
                          -Name Media_Boot `
                          -ItemType Directory |
                   ForEach-Object FullName

    $pathsNode.AppendChild(
      $Configuration.
      OwnerDocument.
      CreateElement("Media_Data")
    ).InnerXml = $Configuration.Paths.Media

    Get-ChildItem -LiteralPath $Configuration.Paths.Media -Force |
      Where-Object Name -in boot,efi,bootmgr,bootmgr.efi |
      Move-Item -Destination $Configuration.Paths.Media_Boot -Force

    $wimDest = New-Item -Path $Configuration.Paths.Media_Boot `
                        -Name sources `
                        -ItemType Directory |
                 ForEach-Object FullName

    Move-Item -LiteralPath $Configuration.Paths.BootImage `
              -Destination $wimDest
  }

  $inc = 1

  $usbTargets = $Configuration.SelectNodes("USBTargets/USBTarget")

  foreach ($usbTarget in $usbTargets) {
    Write-Verbose "Writing install media content to usb [$inc of $($usbTargets.Count)]."

    Write-InstBuilderUSB_Each -Disk (Get-Disk -UniqueId $usbTarget.InnerText) `
                              -Configuration $Configuration `
                              -WriteMode $WriteMode

    $inc++
  }
}
function Write-InstBuilderUSB_Each {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [Microsoft.Management.Infrastructure.CimInstance]
    $Disk,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration,

    [Parameter(
      Mandatory = $true
    )]
    [ValidateSet("Normal", "ExFAT", "DualPartition")]
    [string]
    $WriteMode
  )

  if ($Disk.PartitionStyle -ne "RAW") {
    $Disk |
      Clear-Disk -RemoveData -RemoveOEM -Confirm:$false
  }

  if (($Disk | Get-Disk).PartitionStyle -eq "RAW") {
    $Disk |
      Initialize-Disk -PartitionStyle MBR
  }

  if ($WriteMode -in "Normal","ExFAT") {
    Write-InstBuilderUSB_OnePartition -Disk $Disk `
                                      -Configuration $Configuration `
                                      -WriteMode $WriteMode
  }
  elseif ($WriteMode -in "DualPartition") {
    Write-InstBuilderUSB_TwoPartition -Disk $Disk `
                                      -Configuration $Configuration `
                                      -WriteMode $WriteMode
  }
}
function Write-InstBuilderUSB_OnePartition {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [Microsoft.Management.Infrastructure.CimInstance]
    $Disk,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration,

    [Parameter(
      Mandatory = $true
    )]
    [ValidateSet("Normal", "ExFAT", "DualPartition")]
    [string]
    $WriteMode
  )

  $mbrTypeMap = @{
    Normal = "FAT32"
    ExFAT = "IFS"
  }

  $fsMap = @{
    Normal = "FAT32"
    ExFAT = "ExFAT"
  }

  $Partition = $Disk |
                 New-Partition -MbrType $mbrTypeMap.$WriteMode -UseMaximumSize -IsActive

  $Partition |
    Format-Volume -FileSystem $fsMap.$WriteMode

  $Partition |
    Add-PartitionAccessPath -AssignDriveLetter

  $usbRoot = $Disk |
               Get-Partition |
               Where-Object DriveLetter |
               ForEach-Object {$_.DriveLetter + ":\"}

  do {
    Start-Sleep -Milliseconds 250
  } while ((Get-PSDrive | Where-Object Root -eq $usbRoot) -eq $null)

  Get-ChildItem -LiteralPath $Configuration.Paths.Media -Force |
    Copy-Item -Destination $usbRoot -Recurse -Force

  New-Item -Path $usbRoot `
           -Name createdMedia.log `
           -Value "Created using an automated toolset. Presence of this filepath marks this drive as eligible for scripted one-click overwrite." |
    Out-Null

  Start-Process -FilePath C:\PS\Resources\RemoveDrive.exe `
                -ArgumentList "`"$($driveRoot.Substring(0, 2))`" -l" `
                -PassThru |
    Wait-Process
}
function Write-InstBuilderUSB_TwoPartition {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [Microsoft.Management.Infrastructure.CimInstance]
    $Disk,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration,

    [Parameter(
      Mandatory = $true
    )]
    [ValidateSet("Normal", "ExFAT", "DualPartition")]
    [string]
    $WriteMode
  )

  $bootPartition = $Disk |
                     New-Partition -MbrType FAT32 -Size 512mb -IsActive
  $dataPartition = $Disk |
                     New-Partition -MbrType IFS -UseMaximumSize

  $bootPartition |
    Format-Volume -FileSystem FAT32 |
    Out-Null
  $dataPartition |
    Format-Volume -FileSystem exFAT |
    Out-Null

  $bootPartition,
  $dataPartition |
    Add-PartitionAccessPath -AssignDriveLetter  

  $bootRoot = $Disk |
                Get-Partition |
                Where-Object IsActive -eq $true |
                ForEach-Object {$_.DriveLetter + ":\"}
  $dataRoot = $Disk |
                Get-Partition |
                Where-Object IsActive -eq $false |
                ForEach-Object {$_.DriveLetter + ":\"}

  do {
    Start-Sleep -Milliseconds 250
  } while (@(Get-PSDrive | Where-Object Root -in $bootRoot,$dataRoot).Count -lt 2)

  Get-ChildItem -LiteralPath $Configuration.Paths.Media_Boot -Force |
    Copy-Item -Destination $bootRoot -Force -Recurse
  Get-ChildItem -LiteralPath $Configuration.Paths.Media_Data -Force |
    Copy-Item -Destination $dataRoot -Force -Recurse

  $bootRoot,$dataRoot |
    ForEach-Object {
      New-Item -Path $_ `
               -Name createdMedia.log `
               -Value "Created using an automated toolset. Presence of this filepath marks this drive as eligible for scripted one-click overwrite." |
        Out-Null
    }

  Start-Process -FilePath C:\PS\Resources\RemoveDrive.exe `
                -ArgumentList "`"$($bootRoot.Substring(0, 2))`" -l" `
                -PassThru |
    Wait-Process
}
#endregion

function Invoke-InstBuilderVMAction_Start ($VM) {
  Invoke-InstBuilderVMAction_Reset $VM

  Start-Process -FilePath "$env:SystemRoot\System32\vmconnect.exe" `
                -ArgumentList "localhost -G $($VM.Id)"

  $VM |
    Start-VM
}

function Invoke-InstBuilderVMAction_Stop ($VM) {
  Invoke-InstBuilderVMAction_Reset $VM

  $VM |
    Remove-VM -Force

  Remove-Item -LiteralPath $VM.Path -Recurse -Force
}

function Invoke-InstBuilderVMAction_Reset ($VM) {
  Get-Process |
    Where-Object Name -eq vmconnect |
    Where-Object {
      $vmName = $_.MainWindowTitle -replace " on (?:$([System.Net.Dns]::GetHostName())|localhost) - Virtual Machine Connection$",""

      $vmName -eq $VM.Name
    } |
    Stop-Process

  $VM |
    Where-Object State -ne Off |
    Stop-VM -TurnOff -Force

  $VM |
    Get-VMSnapshot |
    Where-Object ParentSnapshotId -eq $null |
    Restore-VMSnapshot -Confirm:$false
}

function Invoke-InstBuilderVMTest {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )

  Write-Verbose "Running vm test with iso."

  # Troubleshooting an occasional failure to remove the media path.
  Start-Sleep -Seconds 1

  Write-Verbose "  - Building vm."

  $settings = $Configuration.WorkflowSettings.VMTest

  New-Item -Path $Configuration.Paths.VMTest.VHDs -ItemType Directory -Force |
    Out-Null

  New-VHD -Path $Configuration.Paths.VMTest.VHD -SizeBytes $settings.VHDSizeBytes |
    Out-Null

  if ($Configuration.BootMode -eq "Legacy") {
    $VMGeneration = 1
  }
  else {
    $VMGeneration = 2
  }

  $VM = New-VM -Name $Configuration.Name `
               -Path $Configuration.Paths.VMTest.VMBase `
               -VHDPath $Configuration.Paths.VMTest.VHD `
               -Generation $VMGeneration

  $VM |
    Set-VM -ProcessorCount $settings.VMProcessorCount `
           -MemoryStartupBytes $settings.VMMemoryBytes `
           -StaticMemory

  $VM |
    Set-VMProcessor -ExposeVirtualizationExtensions $true

  if ($settings.VMConnectedSwitch -ne "none") {
    $VM |
      Get-VMNetworkAdapter |
      Connect-VMNetworkAdapter -SwitchName $settings.VMConnectedSwitch
  }

  $isoPath = Move-Item -LiteralPath $Configuration.Paths.BuildISO.Output `
                       -Destination $Configuration.Paths.VMTest.VM `
                       -PassThru |
              ForEach-Object FullName

  if ($VMGeneration -eq 1) {
    $VM |
      Get-VMDvdDrive |
      Set-VMDvdDrive -Path $isoPath
  }
  elseif ($VMGeneration -eq 2) {
    $DVD = $VM |
             Add-VMDvdDrive -Path $isoPath

    $VM |
      Set-VMFirmware -FirstBootDevice $DVD
  }

  Write-Verbose "  - Clearing scratch content. (Early, just because we can.)"
  Remove-Item -LiteralPath $Configuration.Paths.Scratch `
              -Recurse `
              -Force `
              -ErrorAction Stop

  if ($settings.TestMode -eq "FromFIN") {
    Write-Verbose "  - Starting vm."
    $VM |
      Start-VM

    Write-Verbose "  - Monitoring vm configuration."
    Start-KvpFinAckHandshake -VMId $VM.Id

    Write-Verbose "  - Stopping vm."
    $VM |
      Stop-VM -Force

    $VM |
      Get-VMDvdDrive |
      Remove-VMDvdDrive
  }

  Write-Verbose "  - Writing test base checkpoint."

  $VM |
    Checkpoint-VM -SnapshotName "VM Test Base Checkpoint"

  Write-Verbose "  - Starting test."

  Write-UserAlertMessage

  Invoke-InstBuilderVMAction_Start $VM

  do {
    $choices = @(
      [System.Management.Automation.Host.ChoiceDescription]::new(
        "&Restart Test",
        "Restart the vm test from the base checkpoint."
      )
      [System.Management.Automation.Host.ChoiceDescription]::new(
        "&End Test",
        "End the vm test and remove resources."
      )
    )

    $result = $Host.UI.PromptForChoice(
      $null,
      "Revert and restart or end the vm test?",
      $choices,
      0
    )

    if ($result -eq 0) {
      Write-Verbose "  - Restarting test."
      Invoke-InstBuilderVMAction_Start $VM
    }

  } while ($result -ne 1)

  Write-Verbose "  - Ending test."
  Invoke-InstBuilderVMAction_Stop $VM
}

#region Exported Functions
function New-InstBuilderConfigurationFile {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Name
  )
  try {
    $configItem = @(
      Get-ChildItem -LiteralPath (Get-Path Configurations) -File -Recurse |
        Where-Object Extension -eq .ps1 |
        Where-Object BaseName -eq $Name
    )

    if ($configItem.Count -gt 0) {
      $exception = [System.Exception]::new("A configuration file with this name already exists in the defined configurations path or a subfolder thereof.")
      $exception.Data.Add("Name", $Name)

      throw $exception
    }

    $configPath = Join-Path -Path (Get-Path Configurations) -ChildPath "$($Name).ps1"

    Copy-Item -LiteralPath (Get-Path ConfigTemplate) -Destination $configPath

    New-InstBuilderShortcuts -Name $Name
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Get-InstBuilderConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Name
  )

  try {
    Write-Verbose "Retrieving configuration from file w/ basename '$Name'."
    $configItem = @(
      Get-ChildItem -LiteralPath (Get-Path Configurations) -File -Recurse |
        Where-Object Extension -eq .ps1 |
        Where-Object BaseName -eq $Name
    )

    if ($configItem.Count -eq 0) {
      $exception = [System.Exception]::new("Named configuration not found in the defined configurations path or a subfolder thereof.")
      $exception.Data.Add("Name", $Name)

      throw $exception
    }

    if ($configItem.Count -gt 1) {
      $exception = [System.Exception]::new("Named configuration exists at multiple locations within the defined configurations path.")
      $exception.Data.Add("Name", $Name)
      $exception.Data.Add("Path1", $configItem[0].DirectoryName)
      $exception.Data.Add("Path2", $configItem[1].DirectoryName)

      throw $exception
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()

    $rs.CreatePipeline($script:resources.ConfigurationCommands).Invoke() | Out-Null
    $rs.CreatePipeline($script:resources.ConfigurationAliases).Invoke() | Out-Null
    $rs.CreatePipeline('$config = New-InstBuilderConfiguration').Invoke() | Out-Null
    
    try {
      $rs.CreatePipeline((Get-Content -LiteralPath $configItem[0].FullName -Raw)).Invoke() | Out-Null
    } catch {
      $exception = [System.Exception]::new(
        "Error while processing config definition file.",
        $_.Exception
      )

      throw $exception
    }

    $config = $rs.CreatePipeline('$config').Invoke()[0]
    $rs.Close()

    if ($config -isnot [System.Xml.XmlElement]) {
      throw "Error while retrieving config definition. Object retrieved was not an XmlElement."
    }

    $nameNode = $config.SelectSingleNode("/Configuration/Name")

    if ($nameNode -isnot [System.Xml.XmlElement]) {
      throw "Error while retrieving config definition. Could not select element node for Name assignment."
    }

    $nameNode.InnerXml = $configItem.BaseName

    Write-Verbose "Validating retrieved configuration against xml schema."
    Test-InstBuilderConfiguration -Configuration $config

    $config
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Test-InstBuilderConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNode]
    $Configuration
  )
  try {
    if ($Configuration -is [System.Xml.XmlElement]) {
      $Configuration = $Configuration.OwnerDocument
    }

    $TestXml = $Configuration.OuterXml -as [xml]
    $TestXml.Schemas.Add($script:resources.ConfigurationSchema) |
      Out-Null
    $TestXml.Validate($null)
  } catch {
    $exception = [System.Exception]::new(
      "Error while validating config definition",
      $_.Exception
    )

    throw $exception
  }
}

function Resolve-InstBuilderConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNode]
    $Configuration,

    [Parameter(
      Mandatory = $true
    )]
    [ValidateSet("NamedConfiguration","SuppliedConfiguration")]
    [string]
    $ResolveMode,
    
    [string]
    $Alternate
  )
  try {
    if ($Configuration -is [System.Xml.XmlElement]) {
      $Configuration = $Configuration.OwnerDocument
    }

    $OutputXml = $BasePassXml = $Configuration.OuterXml -as [xml]

    # This pass of Test-InstBuilderConfiguration is verbose-silent because a
    # "Named" configuration will already have been validated on retrieval,
    # while a "Supplied" configuration should have been validated before
    # being submitted for resolution. This is included as a failsafe.
    Test-InstBuilderConfiguration -Configuration $BasePassXml

    Write-Verbose "Validating & resolving configuration against available resources."
    Resolve-InstBuilderConfiguration_EachPass -Xml $BasePassXml -ResolveMode $ResolveMode

    if ($ResolveMode -eq "NamedConfiguration" -and $Alternate.Length -gt 0) {
      $OutputXml = $AltPassXml = $Configuration.OuterXml -as [xml]

      $AltPassXml.SelectSingleNode("/Configuration/AlternateName").InnerXml = ""
      $AltPassXml.SelectSingleNode("/Configuration/Alternates").InnerXml = ""

      Write-Verbose "Targeting a compiled alternate configuration with name '$Alternate'."
      $compiledAlternates = $BasePassXml.SelectNodes("/Configuration/CompiledAlternates/CompiledAlternate")
      $compiledAlternate = $compiledAlternates |
                             Where-Object Name -eq $Alternate

      if ($compiledAlternate -isnot [System.Xml.XmlElement]) {
        $exception = [System.Exception]::new("Alternate configuration not found.")
        $exception.Data.Add("ConfigurationName", $BasePassXml.Name)
        $exception.Data.Add("AlternateName", $Alternate)

        throw $exception
      }

      $originalName = $Configuration.SelectSingleNode("/Configuration/Name").InnerXml
      $scripts = $compiledAlternate.SelectNodes("Scripts/Script") |
                   ForEach-Object InnerText

      Write-Verbose "Applying $($scripts.Count) transformation script(s) to unresolved configuration to derive the alternate configuration."
      $scriptIndex = 0
      foreach ($script in $scripts) {
        $scriptIndex++

        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()

        $rs.CreatePipeline($script:resources.ConfigurationCommands).Invoke() | Out-Null
        $rs.CreatePipeline($script:resources.ConfigurationAliases).Invoke() | Out-Null

        $pl = $rs.CreatePipeline()
        $cmd = [System.Management.Automation.Runspaces.Command]::new('param($config)', $true)
        $cmd.Parameters.Add(
          [System.Management.Automation.Runspaces.CommandParameter]::new('config', $AltPassXml.SelectSingleNode("/Configuration"))
        )
        $pl.Commands.Add($cmd)
        $pl.Invoke() | Out-Null

        try {
          $rs.CreatePipeline($script).Invoke() | Out-Null
        } catch {
          $exception = [System.Exception]::new(
            "Error while processing transform script for alternate configuration.",
            $_.Exception
          )

          $exception.Data.Add("ConfigurationName", $originalName)
          $exception.Data.Add("AlternateName", $compiledAlternate.Name)
          $exception.Data.Add("ScriptNumber", "$($scriptIndex) of $($scripts.Count)")

          throw $exception
        } finally {
          $rs.Close()
        }
      }

      Write-Verbose "Validating alternate configuration against xml schema."
      Test-InstBuilderConfiguration -Configuration $AltPassXml

      if ($AltPassXml.SelectSingleNode("/Configuration/Name").InnerXml -ne $originalName) {
        throw "Alternate configuration transform scripts may not change the original configuration name."
      }

      Write-Verbose "Validating & resolving alternate configuration against available resources."
      Resolve-InstBuilderConfiguration_EachPass -Xml $AltPassXml -ResolveMode "SuppliedConfiguration"

      $AltPassXml.SelectSingleNode("/Configuration/AlternateName").InnerXml = $compiledAlternate.Name
    }
    elseif ($Alternate.Length -gt 0) {
      throw "An alternate configuration may not be targeted in this context."
    }

    return $OutputXml.SelectSingleNode("/Configuration")
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function New-InstBuilderShortcuts {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Name
  )
  try {
    $config = Get-InstBuilderConfiguration -Name $Name
    $config = Resolve-InstBuilderConfiguration -Configuration $config -ResolveMode NamedConfiguration

    $configPath = Get-ChildItem -LiteralPath (Get-Path Configurations) -File -Recurse |
                    Where-Object Extension -eq .ps1 |
                    Where-Object BaseName -eq $Name |
                    ForEach-Object FullName

    $interfacePath = $configPath.Replace(
      (Get-Path Configurations),
      (Get-Path Interface)
    ) -replace "\.ps1$",""

    if (-not (Test-Path -LiteralPath $interfacePath)) {
      New-Item -Path $interfacePath -ItemType Directory -Force |
        Out-Null
    }
    else {
      Get-ChildItem -LiteralPath $interfacePath |
        Remove-Item -Force
    }

    function New-ShortcutData ($Name, $Params, [switch]$NoExit, [switch]$RunAsAdministrator) {
      [PSCustomObject]@{
        Name               = $Name
        Params             = $Params
        NoExit             = [bool]$NoExit
        RunAsAdministrator = [bool]$RunAsAdministrator
      }
    }

    $shortcutData = @()

    $shortcutData += New-ShortcutData "Update Shortcuts" "Update Shortcuts",$config.Name
    $shortcutData += $null

    $shortcutName = "Start Build"
    if ($config.AlternateName -ne 'n/a') {
      $shortcutName += " ($($config.AlternateName))"
    }
    $shortcutData += New-ShortcutData $shortcutName "Start Build",$config.Name -NoExit -RunAsAdministrator

    $compiledAlternates = $config.SelectNodes("/Configuration/CompiledAlternates/CompiledAlternate/Name") |
                            ForEach-Object InnerXml

    foreach ($alternate in $compiledAlternates) {
      $shortcutData += New-ShortcutData "Start Build ($alternate)" "Start Build",$config.Name,$alternate -NoExit -RunAsAdministrator
    }

  $inc = 1
  foreach ($dataObj in $shortcutData) {
    if ($dataObj -ne $null) {
      $params = @{
        ScriptPath = Get-Path ShortcutHandler
        ShortcutPath = Join-Path -Path $interfacePath -ChildPath "$inc $($dataObj.Name).lnk"
        ScriptParameters = $dataObj.Params
        NoExit = $dataObj.NoExit
        RunAsAdministrator = $dataObj.RunAsAdministrator
      }

      New-ScriptShortcut @params
    }

    $inc++
  }

  New-Shortcut -ShortcutPath (Join-Path -Path $interfacePath -ChildPath "2 Edit Config.lnk") `
               -TargetPath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell_ise.exe" `
               -Arguments "/File `"$configPath`""
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Start-InstBuilder {
  [CmdletBinding(
    PositionalBinding = $false,
    DefaultParameterSetName = "NamedConfiguration"
  )]
  param(
    [Parameter(
      ParameterSetName = "NamedConfiguration",
      Mandatory = $true
    )]
    [string]
    $Name,

    [Parameter(
      ParameterSetName = "NamedConfiguration"
    )]
    [string]
    $Alternate,

    [Parameter(
      ParameterSetName = "SuppliedConfiguration",
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration,

    [ValidateSet("VMTest", "BuildISO", "BuildUSB")]
    $Workflow
  )
  $resultObj = [PSCustomObject]@{
    "Build Origin"           = $null
    "Configuration Name"     = $null
    "Alternate Name"         = $null
    "Raw Configuration"      = $null
    "Resolved Configuration" = $null
    "Workflow"               = $null
    "Processing Status"      = "Initial"
    "Start Time"             = [datetime]::Now
    "End Time"               = $null
    "Duration"               = $null
    "Error Record"           = $null
  }

  try {
    if ($PSCmdlet.ParameterSetName -eq "NamedConfiguration") {
      $resultObj."Build Origin" = "Named"
      $resultObj."Processing Status" = "Retrieving and validating to schema."

      $Configuration = Get-InstBuilderConfiguration -Name $Name
    }
    else {
      $resultObj."Build Origin" = "Supplied"
      $resultObj."Processing Status" = "Validating to schema."

      Write-Verbose "Validating supplied configuration against xml schema."
      Test-InstBuilderConfiguration -Configuration $Configuration
    }

    $resultObj."Configuration Name" = $Configuration.Name
    $resultObj."Raw Configuration" = $Configuration
    $resultObj."Processing Status" = "Validating and resolving to available resources."

    $Configuration = Resolve-InstBuilderConfiguration `
    -Configuration $Configuration `
    -ResolveMode $PSCmdlet.ParameterSetName `
    -Alternate $Alternate

    $resultObj."Alternate Name" = $Configuration.AlternateName
    $resultObj."Processing Status" = "Selecting or validating workflow."

    $Configuration.AppendChild(
      $Configuration.
      OwnerDocument.
      CreateElement("SelectedWorkflow")
    ).InnerXml = Select-InstBuilderWorkflow -Configuration $Configuration -Workflow $Workflow

    $resultObj.Workflow = $Configuration.SelectedWorkflow
    $resultObj."Processing Status" = "Compiling and targeting servicing resources."

    & $PSScriptRoot\InstBuilder.ServicingResourceCompilation.ps1 `
    -Configuration $Configuration `
    -InstBuilderPaths (Get-Path)

    $resultObj."Resolved Configuration" = $Configuration
    $resultObj."Processing Status" = "Validating scratch and output paths."

    Test-InstBuilderServicingPath -Configuration $Configuration

    $resultObj."Processing Status" = "Building install media content."

    Build-InstBuilderMedia -Configuration $Configuration

    if ($Configuration."SelectedWorkflow" -in "VMTest","BuildISO") {
      $resultObj."Processing Status" = "Writing install media content to iso."
      Write-InstBuilderISO -Configuration $Configuration
    }
    if ($Configuration."SelectedWorkflow" -eq "BuildUSB") {
      $resultObj."Processing Status" = "Writing install media content to usb."
      Write-InstBuilderUSB_All -Configuration $Configuration
    }

    if ($Configuration."SelectedWorkflow" -eq "VMTest") {
      $resultObj."Processing Status" = "Running vm test with iso."
      Invoke-InstBuilderVMTest -Configuration $Configuration
    }

    if (Test-Path -LiteralPath $Configuration.Paths.Scratch) {
      $resultObj."Processing Status" = "Clearing scratch content."

      Write-Verbose "Clearing scratch content."
      Remove-Item -LiteralPath $Configuration.Paths.Scratch `
                  -Recurse `
                  -Force # Needed to force removal of "Read Only" items.
    }

    $resultObj."End Time" = [datetime]::Now
    $resultObj."Duration" = $resultObj."End Time" - $resultObj."Start Time"
    $resultObj."Processing Status" = "Complete"
  } catch {
    $resultObj."Error Record" = $_
  }
  $resultObj
}
#endregion

$exportFunctions = @(
  "Set-InstBuilderPath"
  "Get-InstBuilderPath"
  "New-InstBuilderConfigurationFile"
  "Get-InstBuilderConfiguration"
  "Test-InstBuilderConfiguration"
  "Resolve-InstBuilderConfiguration"
  "New-InstBuilderShortcuts"
  "Start-InstBuilder"
)

if ((-not ($PSBoundParameters.ContainsKey("ExportConfigurationCommands"))) -or $ExportConfigurationCommands) {
  $cmdScript = [scriptblock]::Create($script:resources.ConfigurationCommands)

  . $cmdScript

  $exportFunctions += $cmdScript.Ast.EndBlock.Statements |
                        ForEach-Object Name
}

Export-ModuleMember -Function $exportFunctions