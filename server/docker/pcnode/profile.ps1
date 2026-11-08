# All-users profile for the PC node. Loads the Windows-cmdlet emulation and sets a prompt that
# names the node, so every screenshot shows which PC it came from.

Import-Module NetCompat

function prompt { "PS $([System.Net.Dns]::GetHostName())> " }

# Linux `ping` never stops without a count; Windows `ping` sends 4. Translate the two Windows
# switches students use (-n count, -t forever) and pass everything else through.
function ping {
    $out = [System.Collections.Generic.List[string]]::new()
    $count = '4'
    for ($i = 0; $i -lt $args.Count; $i++) {
        $a = [string]$args[$i]
        if ($a -eq '-n' -and $i + 1 -lt $args.Count) { $count = [string]$args[++$i] }
        elseif ($a -eq '-t') { $count = $null }
        elseif ($a -eq '-c' -and $i + 1 -lt $args.Count) { $count = [string]$args[++$i] }
        else { $out.Add($a) }
    }
    if ($count) { /bin/ping -c $count @out } else { /bin/ping @out }
}
