<#
.SYNOPSIS
    Create the Windows Host VM beside the GNS3 VM, on VirtualBox, unattended.

.DESCRIPTION
    Run this ONCE on your own PC, in a normal PowerShell window. It does on your behalf
    what Steps 3 and 4 of the Windows Host guide ask you to do by hand: it creates a
    Windows 11 virtual machine with the two network adapters the lab needs, and starts
    VirtualBox's own unattended installer against a Windows ISO you have downloaded.

    Windows then installs itself, which takes 30 to 60 minutes, and the machine reboots
    into a working desktop with no questions asked.

    What it does:
      - creates a VM (EFI firmware, TPM 2.0) that meets Windows 11's requirements rather
        than bypassing them
      - gives it two adapters: NAT for the internet, and an Internal Network named cqulab
        for the lab. Two adapters is the part people get wrong by hand
      - runs `VBoxManage unattended install`, which supplies the product-key prompt, the
        account and the locale so nobody sits and clicks
      - optionally runs configure-windows-host.ps1 inside Windows afterwards, which is what
        makes the machine answer a ping and accept ssh

    What it does NOT do:
      - it does not touch the GNS3 VM. The third adapter on the GNS3 VM (Step 2 of the
        guide) is still yours to add, and nothing here checks that you have
      - it does not download a Windows ISO. Microsoft's licence is yours to accept, so the
        download stays a thing you do deliberately
      - it does not activate Windows. Unactivated Windows 11 runs indefinitely for lab work
      - it does not create the cqulab network. VirtualBox makes an Internal Network exist
        the moment a VM refers to it, so there is nothing to create - but that also means a
        typo in the name is not an error, it is a second, empty network. Type it carefully
      - it does not configure anything inside GNS3

    Safe to re-run: if the VM already exists it says so and stops, rather than building a
    second one or destroying your work. Use -Force to delete and rebuild it.

.PARAMETER IsoPath
    Path to the Windows 11 ISO you downloaded. Required unless -List.

.PARAMETER Name
    Name of the VM in VirtualBox. Defaults to WindowsHost, which is what the guide uses.

.PARAMETER LabNetwork
    Name of the VirtualBox Internal Network shared with the GNS3 VM. Defaults to cqulab.
    It must match the GNS3 VM's Adapter 3 exactly - VirtualBox will not warn you.

.PARAMETER MemoryMB
    RAM for the Windows VM, in MB. Defaults to 4096. You need this much again for the GNS3
    VM, which is why the guide asks for 16 GB in the machine.

.PARAMETER CPUs
    Processor count. Defaults to 2.

.PARAMETER DiskGB
    Virtual disk size, in GB. Defaults to 64.

.PARAMETER User
    Local account to create. Defaults to gns3, as in the guide.

.PARAMETER Password
    Password for that account. Defaults to gns3. This is a lab machine on an isolated
    network; if that is not true of yours, pass something else.

.PARAMETER ComputerName
    Windows computer name. Defaults to WinHost.

.PARAMETER LabIPAddress
    Static address for the lab adapter, passed through to configure-windows-host.ps1.
    Defaults to 10.10.1.20. Pass an empty string to leave the adapter on DHCP, which is
    what you want if your topology runs a DHCP server.

.PARAMETER Locale
    Installation locale. Defaults to en_AU.

.PARAMETER Edition
    Which Windows edition to install, by name. Defaults to Windows 11 Education, which is
    what the lab standardises on: it has the Remote Desktop server that Home lacks, and the
    Enterprise-grade security features (AppLocker, Application Control, Credential Guard,
    the full BitLocker policy set) that Pro does not have. It installs with no product key
    like any other edition.

    A retail "consumer editions" ISO holds about a dozen images, and Windows Setup takes
    the first - Home - unless told otherwise. This script asks the ISO what it contains
    (`VBoxManage unattended detect`) and converts the name into the index Setup wants, so
    nothing here depends on a number that differs between ISOs. If the name is not on your
    ISO, the script lists what is and stops.

