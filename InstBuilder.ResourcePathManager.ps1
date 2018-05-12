$paths = @()

function New-PathObj {
  param(
    [string]
    $Token,

    [ValidateSet('File', 'Directory')]
    [string]
    $Type,

    [switch]
    $AutoCreate
  )

  $Script:paths += [PSCustomObject]@{
    Token      = $Token
    Type       = $Type
    Path       = $null
    AutoCreate = [bool]$AutoCreate
  }
}

function Get-PathObj ([string]$Token) {
  $pathObj = @(
    $Script:paths |
      Where-Object Token -ceq $Token
  )

  if ($pathObj.Count -ne 1) {
    throw "Token must match exactly one path object. Token `"$Token`" matched $($pathObj.Count) objects."
  }

  $pathObj[0]
}

function Set-InstBuilderPath {
  [CmdletBinding(
    DefaultParameterSetName = "SingleToken",
    PositionalBinding = $false
  )]
  param(

    [Parameter(
      ParameterSetName = "SingleToken",
      Mandatory = $true,
      Position = 0
    )]
    [string]
    $Token,

    [Parameter(
      ParameterSetName = "SingleToken",
      Mandatory = $true,
      Position = 1
    )]
    [string]
    $Path,

    [Parameter(
      ParameterSetName = "MultiToken",
      Mandatory = $true,
      Position = 0
    )]
    [hashtable]
    $AssociationTable,

    [switch]
    $PassThru
  )

  if ($PSCmdlet.ParameterSetName -eq "MultiToken") {
    $AssociationTable.GetEnumerator() |
      ForEach-Object {
        Set-Path -Token $_.Key -Path $_.Value
      }

    if ($PassThru) {
      return $AssociationTable
    }
    else {
      return
    }
  }

  $pathObj = Get-PathObj $Token

  if ($pathObj.Path -ne $null) {
    throw "Path for Token `"$Token`" has already been set."
  }

  try {
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
      throw
    }

    $pathRoot = [System.IO.Path]::GetPathRoot($Path)

    # Allowing paths rooted to local drives or to network shares.
    if ($pathRoot -cnotlike "[A-Z]:\" -and $pathRoot -notlike "\\*\*") {
      throw
    }

    if (-not (Test-Path -LiteralPath $Path -IsValid -ErrorAction Stop)) {
      throw
    }

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

    if ($Path -cne $resolvedPath) {
      throw
    }
  } catch {
    throw "Path provided for Token `"$Token`" must be rooted and absolute, and must reside at a lettered local path or on a network share."
  }

  $pathExists = Test-Path -LiteralPath $Path -ErrorAction Stop

  if ((-not $pathExists) -and (-not $pathObj.AutoCreate)) {
    throw "Path provided for Token `"$Token`" does not already exist, and cannot be created on demand."
  }

  if ($pathExists) {
    $pathTypeMap = @{
      File      = [System.IO.FileInfo]
      Directory = [System.IO.DirectoryInfo]
    }

    if ((Get-Item -LiteralPath $Path -ErrorAction Stop) -isnot ($pathTypeMap.($pathObj.Type))) {
      throw "Path provided for Token `"$Token`" exists, but was not a $($pathObj.Type), as proscribed by the configuration."
    }
  }

  $pathObj.Path = $Path

  if ($PassThru) {
    return $Path
  }
}

function Get-InstBuilderPath ([string]$Token) {
  if ($PSBoundParameters.Keys -notcontains "Token") {
    $outHash = @{}

    $script:paths |
      Where-Object Path -ne $null |
      ForEach-Object {
        $outHash.($_.Token) = $_.Path
      }

    return $outHash
  }

  $pathObj = Get-PathObj $Token

  if ($pathObj.Path -eq $null) {
    throw "No path has been set for Token `"$Token`"."
  }

  $pathExists = Test-Path -LiteralPath $pathObj.Path -ErrorAction Stop

  if ((-not $pathExists) -and (-not $pathObj.AutoCreate)) {
    throw "Path set for Token `"$Token`" does not already exist, and cannot be created on demand."
  }

  if (-not $pathExists) {
    New-Item -Path $pathObj.Path -ItemType $pathObj.Type -ErrorAction Stop |
      Out-Null
  }

  return $pathObj.Path
}

New-PathObj OSData          File
New-PathObj Configurations  Directory

New-PathObj ISO             Directory
New-PathObj WIM             Directory
New-PathObj Unattends       Directory
New-PathObj UsrClass        Directory

New-PathObj Modules         Directory
New-PathObj Packages        Directory

New-PathObj Scratch         Directory -AutoCreate
New-PathObj VMTestLoads     Directory -AutoCreate

New-PathObj ConfigTemplate  File
New-PathObj ShortcutHandler File

New-PathObj Interface       Directory -AutoCreate
New-PathObj Output          Directory -AutoCreate

New-Alias -Name Set-Path -Value Set-InstBuilderPath
New-Alias -Name Get-Path -Value Get-InstBuilderPath