$OSData = & (Get-Path OSData)

function New-PackageType {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $TypeName,
    
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $DefaultSource,

    [string]
    $DefaultDestination,

    [switch]
    $AllowCustomSource,

    [switch]
    $AllowCustomDestination
  )

  $outObj = [PSCustomObject]@{
    TypeName               = $TypeName
    DefaultSource          = $DefaultSource
    DefaultDestination     = $null
    AllowCustomSource      = [bool]$AllowCustomSource
    AllowCustomDestination = [bool]$AllowCustomDestination
  }

  if ($PSBoundParameters.ContainsKey("DefaultDestination")) {
    $outObj.DefaultDestination = $DefaultDestination
  }

  $outObj
}

$packageTypes = @(
  New-PackageType -TypeName PEDrivers `
                  -DefaultSource (Get-Path Packages) `
                  -AllowCustomSource

  New-PackageType -TypeName Drivers `
                  -DefaultSource (Get-Path Packages) `
                  -AllowCustomSource

  New-PackageType -TypeName OfflinePackages `
                  -DefaultSource (Get-Path Packages) `
                  -AllowCustomSource

  New-PackageType -TypeName Modules `
                  -DefaultSource (Get-Path Modules) `
                  -DefaultDestination CT\Modules `
                  -AllowCustomSource

  New-PackageType -TypeName Packages `
                  -DefaultSource (Get-Path Packages) `
                  -DefaultDestination "CT\Packages" `
                  -AllowCustomSource `
                  -AllowCustomDestination
)

function Get-WimPath {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration,

    [switch]
    $Updated
  )

  $filePrefix = $OSData.OperatingSystems |
                  Where-Object Name -eq $Configuration.OS |
                  ForEach-Object FilePrefix

  $updatedMap = @{
    $true  = "Updated"
    $false = "Not Updated"
  }

  $wimBaseName = @(
    $filePrefix
    $Configuration.OSEdition
    $updatedMap.[bool]$Updated
  ) -join ' - '

  $wimName = $wimBaseName + ".wim"

  Join-Path -Path (Get-Path WIM) -ChildPath $wimName
}

function Test-IsValidComputerName {
  param(
    [string]
    $Name
  )
  try {
    if ($Name.Length -ne $Name.Trim().Length) {
      return $false
    }

    if ($Name.Length -lt 1 -or $Name.Length -gt 15) {
      return $false
    }

    if ($Name -notmatch "^[A-Z0-9\-]+$") {
      return $false
    }

    if ($Name[0] -eq "-" -or $Name[-1] -eq "-") {
      return $false
    }

    return $true
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Test-IsValidRootedPath {
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Path,

    [boolean]
    $ShouldExist,

    [System.Type]
    $ItemType
  )
  try {
    if ($Path -notmatch "^[A-Z]:\\" -and $Path -notmatch "^\\\\") {
      return $false
    }

    if (-not (Test-Path -LiteralPath $Path -IsValid -ErrorAction Stop)) {
      return $false
    }

    if (-not ($PSBoundParameters.ContainsKey("Should Exist"))) {
      return $true
    }

    $pathExists = Test-Path -LiteralPath $Path -ErrorAction Stop

    if ($pathExists -ne $ShouldExist) {
      return $false
    }

    if (-not $ShouldExist) {
      return $true
    }

    $item = Get-Item -LiteralPath $Path

    if ($Path -ne $item.FullName) {
      return $false
    }

    if ($ItemType -and $item -isnot $ItemType) {
      return $false
    }

    return $true
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

$constrainedString = {
  if ($nodeValue.Length -ne $nodeValue.Trim().Length) {
    throw "Value had leading or trailing whitespace."
  }

  if ($nodeValue.Length -lt $params.MinLength -or $nodeValue.Length -gt $params.MaxLength) {
    throw "Value did not meet length constraint of $($params.MinLength) min or $($params.MaxLength) max."
  }

  if ($nodeValue.Contains("\")) {
    throw "Value contained ('\') path separator character."
  }

  if ($nodeValue -notmatch $params.Pattern) {
    throw "Value did not match expected pattern '$($params.Pattern)'."
  }

  if ($params.SkipValidityTest) {
    return
  }

  $testPath = Join-Path -Path C:\ -ChildPath $nodeValue -ErrorAction Stop

  if (-not (Test-Path -LiteralPath $testPath -IsValid -ErrorAction Stop)) {
    throw "Value failed 'Test-Path -IsValid' validity failsafe."
  }
}
$vhdDefaultSize = {
  $node.$valProp = 40gb
}
$vhdSize = {
  if ([int64]$nodeValue -ne 40gb -and [int64]$nodeValue -lt 60gb) {
    throw "Value must be exactly 40gb or no less than 60gb to avoid edge cases in size comparison."
  }

  if (([int64]$nodeValue % 1gb) -ne 0) {
    throw "Value must be evenly divisible by 1gb."
  }
}
$packageSource = {
  $typeObj = $packageTypes |
               Where-Object TypeName -eq $params.PackageType

  $packageInDefaultSource = Get-ChildItem -LiteralPath $typeObj.DefaultSource |
                              Where-Object Name -eq $nodeValue |
                              ForEach-Object FullName

  if ($packageInDefaultSource -is [string]) {
    # Other means of setting this value (e.g $node.$valProp) were ineffective.
    $node.OwnerElement.SetAttribute("Source", $packageInDefaultSource)
    return
  }

  if (-not ($typeObj.AllowCustomSource)) {
    throw "No item with this name was found in the default source location for this package type, and the type is not configured to allow custom source locations."
  }

  if (-not (Test-IsValidRootedPath -Path $nodeValue)) {
    throw "No item with this name was found in the default source location for this package type, and the value did not match the format expected of a rooted path to content in a custom source location on a local volume or network share."
  }

  if (-not (Test-IsValidRootedPath -Path $nodeValue -ShouldExist $true -ErrorAction Stop)) {
    throw "A package from a custom source location must be a rooted, direct path to an existing file or folder on a local volume or network share."
  }
}
$driverInfs = {
  $infs = @(
    Get-ChildItem -LiteralPath $nodeValue -File -Recurse |
      Where-Object Extension -eq .inf
  )

  if ($infs.Count -eq 0) {
    throw "Each driver source path must contain one or more .inf files."
  }
}
$packageDest = {
  $typeObj = $packageTypes |
               Where-Object TypeName -eq $params.PackageType

  if ($nodeValue.Length -eq 0 -and $typeObj.DefaultDestination -isnot [string]) {
    $node.OwnerElement.SetAttribute("Destination", "n/a")
    return
  }
  elseif ($nodeValue.Length -gt 0 -and ($typeObj.DefaultDestination -isnot [string] -or (-not $typeObj.AllowCustomDestination))) {
    throw "Packages defined in '$($params.PackageType)' context may not set a custom destination."
  }

  if ($nodeValue.Length -eq 0) {
    $node.OwnerElement.SetAttribute("Destination", $typeObj.DefaultDestination.Trim("\"))
    return
  }

  if ($nodeValue -match "^[A-Z]:\\" -or $nodeValue -match "^\\\\") {
    throw "Custom Destination must be a relative path, considered by reference to the root of the destination volume."
  }

  try {
    $testPath = Join-Path -Path $env:SystemDrive -ChildPath $nodeValue -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $testPath -IsValid -ErrorAction Stop)) {
      throw
    }
  } catch {
    throw "Custom destination failed path validity test."
  }

  $node.OwnerElement.SetAttribute("Destination", $nodeValue.Trim("\"))
}
$notApplicable = {
  foreach ($naNodeName in $params.NANodeNames) {
    $naNode = $node.SelectSingleNode($naNodeName)

    if ($naNode.InnerXml.Length -eq 0) {
      $naNode.InnerXml = "n/a"
    }
    else {
      throw "The value at '$naNodeName' is incompatible with value '$nodeValue' at this node."
    }
  }
}

$uniqueness = {
  $uniqueValues = @(
    $nodeListValues |
      Sort-Object -Unique
  )

  if ($nodeListValues.Count -ne $uniqueValues.Count) {
    throw "List contained duplicate values."
  }
}
$uniqueness_nonEmpty = {
  $nonEmpty = @(
    $nodeListValues |
      Where-Object Length -gt 0
  )

  $uniqueValues = @(
    $nonEmpty |
      Sort-Object -Unique
  )

  if ($nonEmpty.Count -ne $uniqueValues.Count) {
    throw "Non-empty items from list contained duplicate values."
  }
}
$atLeastOne = {
  if ($nodeList.Count -eq 0) {
    throw "List contained no members."
  }
}

rule -Individual /Configuration/Name $constrainedString @{
  MinLength = 1
  MaxLength = 36
  Pattern   = "^[A-Za-z0-9 \-+()]+$"
}

rule -Individual /Configuration/OS `
     -Script {
  $os = @(
    $OSData.OperatingSystems |
      Where-Object {
        $_.Name -eq $nodeValue -or
        $_.Targeting -contains $nodeValue
      }
  )

  if ($os.Count -ne 1) {
    throw "Value could not be used to target a known os. $($os.Count) operating systems matched."
  }

  $isoPath = Join-Path -Path (Get-Path ISO) -ChildPath "$($os.FilePrefix).iso"

  if (-not (Test-Path -LiteralPath $isoPath)) {
    throw "No iso file was found at the expected path for this OS."
  }

  $node.$valProp = $os[0].Name

  $pathsNode = $node.
               SelectSingleNode(".."). # Configuration
               AppendChild(
    $node.
    OwnerDocument.
    CreateElement("Paths")
  )

  $sourceNode = $pathsNode.AppendChild(
    $node.
    OwnerDocument.
    CreateElement("Source")
  )

  $sourceNode.AppendChild(
    $node.
    OwnerDocument.
    CreateElement("ISO")
  ).InnerXml = $isoPath
}

rule -Individual /Configuration/OSEdition `
     -Script {
  $os = $node.SelectSingleNode("../OS").InnerXml

  $osEditions = @(
    $OSData.OperatingSystems |
      Where-Object Name -eq $os |
      ForEach-Object Editions
  )

  if ($nodeValue.Length -eq 0) {
    $node.$valProp = $osEditions[0]
    return
  }

  if ($nodeValue -notin $osEditions) {
    $targetedEdition = @(
      $OSData.Editions |
        Where-Object Name -in $osEditions |
        Where-Object Targeting -contains $nodeValue |
        ForEach-Object Name
    )

    if ($targetedEdition.Count -eq 1) {
      $nodeValue = $targetedEdition[0]
    }
  }

  if ($nodeValue -notin $osEditions) {
    throw "Unable to target by name or abbreviation an edition of the selected os."
  }

  # Enforce canonical capitalization.
  $node.$valProp = $osEditions | Where-Object {$_ -eq $nodeValue}
}

rule -Individual /Configuration/OSUpdated `
     -Script {
  $cfgNode = $node.SelectSingleNode("..")

  $wimPaths = @{
    Updated    = Get-WimPath -Configuration $cfgNode -Updated:$true
    NotUpdated = Get-WimPath -Configuration $cfgNode -Updated:$false
  }

  $testResults = @{
    Updated    = Test-Path -LiteralPath $wimPaths.Updated
    NotUpdated = Test-Path -LiteralPath $wimPaths.NotUpdated
  }

  $updatedMap = @{
    true  = "Updated"
    false = "NotUpdated"
  }

  if ($nodeValue.Length -eq 0) {
    $node.$valProp = $testResults.Updated.ToString().ToLower()
  }

  if (-not $testResults.($updatedMap.($node.$valProp))) {
    throw "No wim file was found at the path indicated by OS and Edition settings."
  }

  $sourceNode = $cfgNode.SelectSingleNode("Paths/Source")

  $sourceNode.AppendChild(
    $node.
    OwnerDocument.
    CreateElement("WIM")
  ).InnerXml = $wimPaths.($updatedMap.($node.$valProp))
}

rule -Individual /Configuration/ServicingScripts/BootImage `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = "none"
}

rule -Individual /Configuration/ServicingScripts/InstallImage `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = "none"
}

