# All-users profile for the PC node. Loads the Windows-cmdlet emulation (which also provides the
# Windows-style `ping` and `ipconfig`) and sets a prompt that names the node, so every screenshot
# shows which PC it came from.

Import-Module NetCompat

function prompt { "PS $([System.Net.Dns]::GetHostName())> " }
