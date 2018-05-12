$rules = @()
function New-EvaluationRule {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      ParameterSetName = "Individual"
    )]
    [switch]
    $Individual,

    [Parameter(
      ParameterSetName = "Aggregate"
    )]
    [switch]
    $Aggregate,

    [Parameter(
      Mandatory = $true,
      Position = 0
    )]
    [string]
    $XPath,

    [scriptblock]
    $PrereqScript = {$true},

    [Parameter(
      Mandatory = $true,
      Position = 1
    )]
    [scriptblock]
    $Script,

    [Parameter(
      Position = 2
    )]
    [hashtable]
    $Params = @{}
  )

  $rule = [PSCustomObject]@{
    PSTypeName   = "EvaluationRule"
    Mode         = $PSCmdlet.ParameterSetName
    XPath        = $XPath
    PrereqScript = $PrereqScript
    Script       = $Script
    Params       = $Params
  }

  Set-Variable -Scope 1 -Name rules -Value ($rules + $rule)
}
function Invoke-EvaluationRule_Individual_Each {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNode]
    $Node,

    [Parameter(
      Mandatory = $true
    )]
    [PSTypeName("EvaluationRule")]
    [Object]
    $Rule
  )
  try {
    # Prerequisite Test
    $pl = $Host.Runspace.CreateNestedPipeline()
    $cmd = [System.Management.Automation.Runspaces.Command]::new('param($node)', $true)
    $cmd.Parameters.Add(
      [System.Management.Automation.Runspaces.CommandParameter]::new('node', $Node)
    )
    $pl.Commands.Add($cmd)
    if ($Node -is [System.Xml.XmlElement]) {
      $pl.Commands.AddScript('$valProp = "InnerXml"')
    }
    elseif ($Node -is [System.Xml.XmlAttribute]) {
      $pl.Commands.AddScript('$valProp = "#text"')
    }
    $pl.Commands.AddScript('$nodeValue = $node.$valProp')
    $pl.Commands.AddScript($Rule.PrereqScript.ToString())
    try {
      $result = $pl.Invoke()
    } catch {
      throw "$($Rule.Mode) rule for XPath '$($Rule.XPath)' failed prerequisite processing with message: '$($_.Exception.InnerException.Message)'."
    }

    if ($result.Count -ne 1 -or $result[0] -isnot [Boolean]) {
      throw "$($Rule.Mode) rule for XPath '$($Rule.XPath)' failed prerequisite processing with message: 'Unnecessary or unexpected script output. Expected output was a single [Boolean].'."
    }

    if (-not $result[0]) {
      return
    }

    # Test/Transformation
    $pl = $Host.Runspace.CreateNestedPipeline()
    $cmd = [System.Management.Automation.Runspaces.Command]::new('param($node, $params)', $true)
    $cmd.Parameters.Add(
      [System.Management.Automation.Runspaces.CommandParameter]::new('node', $Node)
    )
    $cmd.Parameters.Add(
      [System.Management.Automation.Runspaces.CommandParameter]::new('params', $Rule.Params)
    )
    $pl.Commands.Add($cmd)
    if ($Node -is [System.Xml.XmlElement]) {
      $pl.Commands.AddScript('$valProp = "InnerXml"')
    }
    elseif ($Node -is [System.Xml.XmlAttribute]) {
      $pl.Commands.AddScript('$valProp = "#text"')
    }
    $pl.Commands.AddScript('$nodeValue = $node.$valProp')
    $pl.Commands.AddScript($Rule.Script.ToString())
    try {
      $pl.Invoke() | Out-Null
    } catch {
      throw "$($Rule.Mode) rule for XPath '$($Rule.XPath)' failed with message: '$($_.Exception.InnerException.Message)'."
    }
  }
  catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}
function Invoke-EvaluationRule_Aggregate {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNodeList]
    $NodeList,

    [Parameter(
      Mandatory = $true
    )]
    [PSTypeName("EvaluationRule")]
    [Object]
    $Rule
  )
  try {
    $valProp = [string]::Empty
    $nodeTypes = @(
      $NodeList |
        ForEach-Object GetType |
        Sort-Object -Unique
    )
    if ($nodeTypes.Count -eq 1 -and $nodeTypes[0] -eq [System.Xml.XmlElement]) {
      $valProp = "InnerXml"
    }
    elseif ($nodeTypes.Count -eq 1 -and $nodeTypes[0] -eq [System.Xml.XmlAttribute]) {
      $valProp = "#text"
    }
    $valScript = '$nodeListValues = @($nodeList | ForEach-Object "%%valProp%%")'.Replace("%%valProp%%", $valProp)

    # Prerequisite Test
    $pl = $Host.Runspace.CreateNestedPipeline()
    $cmd = [System.Management.Automation.Runspaces.Command]::new('param($nodeList)', $true)
    $cmd.Parameters.Add(
      [System.Management.Automation.Runspaces.CommandParameter]::new('nodeList', $NodeList)
    )
    $pl.Commands.Add($cmd)
    if ($valProp.Length -gt 0) {
      $pl.Commands.AddScript($valScript)
    }
    $pl.Commands.AddScript($Rule.PrereqScript.ToString())
    try {
      $result = $pl.Invoke()
    } catch {
      throw "$($Rule.Mode) rule for XPath '$($Rule.XPath)' failed prerequisite processing with message: '$($_.Exception.InnerException.Message)'."
    }

    if ($result.Count -ne 1 -or $result[0] -isnot [Boolean]) {
      throw "$($Rule.Mode) rule for XPath '$($Rule.XPath)' failed prerequisite processing with message: 'Unnecessary or unexpected script output. Expected output was a single [Boolean].'."
    }

    if (-not $result[0]) {
      return
    }

    # Test/Transformation
    $pl = $Host.Runspace.CreateNestedPipeline()
    $cmd = [System.Management.Automation.Runspaces.Command]::new('param($nodeList, $params)', $true)
    $cmd.Parameters.Add(
      [System.Management.Automation.Runspaces.CommandParameter]::new('nodeList', $NodeList)
    )
    $cmd.Parameters.Add(
      [System.Management.Automation.Runspaces.CommandParameter]::new('params', $Rule.Params)
    )
    $pl.Commands.Add($cmd)
    if ($valProp.Length -gt 0) {
      $pl.Commands.AddScript($valScript)
    }
    $pl.Commands.AddScript($Rule.Script.ToString())
    try {
      $pl.Invoke() | Out-Null
    } catch {
      throw "$($Rule.Mode) rule for XPath '$($Rule.XPath)' failed with message: '$($_.Exception.InnerException.Message)'."
    }
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}
function Invoke-EvaluationRules {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlDocument]
    $Xml,

    [Parameter(
      Mandatory = $true
    )]
    [PSTypeName("EvaluationRule")]
    [Object[]]
    $Rules
  )
  try {
    $nsm = [System.Xml.XmlNamespaceManager]::new($Xml.NameTable)
    $nsm.AddNamespace("xsi", $Xml.Configuration.xsi)

    foreach ($rule in $Rules) {
      $nodeList = $Xml.SelectNodes($rule.XPath, $nsm)

      if ($rule.Mode -eq "Individual") {
        foreach ($node in $nodeList) {
          Invoke-EvaluationRule_Individual_Each -Node $node -Rule $rule
        }
      }
      elseif ($rule.Mode -eq "Aggregate") {
        Invoke-EvaluationRule_Aggregate -NodeList $nodeList -Rule $rule
      }
    }
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}