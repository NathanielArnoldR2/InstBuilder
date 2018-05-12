function New-InstBuilderConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [ValidateNotNullOrEmpty()]
    [string]
    $Name,

    [ValidateNotNullOrEmpty()]
    [string]
    $OS,

    [ValidateNotNullOrEmpty()]
    [string]
    $OSEdition,

    [bool]
    $OSUpdated,

    [ValidateSet("Both","Legacy","UEFI")]
    [string]
    $BootMode,

    [ValidateNotNullOrEmpty()]
    [hashtable]
    $ScriptParameters,

    # Servicing Scripts have their own cmdlet.

    [ValidateNotNullOrEmpty()]
    [string]
    $UsrClass,

    [ValidateNotNullOrEmpty()]
    [string]
    $Unattend,

    [ValidateNotNullOrEmpty()]
    [string]
    $Script,

    [AllowEmptyCollection()]
    [Object[]]
    $PEDrivers,

    [AllowEmptyCollection()]
    [Object[]]
    $Drivers,

    [AllowEmptyCollection()]
    [Object[]]
    $OfflinePackages,

    [AllowEmptyCollection()]
    [Object[]]
    $Modules,

    [AllowEmptyCollection()]
    [Object[]]
    $Packages,

    [ValidateNotNullOrEmpty()]
    [string]
    $ComputerName,

    [ValidateSet("VMTest","BuildISO","BuildUSB")]
    [string[]]
    $SupportedWorkflows,

    # Workflow Settings have their own cmdlets.

    [ValidateNotNullOrEmpty()]
    [string]
    $AlternateName,

    [PSTypeName("InstBuilderAlternate")]
    [AllowEmptyCollection()]
    [Object[]]
    $Alternates
  )

  $xml = [System.Xml.XmlDocument]::new()

  $xml.AppendChild(
    $xml.CreateElement("Configuration")
  ) | Out-Null

  $cfg = $xml.SelectSingleNode("Configuration")

  $cfg.SetAttribute("xmlns:xsi","http://www.w3.org/2001/XMLSchema-instance")

  "Name",
  "OS",
  "OSEdition",
  "OSUpdated",
  "BootMode",
  "ScriptParameters",
  "ServicingScripts",
  "UsrClass",
  "Unattend",
  "UnattendTransforms",
  "Script",
  "PEDrivers",
  "Drivers",
  "OfflinePackages",
  "Modules",
  "Packages",
  "SupportedWorkflows",
  "WorkflowSettings",
  "AlternateName",
  "Alternates" |
    ForEach-Object {
      $cfg.AppendChild(
        $xml.CreateElement($_)
      ) | Out-Null
    }

  $scripts = $cfg.SelectSingleNode("ServicingScripts")

  "BootImage",
  "InstallImage",
  "Media" |
    ForEach-Object {
      $scripts.AppendChild(
        $xml.
          CreateElement($_)
      ) | Out-Null
    }

  $transforms = $cfg.SelectSingleNode("UnattendTransforms")

  $transforms.AppendChild(
    $xml.CreateElement("ComputerName")
  ) | Out-Null

  $settings = $cfg.SelectSingleNode("WorkflowSettings")

  $wf = @{}

  "VMTest",
  "BuildISO",
  "BuildUSB" |
    ForEach-Object {
      $wf.$_ = $settings.AppendChild(
                 $xml.CreateElement($_)
      )
    }

  "VMProcessorCount",
  "VMMemoryBytes",
  "VMConnectedSwitch",
  "VHDSizeBytes",
  "TestMode" |
    ForEach-Object {
      $wf.VMTest.AppendChild(
        $xml.CreateElement($_)
      ) | Out-Null
    }

  $wf.VMTest.TestMode = "FromInstall"

  $wf.BuildISO.AppendChild(
    $xml.CreateElement("OutputPath")
  ) | Out-Null

  $wf.BuildUSB.AppendChild(
    $xml.CreateElement("BigImageMode")
  ).InnerXml = "ExFAT"

  $setParams = [hashtable]$PSBoundParameters

  if (-not $PSBoundParameters.ContainsKey("BootMode")) {
    $setParams.BootMode = "Both"
  }

  $cfg |
    Set-InstBuilderConfiguration @setParams

  $cfg
}
function Set-InstBuilderConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )

  DynamicParam {
    $params = [System.Management.Automation.RuntimeDefinedParameterDictionary]::new()

    $commonParamNames = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
      [System.Management.Automation.Internal.CommonParameters]
    ) |
      ForEach-Object psobject |
      ForEach-Object Properties |
      ForEach-Object Name

    $sourceParams = Get-Command New-InstBuilderConfiguration |
                      ForEach-Object Parameters |
                      ForEach-Object GetEnumerator |
                      ForEach-Object Value |
                      Where-Object Name -cnotin $commonParamNames

    foreach ($sourceParam in $sourceParams) {
      $param = [System.Management.Automation.RuntimeDefinedParameter]::new(
        $sourceParam.Name,
        $sourceParam.ParameterType,
        $sourceParam.Attributes
      )

      $params.Add(
        $sourceParam.Name,
        $param
      )
    }

    return $params
  }

  process {
    if ($PSBoundParameters.ContainsKey("Name")) {
      $InputObject.Name = $PSBoundParameters.Name
    }

    if ($PSBoundParameters.ContainsKey("OS")) {
      $InputObject.OS = $PSBoundParameters.OS
    }

    if ($PSBoundParameters.ContainsKey("OSEdition")) {
      $InputObject.OSEdition = $PSBoundParameters.OSEdition
    }

    if ($PSBoundParameters.ContainsKey("OSUpdated")) {
      $InputObject.OSUpdated = $PSBoundParameters.OSUpdated.ToString().ToLower()
    }

    if ($PSBoundParameters.ContainsKey("BootMode")) {
      $InputObject.BootMode = $PSBoundParameters.BootMode
    }

    if ($PSBoundParameters.ContainsKey("ScriptParameters")) {
      $paramsNode = $InputObject.SelectSingleNode("ScriptParameters")

      $paramsNode.RemoveAll()

      foreach ($item in $PSBoundParameters.ScriptParameters.GetEnumerator()) {
        $paramNode = $paramsNode.AppendChild(
          $PSBoundParameters.
          InputObject.
          OwnerDocument.
          CreateElement("ScriptParameter")
        )

        $val = $item.Value

        if ($val -is [System.Boolean]) {
          $val = $val.ToString().ToLower()
        }

        $paramNode.SetAttribute("Name", $item.Key)
        $paramNode.SetAttribute("Value", $val)
      }
    }

    if ($PSBoundParameters.ContainsKey("UsrClass")) {
      $InputObject.UsrClass = $PSBoundParameters.UsrClass
    }

    if ($PSBoundParameters.ContainsKey("Unattend")) {
      $InputObject.Unattend = $PSBoundParameters.Unattend
    }

    if ($PSBoundParameters.ContainsKey("Script")) {
      $InputObject.Script = $PSBoundParameters.Script
    }

    if ($PSBoundParameters.ContainsKey("PEDrivers")) {
      $InputObject |
        Get-InstBuilderPackage -PackageType PEDrivers |
        Remove-InstBuilderPackage

      $InputObject |
        Add-InstBuilderPackage -PackageType PEDrivers $PSBoundParameters.PEDrivers
    }

    if ($PSBoundParameters.ContainsKey("Drivers")) {
      $InputObject |
        Get-InstBuilderPackage -PackageType Drivers |
        Remove-InstBuilderPackage

      $InputObject |
        Add-InstBuilderPackage -PackageType Drivers $PSBoundParameters.Drivers
    }

    if ($PSBoundParameters.ContainsKey("OfflinePackages")) {
      $InputObject |
        Get-InstBuilderPackage -PackageType OfflinePackages |
        Remove-InstBuilderPackage

      $InputObject |
        Add-InstBuilderPackage -PackageType OfflinePackages $PSBoundParameters.OfflinePackages
    }

    if ($PSBoundParameters.ContainsKey("Modules")) {
      $InputObject |
        Get-InstBuilderPackage -PackageType Modules |
        Remove-InstBuilderPackage

      $InputObject |
        Add-InstBuilderPackage -PackageType Modules $PSBoundParameters.Modules
    }

    if ($PSBoundParameters.ContainsKey("Packages")) {
      $InputObject |
        Get-InstBuilderPackage -PackageType Packages |
        Remove-InstBuilderPackage

      $InputObject |
        Add-InstBuilderPackage -PackageType Packages $PSBoundParameters.Packages
    }

    if ($PSBoundParameters.ContainsKey("ComputerName")) {
      $InputObject.UnattendTransforms.ComputerName = $PSBoundParameters.ComputerName
    }

    if ($PSBoundParameters.ContainsKey("SupportedWorkflows")) {
      $wfsNode = $InputObject.SelectSingleNode("SupportedWorkflows")

      $wfsNode.RemoveAll()

      foreach ($item in $PSBoundParameters.SupportedWorkflows.GetEnumerator()) {
        $wfsNode.AppendChild(
          $InputObject.
          OwnerDocument.
          CreateElement("SupportedWorkflow")
        ).InnerXml = $item
      }
    }

    if ($PSBoundParameters.ContainsKey("AlternateName")) {
      $InputObject.AlternateName = $PSBoundParameters.AlternateName
    }

    if ($PSBoundParameters.ContainsKey("Alternates")) {
      $InputObject |
        Get-InstBuilderAlternate |
        Remove-InstBuilderAlternate

      $InputObject |
        Add-InstBuilderAlternate $PSBoundParameters.Alternates
    }
  }
}

