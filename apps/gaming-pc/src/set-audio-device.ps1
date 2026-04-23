Import-Module AudioDeviceCmdlets

Get-AudioDevice -List |
  Where-Object { $_.Type -eq 'Playback' -and $_.Name -imatch 'denon' } |
  Set-AudioDevice
