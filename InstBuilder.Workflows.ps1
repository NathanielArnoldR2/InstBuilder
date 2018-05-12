function New-InstBuilderWorkflow {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Name,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $DisplayName,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Description
  )

  [PSCustomObject]@{
    Name        = $Name
    DisplayName = $DisplayName
    Description = $Description
  }
}

New-InstBuilderWorkflow `
-Name VMTest `
-DisplayName "VM Test" `
-Description "Create iso install media and attach to a new vm for testing. Delete all resources after."

New-InstBuilderWorkflow `
-Name BuildISO `
-DisplayName "Build ISO" `
-Description "Create iso install media in the output path."

New-InstBuilderWorkflow `
-Name BuildUSB `
-DisplayName "Build USB(s)" `
-Description "Create usb install media from compatible thumb drives attached to the system."