function Set-InstBuilderServicingScript {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [ValidateNotNullOrEmpty()]
    [string]
    $BootImage,

    [ValidateNotNullOrEmpty()]
    [string]
    $InstallImage,

    [ValidateNotNullOrEmpty()]
    [string]
    $Media
  )

  $scriptsNode = $InputObject.SelectSingleNode("ServicingScripts")

  if ($PSBoundParameters.ContainsKey("BootImage")) {
    $scriptsNode.BootImage = $BootImage
  }

  if ($PSBoundParameters.ContainsKey("InstallImage")) {
    $scriptsNode.InstallImage = $InstallImage
  }

  if ($PSBoundParameters.ContainsKey("Media")) {
    $scriptsNode.Media = $Media
  }
}
function Set-InstBuilderVMTestSetting {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [byte]
    $VMProcessorCount,

    [long]
    $VMMemoryBytes,

    [ValidateNotNullOrEmpty()]
    [string]
    $VMConnectedSwitch,

    [long]
    $VHDSizeBytes,

    [ValidateSet("FromInstall", "FromFIN")]
    [string]
    $TestMode
  )

  $settingsNode = $InputObject.SelectSingleNode("WorkflowSettings/VMTest")

  if ($PSBoundParameters.ContainsKey("VMProcessorCount")) {
    $settingsNode.VMProcessorCount = $VMProcessorCount.ToString()
  }

  if ($PSBoundParameters.ContainsKey("VMMemoryBytes")) {
    $settingsNode.VMMemoryBytes = $VMMemoryBytes.ToString()
  }

  if ($PSBoundParameters.ContainsKey("VMConnectedSwitch")) {
    $settingsNode.VMConnectedSwitch = $VMConnectedSwitch
  }

  if ($PSBoundParameters.ContainsKey("VHDSizeBytes")) {
    $settingsNode.VHDSizeBytes = $VHDSizeBytes.ToString()
  }

  if ($PSBoundParameters.ContainsKey("TestMode")) {
    $settingsNode.TestMode = $TestMode
  }
}
function Set-InstBuilderBuildISOSetting {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [ValidateNotNullOrEmpty()]
    [string]
    $OutputPath
  )

  $settingsNode = $InputObject.SelectSingleNode("WorkflowSettings/BuildISO")

  if ($PSBoundParameters.ContainsKey("OutputPath")) {
    $settingsNode.OutputPath = $OutputPath
  }
}
function Set-InstBuilderBuildUSBSetting {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [ValidateSet("ExFAT", "SplitImage", "DualPartition")]
    [string]
    $BigImageMode
  )

  $settingsNode = $InputObject.SelectSingleNode("WorkflowSettings/BuildUSB")

  if ($PSBoundParameters.ContainsKey("BigImageMode")) {
    $settingsNode.BigImageMode = $BigImageMode
  }
}