.PARAMETER ImageIndex
    The image index to install, when you would rather name a number than an edition.
    Overrides -Edition and skips the lookup. Index 1 is Home on a retail ISO. List them
    with:

        VBoxManage unattended detect --iso=<path to the .iso>

.PARAMETER ProductKey
    Product key passed to Windows Setup. You should not need this: the script already
    supplies Microsoft's published generic volume-licence key (GVLK) for whichever edition
    -Edition names, which is what stops Setup halting on the product key screen.

    A GVLK is not anybody's licence. Microsoft publishes one per edition so that an
    unattended install can name an edition without a real key; it selects the edition and
    does not activate. Pass -ProductKey only to use a different key, such as a CQU Azure
    Education key you do want to activate with.

    Source: https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys

.PARAMETER SkipConfigure
    Do not run configure-windows-host.ps1 after the install. The machine then installs but
    does not answer a ping - you run the script yourself, per Step 5 of the guide.

.PARAMETER NoStart
    Build the VM and prepare the unattended install, but do not start it.

.PARAMETER Force
    Delete an existing VM of the same name first. This destroys that machine and its disk.

.PARAMETER DryRun
    Print every VBoxManage command that would run, and run none of them.

.PARAMETER List
    Report what is already here - VirtualBox, the VM, the lab network - and change nothing.

.EXAMPLE
    .\New-WindowsHost.ps1 -IsoPath C:\Users\me\Downloads\Win11_24H2_English_x64.iso

.EXAMPLE
    .\New-WindowsHost.ps1 -IsoPath .\Win11.iso -LabIPAddress '' -SkipConfigure

.EXAMPLE
    .\New-WindowsHost.ps1 -List
#>

[CmdletBinding()]
param(
    [string] $IsoPath,
    [string] $Name         = 'WindowsHost',
    [string] $LabNetwork   = 'cqulab',
    [int]    $MemoryMB     = 4096,
    [int]    $CPUs         = 2,
    [int]    $DiskGB       = 64,
    [string] $User         = 'gns3',
    [string] $Password     = 'gns3',
    [string] $ComputerName = 'WinHost',
    [string] $LabIPAddress = '10.10.1.20',
    [string] $Locale       = 'en_AU',
    [string] $Edition      = 'Windows 11 Education',
    [int]    $ImageIndex   = 0,
    [string] $ProductKey   = '',
    [switch] $SkipConfigure,
    [switch] $NoStart,
    [switch] $Force,
    [switch] $DryRun,
    [switch] $List
)

$ErrorActionPreference = 'Stop'

# Where configure-windows-host.ps1 is fetched from when -SkipConfigure is not given. Same
# URL the guide tells students to paste, so there is one place to change it.
$ConfigureUrl = 'https://raw.githubusercontent.com/steve-cqu/gns3/refs/heads/main/server/windows/configure-windows-host.ps1'

$script:Steps  = 0
$script:Failed = 0

function Report-Step    { param($What, $Detail) Write-Host ("  {0}  {1,-24} {2}" -f $(if ($DryRun) {'would  '} else {'done   '}), $What, $Detail) -ForegroundColor Green; $script:Steps++ }
function Report-Ok      { param($What, $Detail) Write-Host ("  ok       {0,-24} {1}" -f $What, $Detail) }
function Report-Failed  { param($What, $Detail) Write-Host ("  FAILED   {0,-24} {1}" -f $What, $Detail) -ForegroundColor Red; $script:Failed++ }

