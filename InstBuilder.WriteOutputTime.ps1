$writeOutputTime = @{
  Mode         = "Time"      # Time/Duration
  DurationMode = "FromStart" # FromStart/FromLastOutput
  OutputFormat = "Short"     # Short/Long
  ReferenceTime = $null
}
function Get-WriteOutputTime {
  $now = [datetime]::Now

  if ($script:writeOutputTime.Mode -eq "Time") {
    if ($script:writeOutputTime.OutputFormat -eq "Short") {
      $now.ToString("HH:mm")
    }
    elseif ($script:writeOutputTime.OutputFormat -eq "Long") {
      $now.ToString("HH:mm:ss.fff")
    }
  }
  elseif ($script:writeOutputTime.Mode -eq "Duration") {
    if ($script:writeOutputTime.ReferenceTime -isnot [datetime]) {
      $script:writeOutputTime.ReferenceTime = $now
    }

    $duration = $now - $script:writeOutputTime.ReferenceTime

    if ($script:writeOutputTime.OutputFormat -eq "Short") {
      "+" + $duration.ToString("hh\:mm")
    }
    elseif ($script:writeOutputTime.OutputFormat -eq "Long") {
      "+" + $duration.ToString("hh\:mm\:ss\.fff")
    }

    if ($script:writeOutputTime.DurationMode -eq "FromStart") {}
    elseif ($script:writeOutputTime.DurationMode -eq "FromLastOutput") {
      $script:writeOutputTime.ReferenceTime = $now
    }
  }
}
function Write-Verbose ($Message) {
  $stored = $Host.PrivateData.VerboseForegroundColor
  $Host.PrivateData.VerboseForegroundColor = "White"
  $Host.PrivateData.VerboseBackgroundColor = $Host.UI.RawUI.BackgroundColor

  Microsoft.PowerShell.Utility\Write-Verbose -Message "[$(Get-WriteOutputTime)] $($Message)"

  $Host.PrivateData.VerboseForegroundColor = $stored
  $Host.PrivateData.VerboseBackgroundColor = $Host.UI.RawUI.BackgroundColor
}
function Write-Warning ($Message) {
  $stored = $Host.PrivateData.WarningForegroundColor
  $Host.PrivateData.WarningForegroundColor = "Yellow"
  $Host.PrivateData.WarningBackgroundColor = $Host.UI.RawUI.BackgroundColor

  Microsoft.PowerShell.Utility\Write-Warning -Message "[$(Get-WriteOutputTime)] $($Message)"

  $Host.PrivateData.WarningForegroundColor = $stored
  $Host.PrivateData.WarningBackgroundColor = $Host.UI.RawUI.BackgroundColor
}