rule -Individual /Configuration/ServicingScripts/Media `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = "none"
}

rule -Individual /Configuration/UsrClass `
     -PrereqScript {
  $nodeValue -ne "none"
} `
     -Script {
  if ($nodeValue.Length -eq 0) {
    $node.$valProp = 'none'
    return
  }

  $usrClassBase = Get-Path UsrClass

  if ($nodeValue -eq 'default') {
    $usrClass = @(
      Get-ChildItem -LiteralPath $usrClassBase |
        Where-Object Extension -eq .dat |
        Where-Object BaseName -match \.default$ |
        ForEach-Object FullName
    )

    if ($usrClass.Count -ne 1) {
      throw "Unable to target a default UsrClass hive file."
    }
  }
  else {
    $usrClass = @(
      Get-ChildItem -LiteralPath $usrClassBase |
        Where-Object Extension -eq .dat |
        Where-Object {
          $comparisonName = $_.BaseName -replace "\.default$",""
          $comparisonName -eq $nodeValue
        } |
        ForEach-Object FullName
    )

    if ($usrClass.Count -ne 1) {
      throw "Unable to target a UsrClass hive file using the value provided."
    }
  }

  $node.$valProp = $usrClass[0]
}

rule -Individual /Configuration/Unattend `
     -PrereqScript {
  $nodeValue -eq "none"
} `
     -Script $notApplicable `
     -Params @{
  NANodeNames = @(
    "../UnattendTransforms/ComputerName"
  )
}

