#!/bin/bash
# Self-test for the Lab Router's IOS-style front end, run INSIDE a Lab Router node. Not shipped.
#   bash ios-cli.selftest.sh
# Uses GigabitEthernet3 with a throwaway address and leaves it as it found it (unsaved).
# Prints PASS/FAIL lines; exit code = number of failures.
fail=0
run() { printf '%s\n' "$@" | python3 /usr/local/bin/ios-cli 2>&1; }
check() {  # name, regex, output
    if printf '%s' "$3" | grep -Eq -- "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=$((fail+1)); fi
}
h=$(cat /run/ios-hostname /etc/frr/ios-hostname 2>/dev/null | head -1); [ -n "$h" ] || h=$(hostname)

o=$(run 'show ip interface brief')
check 'user mode prompt and sh ip int br header' "^${h}>Interface +IP-Address +OK\? Method Status +Protocol" "$o"
o=$(run 'show running-config')
check 'show running-config refused in user mode' "Invalid input detected at '\^' marker" "$o"
o=$(run 'blah')
check 'unknown word: IOS translating message' 'Unknown command or computer name' "$o"
o=$(run enable c)
check 'ambiguous abbreviation' '% Ambiguous command:  "c"' "$o"
o=$(run enable 'conf t' 'int gi3' 'ip address 10.250.0.1')
check 'incomplete command' '% Incomplete command\.' "$o"
o=$(run enable 'conf t' 'int gi3' 'ip address 10.250.0.300 255.255.255.0')
check 'bad address: caret' "Invalid input detected" "$o"
o=$(run enable 'conf t' 'int gi3' 'ip address 10.250.0.1 255.255.255.0' 'no shutdown' 'end' 'sh ip int br')
check 'ip address with dotted mask applied' 'GigabitEthernet3 +10\.250\.0\.1 +YES manual up +up' "$o"
check 'config mode banner' 'Enter configuration commands, one per line\.  End with CNTL/Z\.' "$o"
check 'end prints SYS-5-CONFIG_I' '%SYS-5-CONFIG_I: Configured from console by console' "$o"
o=$(run 'sh int gi3')
check 'show interfaces gi3 (user mode, abbreviated)' 'GigabitEthernet3 is up, line protocol is up' "$o"
check 'show interfaces: address line' 'Internet address is 10\.250\.0\.1/24' "$o"
o=$(run 'show ip route')
check 'show ip route: connected + local' 'C +10\.250\.0\.0(/24)? is directly connected, GigabitEthernet3' "$o"
check 'show ip route: local /32' 'L +10\.250\.0\.1(/32)? is directly connected, GigabitEthernet3' "$o"
o=$(run enable 'conf t' 'ip route 10.251.0.0 255.255.0.0 10.250.0.2' 'do show ip route' 'ip route 10.252.0.1 255.255.0.0 10.250.0.2')
check 'static route shown with [1/0] via' 'S +10\.251\.0\.0(/16)? \[1/0\] via 10\.250\.0\.2' "$o"
check 'inconsistent address and mask' '%Inconsistent address and mask' "$o"
o=$(run enable 'show running-config')
check 'running-config: dotted mask' ' ip address 10\.250\.0\.1 255\.255\.255\.0' "$o"
check 'running-config: ip route line' 'ip route 10\.251\.0\.0 255\.255\.0\.0 10\.250\.0\.2' "$o"
o=$(run enable 'conf t' 'int gi3' 'shutdown' 'end' 'sh ip int br')
check 'shutdown: administratively down' 'GigabitEthernet3 +10\.250\.0\.1 +YES manual administratively down down' "$o"
o=$(run enable 'ping 127.0.0.1')
check 'ping: IOS layout' 'Success rate is 100 percent \(5/5\)' "$o"
o=$(run enable 'show interfaces gi9')
check 'nonexistent port: caret' "Invalid input detected" "$o"
o=$(run enable 'show arp')
check 'show arp header' 'Protocol +Address +Age \(min\) +Hardware Addr +Type +Interface' "$o"
# clean up: back to no address, shut, no test route (unsaved)
run enable 'conf t' 'no ip route 10.251.0.0 255.255.0.0 10.250.0.2' 'int gi3' 'no ip address' 'no shutdown' 'end' >/dev/null
o=$(run 'sh ip int br')
check 'cleanup: Gi3 unassigned again' 'GigabitEthernet3 +unassigned' "$o"
echo '---'
echo "$fail failure(s)"
exit $fail
