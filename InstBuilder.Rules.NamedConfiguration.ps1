$Xml.
  SelectSingleNode("/Configuration").
  AppendChild(
    $Xml.CreateElement("CompiledAlternates")
  ) | Out-Null

rule -Individual /Configuration/AlternateName `
     -PrereqScript {
  $nodeValue.Length -gt 0
} `
     -Script $constrainedString `
     -Params @{
  Pattern   = "^[A-Za-z0-9 \-]+$"
  MinLength = 1
  MaxLength = 20
}
rule -Individual /Configuration/AlternateName `
     -Script {
  $alternates = $node.SelectNodes("/Configuration/Alternates/Alternate")

  if ($nodeValue.Length -eq 0 -and $alternates.Count -eq 0) {
    $node.$valProp = "n/a"
    return
  }
  elseif ($nodeValue.Length -eq 0 -and $alternates.Count -gt 0) {
    $node.$valProp = "Base"
    return
  }

  if ($nodeValue.Length -gt 0 -and $alternates.Count -eq 0) {
    throw "AlternateName is only meaningful in the context of defined alternates, and should not be provided where none are defined."
  }
}

$alternatesCount = $Xml.SelectNodes("/Configuration/Alternates/Alternate").Count

rule -Individual /Configuration/Alternates/Alternate/Name `
     -Script $constrainedString `
     -Params @{
  Pattern   = "^[A-Za-z0-9 \-]+$"
  MinLength = 1
  MaxLength = 30
}
rule -Individual /Configuration/Alternates/Alternate/Name `
     -Script {
  if ($nodeValue -eq 'Base') {
    throw "The word 'Base' is reserved in this context, and cannot be used."
  }
}
rule -Aggregate /Configuration/Alternates/Alternate/Name `
     -Script $uniqueness

rule -Individual /Configuration/Alternates/Alternate/Targets `
     -PrereqScript {
  $node.ChildNodes.Count -eq 0
} `
     -Script {
  $target = $node.AppendChild(
    $node.
      OwnerDocument.
      CreateElement("Target")
  )

  $target.InnerXml = "Base"
}

rule -Individual /Configuration/Alternates/Alternate/Targets/Target `
     -Script $constrainedString `
     -Params @{
  Pattern   = "^[A-Za-z0-9 \-*]+$"
  MinLength = 1
  MaxLength = 20
  SkipValidityTest = $true
}
rule -Individual /Configuration/Alternates/Alternate/Targets/Target `
     -Script {
  try {
    [System.Management.Automation.WildcardPattern]::new(
      $nodeValue
    ).IsMatch(
      "Just need the exception."
    ) | Out-Null
  } catch {
    throw "Must be a valid wildcard pattern."
  }
}
1..$alternatesCount |
  ForEach-Object {
    rule -Aggregate /Configuration/Alternates/Alternate[$_]/Targets/Target `
         -Script $uniqueness
  }

1..$alternatesCount |
  ForEach-Object {
    rule -Individual /Configuration/Alternates/Alternate[$_] `
         -Script {
      $compiledAlternatesBase = $node.SelectSingleNode("/Configuration/CompiledAlternates")

      $compiledAlternates = $compiledAlternatesBase.SelectNodes("CompiledAlternate")

      $baseAlternateName = $node.SelectSingleNode("/Configuration/AlternateName").InnerXml

      $targets = $node.SelectNodes("Targets/Target") | ForEach-Object InnerXml

      $compiledTargets = @()
      $targetsBase = $false

      foreach ($target in $targets) {
        if ($target -eq "Base") {
          $targetsBase = $true
          continue
        }

        $compiledTargets += @(
          $compiledAlternates |
            Where-Object Name -like $target |
            Where-Object Name -notin $compiledTargets
        )
      }

      if (($compiledTargets.Count + $targetsBase) -eq 0) {
        throw "Alternate configuration failed to target base configuration or at least one previously compiled alternate."
      }
      if (($compiledTargets.Count + $targetsBase) -gt 1 -and $node.AppendName -ne "true") {
        throw "The 'AppendName' swich must be set when an alternate configuration targets more that one existing configuration."
      }

      if ($targetsBase) {
        $newTarget = $node.
                       OwnerDocument.
                       CreateElement("NewTarget")

        $newTarget.AppendChild(
          $node.
            OwnerDocument.
            CreateElement("Name")
        ) | Out-Null

        $newTarget.Name = $baseAlternateName

        $newTarget.AppendChild(
          $node.
            OwnerDocument.
            CreateElement("Scripts")
        ) | Out-Null

        $compiledTargets = @(
          $newTarget
          $compiledTargets
        )
      }

      foreach ($target in $compiledTargets) {
        $compiledNode = $compiledAlternatesBase.AppendChild(
          $node.
            OwnerDocument.
            CreateElement("CompiledAlternate")
        )

        $compiledNode.InnerXml = $target.InnerXml

        if ($node.AppendName -eq "true") {
          $compiledNode.Name += " + " + $node.Name
        }
        else {
          $compiledNode.Name = $node.Name
        }

        $scriptsNode = $compiledNode.SelectSingleNode("Scripts")

        $scriptNode = $scriptsNode.AppendChild(
          $node.
            OwnerDocument.
            CreateElement("Script")
        )

        $scriptNode.InnerText = $node.Script
      }
    }
  }

rule -Aggregate /Configuration/CompiledAlternates/CompiledAlternate/Name `
     -Script $uniqueness