# --------------------------------------------------------------------------- #
# Find VBoxManage
#
# It is not on the PATH of a default VirtualBox install on Windows, which is the first
# thing that stops this script on a student machine. Look where it actually is.
# --------------------------------------------------------------------------- #
function Find-VBoxManage {
    $cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Each of these environment variables is empty on a machine that has never had
    # VirtualBox installed - including a Windows PC where it simply is not installed yet.
    # Join-Path throws on an empty path, and $ErrorActionPreference is 'Stop', so building
    # this list unconditionally killed the script right here with "Cannot bind argument to
    # parameter 'Path' because it is null" - instead of reaching the message below that
    # says what to do about it. Found 20 September 2026.
    $candidates = @()
    if ($env:VBOX_MSI_INSTALL_PATH) { $candidates += (Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe') }
    if ($env:ProgramFiles)          { $candidates += (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe') }
    if (${env:ProgramFiles(x86)})   { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Oracle\VirtualBox\VBoxManage.exe') }

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

$vbox = Find-VBoxManage
if (-not $vbox) {
    Write-Host "VBoxManage was not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "VirtualBox does not put it on the PATH, so this is normal even on a machine"
    Write-Host "where VirtualBox works. Either install VirtualBox 7 from https://www.virtualbox.org/,"
    Write-Host "or if it is already installed, open its folder and run this script from there."
    exit 1
}

# Finding the program is not the same as the program working: a half-removed install, or a
# launcher that rejects the name it was called by, both answer here rather than several
# steps later, where the failure reads as something else entirely. `VBoxManage --version`
# prints a version string and nothing else, e.g. 7.0.20r163906.
$script:VBoxVersion = ''
$global:LASTEXITCODE = 0
try { $script:VBoxVersion = ((& $vbox --version 2>&1) -join '').Trim() } catch { $script:VBoxVersion = '' }
if ($LASTEXITCODE -ne 0 -or $script:VBoxVersion -notmatch '^\d+\.\d+') {
    Write-Host "VBoxManage was found, but it did not run." -ForegroundColor Red
    Write-Host ""
    Write-Host "  $vbox"
    if ($script:VBoxVersion) { Write-Host "  answered: $script:VBoxVersion" }
    Write-Host ""
    Write-Host "Nothing has been changed. Check that VirtualBox itself starts, then run this"
    Write-Host "script again. Every step below depends on this one program."
    exit 1
}

# Run a VBoxManage command. Honours -DryRun by printing instead of running. Returns the
# output so callers can read it; throws on a non-zero exit so a failed step is not
# mistaken for a successful one.
function Invoke-VBox {
    param([string[]] $Arguments, [switch] $AllowFailure, [switch] $Quiet)

    if ($DryRun -and -not $Quiet) {
        Write-Host ("      VBoxManage " + ($Arguments -join ' ')) -ForegroundColor DarkGray
        return ''
    }
    $out = & $vbox @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw ("VBoxManage " + ($Arguments -join ' ') + "`n" + ($out -join "`n"))
    }
    return ($out -join "`n")
}

# Turn an edition name into the image index Windows Setup wants.
#
# VBoxManage only accepts --image-index, but indexes are a property of the ISO, not of
# Windows: 4 is Education on the September 2026 consumer ISO and could be anything on the
# next one. So ask the ISO. `VBoxManage unattended detect` prints one line per image:
#
#     Image #4     = Windows 11 Education (10.0.26200.6584 / x64 / en-US)
#
# Matched exactly, because "Windows 11 Education" is a prefix of "Windows 11 Education N",
# which is a different edition with no Media Player and no reason to be installed by
# accident.
# Microsoft's published generic volume-licence keys, one per edition. They answer Setup's
# product key question and select an edition; they do not activate anything. Copied from
# learn.microsoft.com/windows-server/get-started/kms-client-activation-keys (read 20 Sep
# 2026). An edition missing from this table simply gets no key, and Setup will ask.
$GvlkByEdition = @{
    'Windows 11 Home'                     = ''
    'Windows 11 Pro'                      = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
    'Windows 11 Pro N'                    = 'MH37W-N47XK-V7XM9-C7227-GCQG9'
    'Windows 11 Pro for Workstations'     = 'NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J'
    'Windows 11 Pro Education'            = '6TP4R-GNPTD-KYYHQ-7B7DP-J447Y'
    'Windows 11 Education'                = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
    'Windows 11 Education N'              = '2WH4N-8QGBV-H22JP-CT43Q-MDWWJ'
    'Windows 11 Enterprise'               = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
    'Windows 11 Enterprise N'             = 'DPH2V-TTNVB-4X9Q3-TJR4H-KHJW4'
}

function Resolve-EditionIndex {
    param([string] $IsoFile, [string] $EditionName)

    $out = & $vbox unattended detect "--iso=$IsoFile" 2>&1
    $images = @()
    foreach ($line in $out) {
        $m = [regex]::Match([string]$line, '^\s*Image #(\d+)\s*=\s*(.+?)\s*\(')
        if ($m.Success) {
            $images += [pscustomobject]@{
                Index = [int]$m.Groups[1].Value
                Name  = $m.Groups[2].Value.Trim()
            }
        }
    }

    # A single-image ISO lists nothing to choose between. Index 1 is then the only answer.
    if ($images.Count -eq 0) { return 1 }

    foreach ($img in $images) {
        if ($img.Name -eq $EditionName) { return $img.Index }
    }

    Write-Host "This ISO does not contain '$EditionName'." -ForegroundColor Red
    Write-Host ""
    Write-Host "What it does contain:"
    foreach ($img in $images) { Write-Host ("    {0,2}  {1}" -f $img.Index, $img.Name) }
    Write-Host ""
    Write-Host "Pass one of those names to -Edition, or its number to -ImageIndex."
    exit 1
}

function Test-VMExists {
    param([string] $VMName)
    $list = & $vbox list vms 2>&1
    return ($list -match ('^"' + [regex]::Escape($VMName) + '"'))
}

# --------------------------------------------------------------------------- #
# -List: report and stop
# --------------------------------------------------------------------------- #
if ($List) {
    Write-Host ""
    Write-Host "Windows Host - what is already here" -ForegroundColor Cyan
    Write-Host ""
    Report-Ok "VirtualBox" "$script:VBoxVersion  ($vbox)"

    if (Test-VMExists $Name) {
        $info = & $vbox showvminfo $Name --machinereadable 2>&1
        $state = ($info | Select-String '^VMState=').ToString() -replace '.*="?([^"]*)"?$', '$1'
        Report-Ok "VM '$Name'" "exists, state: $state"
        foreach ($n in 1..2) {
            $nic  = ($info | Select-String "^nic$n=")
            $net  = ($info | Select-String "^intnet$n=")
            if ($nic) {
                $kind = $nic.ToString() -replace '.*="?([^"]*)"?$', '$1'
                $name = if ($net) { $net.ToString() -replace '.*="?([^"]*)"?$', '$1' } else { '' }
                Report-Ok "  adapter $n" ("$kind $name").Trim()
            }
        }
    } else {
        Report-Ok "VM '$Name'" "does not exist - this script would create it"
    }

    Write-Host ""
    Write-Host "The lab network is an Internal Network named '$LabNetwork'. VirtualBox has no"
    Write-Host "list of those - it creates one whenever a VM refers to it - so check the GNS3"
    Write-Host "VM's Adapter 3 by eye and make sure the name matches character for character."
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------------------- #
# Preconditions
# --------------------------------------------------------------------------- #
if (-not $IsoPath) {
    Write-Host "No -IsoPath given." -ForegroundColor Red
    Write-Host ""
    Write-Host "Download a Windows 11 ISO first - it is a free direct download from Microsoft,"
    Write-Host "about 6 GB, and you want the 64-bit version for a PC. Then:"
    Write-Host ""
    Write-Host "    .\New-WindowsHost.ps1 -IsoPath <path to the .iso>"
    exit 2
}

# Windows PowerShell 5.1 is what a student's machine has out of the box, so no PS7-only
# syntax anywhere in this script - `?.` and `??` parse there but fail at runtime.
$resolved = Resolve-Path -LiteralPath $IsoPath -ErrorAction SilentlyContinue
if (-not $resolved) {
    Report-Failed "iso" "no file at the path given to -IsoPath"
    exit 1
}
$IsoPath = $resolved.Path

# Checked BEFORE describing the machine we would build. A refused run that first prints
# "image index 1" and a yellow "Setup WILL stop and ask for a key" is describing a machine
# it is not going to create, and the warning that does not apply is the one that reads
# loudest.
if (Test-VMExists $Name) {
    if (-not $Force) {
        Write-Host "A VM named '$Name' already exists." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Nothing has been changed. If that machine is the one you want, start it from"
        Write-Host "VirtualBox. If it is a half-finished attempt you want to throw away:"
        Write-Host ""
        Write-Host "    .\New-WindowsHost.ps1 -IsoPath `"$IsoPath`" -Force"
        Write-Host ""
        Write-Host "-Force deletes that VM and its disk. There is no undo."
        exit 0
    }
    Write-Host "Deleting the existing VM '$Name' (-Force)..." -ForegroundColor Yellow
    Invoke-VBox @('controlvm', $Name, 'poweroff') -AllowFailure -Quiet | Out-Null
    Invoke-VBox @('unregistervm', $Name, '--delete')
    Report-Step "existing VM" "deleted"
}
# Resolve the edition before anything is created, so an ISO without it costs nothing.
$editionLabel = "image index $ImageIndex  (chosen by number, -ImageIndex)"
if ($ImageIndex -le 0) {
    $ImageIndex   = Resolve-EditionIndex $IsoPath $Edition
    $editionLabel = "$Edition  (image index $ImageIndex on this ISO)"
}

# No key given: use the published GVLK for the edition, so the default run does not stop on
# Setup's product key screen. Naming an edition and then being asked for a key is a pair of
# defaults that disagree.
$keySource = 'supplied'
if (-not $ProductKey -and $GvlkByEdition.ContainsKey($Edition)) {
    $ProductKey = $GvlkByEdition[$Edition]
    $keySource  = "Microsoft's published GVLK for $Edition"
}

Write-Host ""
Write-Host "Creating the GNS3 Windows Host VM" -ForegroundColor Cyan
if ($DryRun) { Write-Host "DRY RUN - no VM will be created." -ForegroundColor Yellow }
Write-Host ""
Write-Host "  name        : $Name"
Write-Host "  iso         : $IsoPath"
Write-Host "  lab network : Internal Network '$LabNetwork'  (must match the GNS3 VM's Adapter 3)"
Write-Host "  hardware    : ${MemoryMB} MB RAM, $CPUs CPUs, ${DiskGB} GB disk, EFI + TPM 2.0"
Write-Host "  account     : $User / $Password, computer name $ComputerName"
Write-Host "  edition     : $editionLabel"
if ($ProductKey) {
    Write-Host "  product key : $keySource - does not activate, and Setup will not ask"
} else {
    Write-Host "  product key : none - Setup WILL stop and ask for one (see -? on -ProductKey)" -ForegroundColor Yellow
}
Write-Host ""

# --------------------------------------------------------------------------- #
# 1. Create the VM
# --------------------------------------------------------------------------- #
Write-Host "Virtual machine"

try {
    Invoke-VBox @('createvm', '--name', $Name, '--ostype', 'Windows11_64', '--register')
    Report-Step "created" "$Name (Windows11_64)"
} catch {
    Report-Failed "created" $_.Exception.Message
    exit 1
}

# Machine folder, so the disk lands beside the VM rather than somewhere surprising.
$vmFolder = $null
if (-not $DryRun) {
    $info = & $vbox showvminfo $Name --machinereadable 2>&1
    $cfg  = ($info | Select-String '^CfgFile=').ToString() -replace '.*="?([^"]*)"?$', '$1'
    $vmFolder = Split-Path -Parent $cfg
} else {
    $vmFolder = "<VM folder>"
}
$diskPath = Join-Path $vmFolder "$Name.vdi"

try {
    Invoke-VBox @('modifyvm', $Name,
                  '--memory',   "$MemoryMB",
                  '--cpus',     "$CPUs",
                  '--firmware', 'efi',
                  '--vram',     '128',
                  '--graphicscontroller', 'vboxsvga',
                  '--audio-driver', 'none',
                  '--clipboard-mode', 'bidirectional')
    Report-Step "hardware" "${MemoryMB} MB, $CPUs CPUs, EFI firmware"
} catch {
    Report-Failed "hardware" $_.Exception.Message
    exit 1
}

# TPM 2.0. Windows 11 requires it, and VirtualBox 7 provides one - so the requirement is
# MET rather than bypassed, which is the whole reason this path was chosen over an answer
# file full of registry bypasses. On a VirtualBox older than 7 this option does not exist,
# and that is worth failing on rather than installing a machine Windows will not update.
try {
    Invoke-VBox @('modifyvm', $Name, '--tpm-type', '2.0')
    Report-Step "tpm" "2.0"
} catch {
    Report-Failed "tpm" "this VirtualBox has no --tpm-type. VirtualBox 7 or later is needed for Windows 11."
    exit 1
}

# Secure Boot. Enrolling Microsoft's signatures into a fresh UEFI variable store is what
# makes Secure Boot usable; the flags for it have moved between VirtualBox releases, so a
# failure here is reported and tolerated. Windows 11 installs with TPM 2.0 and EFI alone.
try {
    Invoke-VBox @('modifynvram', $Name, 'inituefivarstore') -AllowFailure | Out-Null
    Invoke-VBox @('modifynvram', $Name, 'enrollmssignatures')
    Report-Step "secure boot" "Microsoft signatures enrolled"
} catch {
    Write-Host "  note     secure boot              not enrolled on this VirtualBox - continuing" -ForegroundColor Yellow
    Write-Host "                                    (TPM 2.0 + EFI are enough to install Windows 11)" -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------- #
# 2. Disk and drives
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "Storage"

try {
    Invoke-VBox @('createmedium', 'disk', '--filename', $diskPath,
                  '--size', "$($DiskGB * 1024)", '--format', 'VDI')
    Report-Step "disk" "${DiskGB} GB at $diskPath"

    # Four ports, not two. The disk and the Windows ISO take the first two, but
    # `unattended install` then attaches media of its own - the auxiliary ISO carrying the
    # answer file, and the Guest Additions ISO - and needs somewhere to put them.
    Invoke-VBox @('storagectl', $Name, '--name', 'SATA', '--add', 'sata',
                  '--controller', 'IntelAHCI', '--portcount', '4', '--bootable', 'on')
    Invoke-VBox @('storageattach', $Name, '--storagectl', 'SATA', '--port', '0',
                  '--device', '0', '--type', 'hdd', '--medium', $diskPath)

    # Two calls, not one. Creating the drive and inserting the disc are separate
    # operations: with an empty slot, a single call that names a medium goes down
    # VBoxManage's "mount" path and fails with "No drive attached to device slot 0 on
    # port 1 of controller 'SATA'". Attaching `emptydrive` first makes the drive exist.
    # Found on the first real run, VirtualBox 7.0.20, 20 September 2026.
    Invoke-VBox @('storageattach', $Name, '--storagectl', 'SATA', '--port', '1',
                  '--device', '0', '--type', 'dvddrive', '--medium', 'emptydrive')
    Invoke-VBox @('storageattach', $Name, '--storagectl', 'SATA', '--port', '1',
                  '--device', '0', '--type', 'dvddrive', '--medium', $IsoPath)
    Report-Step "controller" "SATA (AHCI), disk on port 0, ISO on port 1"
} catch {
    Report-Failed "storage" $_.Exception.Message
    exit 1
}

# --------------------------------------------------------------------------- #
# 3. The two adapters
#
# Adapter 1 NAT - the internet, which the post-install step needs to fetch the configure
# script, and which students need to install anything at all.
# Adapter 2 Internal Network - the lab. Promiscuous mode stays DENY here: only the GNS3 VM
# carries traffic on behalf of other machines, and Windows only ever receives its own.
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "Network"

try {
    Invoke-VBox @('modifyvm', $Name, '--nic1', 'nat', '--nic-type1', '82540EM')
    Report-Step "adapter 1" "NAT (internet)"

    Invoke-VBox @('modifyvm', $Name, '--nic2', 'intnet', '--intnet2', $LabNetwork,
                  '--nic-type2', '82540EM', '--nic-promisc2', 'deny')
    Report-Step "adapter 2" "Internal Network '$LabNetwork' (the lab)"
} catch {
    Report-Failed "network" $_.Exception.Message
    exit 1
}

# Read back the MAC VirtualBox assigned to adapter 2, and hand THAT to the configure script
# instead of an adapter name.
#
# This cost most of a day on 20 September 2026. The post-install command used to pass
# -LabAdapter 'Ethernet 2', on the reasonable-looking assumption that VirtualBox's NIC 2 is
# the adapter Windows calls "Ethernet 2". On a real machine it was not: Windows called the
# lab adapter "Ethernet" and the NAT adapter "Ethernet 2", complete with an
# "Intel(R) PRO/1000 MT Desktop Adapter #2" description that made the wrong one look right.
# configure-windows-host.ps1 then gave the NAT adapter a static lab address, which removed
# the machine's default route; Windows Update failed minutes later with 0x80240438; and the
# machine had neither internet nor a presence on the lab network, while every step of every
# script reported success.
#
# A Windows adapter name records the order Windows happened to enumerate the hardware in.
# The MAC is the only identifier this side and the guest side both agree on.
$script:LabMac = ''
if (-not $DryRun) {
    try {
        $nicInfo = Invoke-VBox @('showvminfo', $Name, '--machinereadable') -Quiet
        $macLine = ($nicInfo -split "`n" | Select-String '^macaddress2=')
        if ($macLine) { $script:LabMac = $macLine.ToString() -replace '.*="?([^"]*)"?$', '$1' }
    } catch { }
}
if ($script:LabMac) {
    Report-Step "adapter 2 MAC" "$($script:LabMac) - passed to the configure script"
} elseif (-not $DryRun) {
    # Not fatal. Without a MAC the configure script falls back to its own rule - the
    # adapter with no default gateway - which is correct on this build and was always the
    # better guess than a name.
    Report-Ok "adapter 2 MAC" "could not be read - the configure script will detect the adapter itself"
}

# --------------------------------------------------------------------------- #
# 4. The unattended install
#
# VirtualBox supplies the answers Windows Setup would stop for. The hostname it wants is a
# FQDN - a bare name is rejected - so the computer name gets a .lab suffix here and Windows
# ends up with the short name.
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "Unattended install"

$unattendArgs = @(
    'unattended', 'install', $Name,
    "--iso=$IsoPath",
    "--user=$User",
    "--password=$Password",
    "--full-user-name=GNS3 Lab",
    "--hostname=$ComputerName.lab",
    "--locale=$Locale",
    "--image-index=$ImageIndex",
    "--install-additions"
)

# Without this, VirtualBox writes an empty <ProductKey> element into the answer file and
# Windows 11 25H2 Setup stops to ask. Found on the first real run, 20 September 2026.
if ($ProductKey) { $unattendArgs += "--key=$ProductKey" }

if (-not $SkipConfigure) {
    # Runs inside Windows once the install finishes. It fetches the same script the guide
    # tells students to run by hand, so a machine built here and a machine built by hand
    # end up identical. This is the least-tested part of this script: if it does not run,
    # nothing is broken - run configure-windows-host.ps1 yourself, per Step 5 of the guide.
    $ipArg  = if ($LabIPAddress)    { " -IPAddress $LabIPAddress" }        else { "" }
    $nicArg = if ($script:LabMac)    { " -LabAdapterMac $script:LabMac" }   else { "" }
    $inner  = "Invoke-WebRequest -Uri $ConfigureUrl -OutFile C:\Windows\Temp\configure-windows-host.ps1; " +
              "& C:\Windows\Temp\configure-windows-host.ps1$nicArg$ipArg -ComputerName $ComputerName"
    $unattendArgs += "--post-install-command=powershell.exe -ExecutionPolicy Bypass -Command `"$inner`""
}

if (-not $NoStart) { $unattendArgs += '--start-vm=gui' }

try {
    Invoke-VBox $unattendArgs
    Report-Step "prepared" $(if ($NoStart) { "not started (-NoStart)" } else { "started - Windows is installing" })
} catch {
    Report-Failed "unattended" $_.Exception.Message
    exit 1
}

# --------------------------------------------------------------------------- #
# 5. Press the key nobody is there to press
#
# The retail ISO's EFI bootloader asks you to "Press any key to boot from CD or DVD", and
# an unattended install has nobody to answer it: the prompt times out, the empty disk has
# nothing to boot, and the machine lands in VirtualBox's "failed to boot" dialog.
#
# VirtualBox 7.0.20 does not patch the prompt out. Its auxiliary disc carries the answer
# file, the post-install command and the Guest Additions - and no boot files - so it is the
# Windows ISO itself that boots, prompt and all. Windows Setup reads the answer file off
# that second disc regardless, which is why everything after this point works.
#
# So tap a key. 0f 8f is Tab down, Tab up - deliberately NOT space or Enter.
#
# The taps do overlap Setup's first screen: WinPE can be drawing "Please wait" within ten
# seconds on an SSD. Space there activated the focused Support link, and Setup put up
# "Unable to open link. Please visit https://aka.ms/SetupFaq" - which WinPE cannot open,
# because it has no browser. That run recovered, but a modal dialog in front of an
# unattended install is exactly what an unattended install cannot clear. Tab only moves
# focus, so it satisfies "press any key" and activates nothing.
#
# The early taps land while the VM is still coming up and fail harmlessly.
# Boot prompt fix proven on VirtualBox 7.0.20, 20 September 2026; the Tab refinement came
# from watching space trip that dialog on the run after.
# --------------------------------------------------------------------------- #
if (-not $NoStart -and -not $DryRun) {
    Write-Host ""
    Write-Host "Boot prompt"
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        Invoke-VBox @('controlvm', $Name, 'keyboardputscancode', '0f', '8f') -AllowFailure -Quiet | Out-Null
    }
    Report-Step "boot prompt" "Tab sent for 10 s - nothing else would press it"
}

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
Write-Host ""
if ($DryRun) {
    Write-Host "Dry run: $script:Steps step(s) would run. Nothing was created."
    exit 0
}
if ($script:Failed) {
    Write-Host "$script:Failed step(s) failed - the VM is incomplete." -ForegroundColor Red
    Write-Host "Delete it from VirtualBox, or re-run with -Force, once the cause is fixed."
    exit 1
}

Write-Host "The Windows Host VM is building." -ForegroundColor Green
Write-Host ""
Write-Host "  Windows takes 30 to 60 minutes and restarts itself several times. Leave it alone."
Write-Host ""
Write-Host "  When it reaches the desktop:"
if ($SkipConfigure) {
    Write-Host "    1. Run configure-windows-host.ps1 inside Windows - Step 5 of the guide."
    Write-Host "    2. Add a Windows Host node to your GNS3 project and wire it up."
} else {
    Write-Host "    1. Check it worked: from a GNS3 Linux Host, ping $(if ($LabIPAddress) { $LabIPAddress } else { 'the machine' })."
    Write-Host "       If it does not answer, run configure-windows-host.ps1 inside Windows"
    Write-Host "       yourself - Step 5 of the guide - and read what it reports."
    Write-Host "    2. Add a Windows Host node to your GNS3 project and wire it up."
}
Write-Host ""
Write-Host "  Remember the GNS3 VM needs its third adapter on Internal Network '$LabNetwork',"
Write-Host "  with Promiscuous Mode set to Allow All. This script did not touch it."