rule -Individual /Configuration/UnattendTransforms/ComputerName `
     -PrereqScript {
  $nodeValue -ne "n/a"
} `
     -Script {
  if ($nodeValue.Length -eq 0) {
    $node.$valProp = "*"
    return
  }

  if (-not (Test-IsValidComputerName $nodeValue)) {
    throw "ComputerName value was not a valid computer name."
  }
}

rule -Individual /Configuration/Unattend `
     -PrereqScript {
  $nodeValue -ne "none"
} `
     -Script {
  $unattendBase = Get-Path Unattends
  $os = $node.SelectSingleNode("../OS").InnerXml
  $osEdition = $node.SelectSingleNode("../OSEdition").InnerXml

  $filePrefix = $OSData.OperatingSystems |
                  Where-Object Name -eq $OS |
                  ForEach-Object FilePrefix

  $subPath = $filePrefix,$osEdition -join " - "

  $unattendBase = Join-Path -Path $unattendBase -ChildPath $subPath

  if (-not (Test-Path -LiteralPath $unattendBase)) {
    throw "Could not find a path for unattend files specific to the provided os/edition."
  }

  if ($nodeValue.Length -eq 0) {
    $unattend = @(
      Get-ChildItem -LiteralPath $unattendBase |
        Where-Object BaseName -match \.default$ |
        ForEach-Object FullName
    )

    if ($unattend.Count -ne 1) {
      throw "Unable to target a default unattend xml file."
    }
  }
  else {
    $unattend = @(
      Get-ChildItem -LiteralPath $unattendBase |
        Where-Object {
          $comparisonName = $_.BaseName -replace "\.default$",""
          $comparisonName -eq $nodeValue
        } |
        ForEach-Object FullName
    )

    if ($unattend.Count -ne 1) {
      throw "Unable to target a unattend xml file using the value provided."
    }
  }

  $unattendXml = [xml](
    Get-Content -LiteralPath $unattend -Raw
  )

  $cn = $node.SelectSingleNode("../UnattendTransforms/ComputerName").InnerXml

  $nsm = [System.Xml.XmlNamespaceManager]::new($unattendXml.NameTable)
  $nsm.AddNamespace("urn", $unattendXml.unattend.xmlns)

  $cnNode = $unattendXml.SelectNodes(
    "/urn:unattend/urn:settings[@pass='specialize']/urn:component[@name='Microsoft-Windows-Shell-Setup']/urn:ComputerName",
    $nsm
  )

  # If the cn to be assigned is a random ('*') value lack of a ComputerName
  # node has no impact, since this is default behavior.
  if ($cnNode.Count -gt 1 -or ($cnNode.Count -eq 0 -and $cn -ne "*")) {
    throw "Unable to target an unambiguous 'ComputerName' node in the unattend markup. $($cnNode.Count) matching node(s) were found."
  }
  elseif ($cnNode.Count -eq 1) {
    $cnNode = $cnNode[0]

    $cnNode.InnerXml = $cn
  }

  $node.InnerText = $unattendXml.OuterXml
}