function Get-InstBuilderPackage {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [ValidateNotNullOrEmpty()]
    [string]
    $PackageType = "Packages"
  )
  process {
    $InputObject.
      SelectNodes("$PackageType/Package")
  }
}
function New-InstBuilderPackage {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Source,

    [ValidateNotNullOrEmpty()]
    [string]
    $Destination
  )

  $outHash = [hashtable]$PSBoundParameters
  $outHash.PSTypeName = "InstBuilderPackage"

  [PSCustomObject]$outHash
}
function Add-InstBuilderPackage {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [ValidateNotNullOrEmpty()]
    [string]
    $PackageType = "Packages",

    [Parameter(
      Mandatory = $true,
      Position = 0
    )]
    [AllowEmptyCollection()]
    [Object[]]
    $Package
  )

  $packagesNode = $InputObject.SelectSingleNode($PackageType)

  foreach ($PackageItem in $Package) {
    if ($PackageItem -is [string]) {
      $PackageItem = New-InstBuilderPackage -Source $PackageItem
    }

    if ($PackageItem.psobject.TypeNames[0] -cne "InstBuilderPackage") {
      throw "Invalid package. Object was not an 'InstBuilderPackage', or a string source from which a package could be constructed."
    }

    $packageNode = $packagesNode.AppendChild(
      $InputObject.
        OwnerDocument.
        CreateElement("Package")
    )

    $packageNode.SetAttribute("Source", $PackageItem.Source)
    $packageNode.SetAttribute("Destination", $PackageItem.Destination)
  }
}
function Remove-InstBuilderPackage {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )
  process {
    $InputObject.
      ParentNode.
      RemoveChild($InputObject) |
      Out-Null
  }
}

