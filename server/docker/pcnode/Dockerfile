# PC node: PowerShell 7 on the Ubuntu host, with a module (NetCompat) that emulates the Windows
# networking cmdlets students use on lab PCs: Get-NetAdapter, New-NetIPAddress, Test-NetConnection…
# PowerShell on Linux has none of them (they are Windows CIM wrappers), so NetCompat rebuilds them
# on `ip -json`. Design and measurements: gns3-dev notes/powershell-pc-node.md.
#
# Template: ../../templates/docker-pcnode.conf ("PowerShell PC"). NOT YET in manifest.yml: built by
# hand as cqugns3/pcnode-spike for Phases 0-1. Tests (not shipped): tests/NetCompat.SelfTest.ps1.
FROM cqugns3/ubuntunode

# PowerShell from Microsoft's release tarball, pinned and checksummed. The tarball, not apt: it is
# published for linux-x64 and linux-arm64 with the same layout, so both architectures install the
# same way. 7.6 is an LTS line. Checksums from the release's hashes.sha256.
ARG PWSH_VERSION=7.6.9
ARG PWSH_SHA256_X64=1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b
ARG PWSH_SHA256_ARM64=02eb9991af447c7e7fe881acde195961afd397c40b8eb1c2b3856b84ec2d85f2
ARG TARGETARCH

# libicu74: .NET globalisation (culture-aware formatting) needs ICU on Ubuntu.
RUN apt-get update && apt-get install -y --no-install-recommends libicu74 \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) arch=x64;   sum=$PWSH_SHA256_X64 ;; \
      arm64) arch=arm64; sum=$PWSH_SHA256_ARM64 ;; \
      *) echo "unsupported arch" >&2; exit 1 ;; \
    esac \
 && wget -q -O /tmp/pwsh.tar.gz \
      "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${arch}.tar.gz" \
 && echo "${sum}  /tmp/pwsh.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/microsoft/powershell/7 \
 && tar -xzf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7 \
 && rm /tmp/pwsh.tar.gz \
 && chmod +x /opt/microsoft/powershell/7/pwsh \
 && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh

# Nodes are offline: no telemetry, no update check (it would only print a warning).
ENV POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1

# The emulation module, on the all-users module path, and the all-users profile that imports it.
COPY NetCompat /usr/local/share/powershell/Modules/NetCompat
COPY profile.ps1 /opt/microsoft/powershell/7/profile.ps1
COPY start-pc /usr/local/bin/start-pc
RUN chmod +x /usr/local/bin/start-pc

CMD ["/usr/local/bin/start-pc"]