rule -Individual /Configuration/Script `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = "none"
}

# Requires knowing all Script values.
rule -Individual /Configuration/ScriptParameters `
     -Script {
  $scripts = @(
    $node.SelectSingleNode("../ServicingScripts/BootImage").InnerXml
    $node.SelectSingleNode("../ServicingScripts/InstallImage").InnerXml
    $node.SelectSingleNode("../ServicingScripts/Media").InnerXml
    $node.SelectSingleNode("../Script").InnerXml
  )

  $presentScripts = @(
    $scripts |
      Where-Object {$_ -ne 'none'}
  )

  if ($presentScripts.Count -eq 0 -and $nodeValue.Length -eq 0) {
    $node.$valProp = "n/a"
    return
  }
  elseif ($presentScripts.Count -eq 0) {
    throw "ScriptParameters are only relevant in the context of servicing and online scripts, and should not be specified when none are provided."
  }

  # Write-Warning when "Modules" does not contain "Common", which exposes ScriptParameters to the online Script?
}
rule -Individual /Configuration/ScriptParameters/ScriptParameter/@Name `
     -Script $constrainedString `
     -Params @{
  Pattern   = "^[A-Za-z0-9]+$"
  MinLength = 1
  MaxLength = 20
}
rule -Aggregate /Configuration/ScriptParameters/ScriptParameter/@Name `
     -Script $uniqueness

rule -Individual /Configuration/PEDrivers/Package/@Source `
     -Script $packageSource `
     -Params @{
  PackageType = "PEDrivers"
}
rule -Individual /Configuration/PEDrivers/Package/@Source `
     -Script $driverInfs