function Get-InstBuilderAlternate {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )
  process {
    $InputObject.
      SelectNodes("Alternates/Alternate")
  }
}
function New-InstBuilderAlternate {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Name,

    [string[]]
    $Targets,

    [Parameter(
      Mandatory = $true
    )]
    [scriptblock]
    $Script,

    [switch]
    $AppendName
  )

  $outHash = @{
    PSTypeName = "InstBuilderAlternate"
    Name       = $Name
    Targets    = $Targets
    Script     = $Script
    AppendName = [bool]$AppendName
  }

  [PSCustomObject]$outHash
}
function Add-InstBuilderAlternate {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [Parameter(
      Mandatory = $true,
      Position = 0
    )]
    [PSTypeName("InstBuilderAlternate")]
    [AllowEmptyCollection()]
    [Object[]]
    $Alternate
  )

  $alternatesNode = $InputObject.SelectSingleNode("Alternates")

  foreach ($AlternateItem in $Alternate) {
    $alternateNode = $alternatesNode.AppendChild(
      $InputObject.
        OwnerDocument.
        CreateElement("Alternate")
    )

    $alternateNode.AppendChild(
      $InputObject.
        OwnerDocument.
        CreateElement("Name")
    ) | Out-Null

    $alternateNode.Name = $AlternateItem.Name

    $targetsNode = $alternateNode.AppendChild(
      $InputObject.
        OwnerDocument.
        CreateElement("Targets")
    )

    foreach ($target in $AlternateItem.Targets) {
      $targetNode = $targetsNode.AppendChild(
        $InputObject.
         OwnerDocument.
         CreateElement("Target")
      )

      $targetNode.AppendChild(
        $InputObject.
          OwnerDocument.
          CreateTextNode($target)
      ) | Out-Null
    }

    "Script",
    "AppendName" |
      ForEach-Object {
        $alternateNode.AppendChild(
          $InputObject.
            OwnerDocument.
            CreateElement($_)
        ) | Out-Null
      }

    $alternateNode.Script = $AlternateItem.Script.ToString()
    $alternateNode.AppendName = $AlternateItem.AppendName.ToString().ToLower()
  }
}
function Remove-InstBuilderAlternate {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )
  process {
    $InputObject.
      ParentNode.
      RemoveChild($InputObject) |
      Out-Null
  }
}