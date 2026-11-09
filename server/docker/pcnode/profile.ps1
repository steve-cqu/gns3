# All-users profile for the PC node. Loads the Windows-cmdlet emulation (which also provides the
# Windows-style `ping` and `ipconfig`) and sets a prompt that names the node, so every screenshot
# shows which PC it came from.

Import-Module NetCompat

# Keep command history in memory only (up-arrow still works within a session). Saving it to a file
# makes .NET create /root/.dotnet/corefx/Runtime/SharedMemory as root 0700, for PSReadLine's
# history-file mutex, after GNS3 has handed /root back to the gns3 user on stop. GNS3 then cannot
# delete or export the project: 409 "Permission denied: '.dotnet'" (measured 9 Nov 2026, v045 amd64).
Set-PSReadLineOption -HistorySaveStyle SaveNothing

function prompt { "PS $([System.Net.Dns]::GetHostName())> " }