rule -Individual /Configuration/PEDrivers/Package/@Destination `
     -Script $packageDest `
     -Params @{
  PackageType = "PEDrivers"
}

rule -Individual /Configuration/Drivers/Package/@Source `
     -Script $packageSource `
     -Params @{
  PackageType = "Drivers"
}
rule -Individual /Configuration/Drivers/Package/@Source `
     -Script $driverInfs
rule -Individual /Configuration/Drivers/Package/@Destination `
     -Script $packageDest `
     -Params @{
  PackageType = "Drivers"
}

rule -Individual /Configuration/OfflinePackages/Package/@Source `
     -Script $packageSource `
     -Params @{
  PackageType = "OfflinePackages"
}
rule -Individual /Configuration/OfflinePackages/Package/@Source `
     -Script {
  $item = Get-Item -LiteralPath $nodeValue

  if ($item -is [System.IO.DirectoryInfo]) {
    $item = @(
      $item |
        Get-ChildItem -File |
        Where-Object Extension -in .cab,.msu
    )

    if ($item.Count -ne 1) {
      throw "If a folder is provided, it must contain exactly one file with the extension '.cab' or '.msu'. $($item.Count) files matching this criteria were found."
    }

    $item = $item[0]
  }

  if ($item.Extension -notin ".cab",".msu") {
    throw "An OfflinePackage source must be a single .cab or .msu file, or a folder containing exactly one file that matches this description."
  }

  $node.OwnerElement.SetAttribute("Source", $item.FullName)
}
rule -Individual /Configuration/OfflinePackages/Package/@Destination `
     -Script $packageDest `
     -Params @{
  PackageType = "OfflinePackages"
}

rule -Individual /Configuration/Modules/Package/@Source `
     -Script $packageSource `
     -Params @{
  PackageType = "Modules"
}
rule -Individual /Configuration/Modules/Package/@Destination `
     -Script $packageDest `
     -Params @{
  PackageType = "Modules"
}

rule -Individual /Configuration/Packages/Package/@Source `
     -Script $packageSource `
     -Params @{
  PackageType = "Packages"
}
rule -Individual /Configuration/Packages/Package/@Destination `
     -Script $packageDest `
     -Params @{
  PackageType = "Packages"
}

rule -Individual /Configuration/SupportedWorkflows `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  "VMTest",
  "BuildISO",
  "BuildUSB" |
    ForEach-Object {
      $node.AppendChild(
        $node.
        OwnerDocument.
        CreateElement("SupportedWorkflow")
      ).InnerXml = $_
    }
}
rule -Aggregate /Configuration/SupportedWorkflows/SupportedWorkflow `
     -Script $uniqueness

rule -Individual /Configuration/WorkflowSettings/VMTest/VMProcessorCount `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = "4"
}
rule -Individual /Configuration/WorkflowSettings/VMTest/VMProcessorCount `
     -Script {
  $processorCountMax = (Get-VMHost).LogicalProcessorCount

  if ([int]$nodeValue -lt 1 -or [int]$nodeValue -gt $processorCountMax) {
    throw "Value was not within the range of logical processors supported by this virtualization host: 1 min, $($processorCountMax) max."
  }
}

rule -Individual /Configuration/WorkflowSettings/VMTest/VMMemoryBytes `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = 16gb
}
rule -Individual /Configuration/WorkflowSettings/VMTest/VMMemoryBytes `
     -Script {
  if ([int]$nodeValue -ne 512mb -and ([int]$nodeValue % 1gb) -ne 0) {
    throw "Value must be exactly 512mb, or an exact multiple of 1gb."
  }
}

rule -Individual /Configuration/WorkflowSettings/VMTest/VMConnectedSwitch `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = 'none'
}
rule -Individual /Configuration/WorkflowSettings/VMTest/VMConnectedSwitch `
     -PrereqScript {
  $nodeValue -ne 'none'
} `
     -Script {
  $switches = @(
    Get-VMSwitch |
      Where-Object Name -eq $nodeValue
  )

  if ($switches.Count -ne 1) {
    throw "Found $($switches.Count) switches with this name. Exactly 1 is required."
  }
}

rule -Individual /Configuration/WorkflowSettings/VMTest/VHDSizeBytes `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = 1tb
}
rule -Individual /Configuration/WorkflowSettings/VMTest/VHDSizeBytes `
     -Script {
  if ([int]$nodeValue -lt 500gb -or ([int]$nodeValue % 1gb) -ne 0) {
    throw "Value must be an exact multiple of 1gb, no less than 500gb."
  }
}

rule -Individual /Configuration/WorkflowSettings/VMTest/TestMode `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = "FromInstall"
}

rule -Individual /Configuration/WorkflowSettings/BuildISO/OutputPath `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $node.$valProp = Get-Path Output
}
rule -Individual /Configuration/WorkflowSettings/BuildISO/OutputPath `
     -Script {
  if (-not (Test-IsValidRootedPath -Path $nodeValue)) {
    throw "The output path must be a valid filesystem path on a local volume or network share."
  }

  if ($nodeValue -match "[^\\]\.iso$") {
    $folderName = Split-Path -LiteralPath $nodeValue
  }
  else {
    $folderName = $nodeValue

    $configName = $node.SelectSingleNode("/Configuration/Name").InnerXml
    $node.$valProp = Join-Path -Path $nodeValue -ChildPath "$($configName).iso"
  }

  if (-not (Test-IsValidRootedPath -Path $folderName -ShouldExist $true -ItemType ([System.IO.DirectoryInfo]))) {
    throw "The output path must refer to an existing folder, or an iso file to be placed in an existing folder."
  }
}

rule -Individual /Configuration/WorkflowSettings/BuildUSB/BigImageMode `
     -Script {
  if ($nodeValue -eq "SplitImage") {
    throw "Not implemented."
  }
}

if ($ResolveMode -eq "NamedConfiguration") {
  . $PSScriptRoot\InstBuilder.RuleEvaluator.Rules.NamedConfiguration.ps1
}
elseif ($ResolveMode -eq "SuppliedConfiguration") {
  . $PSScriptRoot\InstBuilder.RuleEvaluator.Rules.SuppliedConfiguration.ps1
}