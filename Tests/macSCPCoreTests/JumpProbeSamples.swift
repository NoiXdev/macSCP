@testable import macSCPCore

/// What the jump-host probes' tools printed, kept byte for byte as a command
/// on a real machine printed it — the input `JumpProbeReading` is measured
/// against, and what `JumpRig` answers a probe with.
///
/// **Recorded 2026-09-18**, standard output only (standard error sent to
/// `/dev/null`, which is what `SSHClient.collectingStandardOutput(of:limit:onStandardOutput:)`
/// keeps), each with the exit status the shell reported:
///
/// - `rig…`: the Docker rig's `macscp-test-sshd` (Alpine 3.24.1, BusyBox
///   v1.37.0, `getent` from musl-utils 1.2.6-r2). The `…OverSSH` ones went
///   through a real SSH `exec` as `testuser` on 127.0.0.1:2222; the rest
///   through `docker exec`, `rigTraceroute…` as root because BusyBox
///   `traceroute` needs a raw socket `testuser` is not allowed
///   (`rigTracerouteAsTestuserOverSSH` is that refusal).
/// - `debian…`: `ddev/ddev-webserver:v1.25.4` (Debian 13, iputils 20240905,
///   glibc `getent`), run with `--network none`, so only loopback answers.
/// - `macOS…`: this Mac, macOS 26.6.2 (BSD `ping` and `traceroute`).
///   `traceroute` wrote its header line to standard error, so the recorded
///   standard output starts at hop 1.
///
/// Fix round 1 added the deadline `ping` samples below, recorded the same
/// day with the same labels.
///
/// **Constructed, not recorded** — no machine available here carries these,
/// and none was installed to get them: every `tracepath` sample (iputils'
/// `tracepath` is on none of the local images, and the rig has none), and
/// the traceroute rows with a `!X` annotation or a router before the
/// destination (the rig's Docker network is one hop deep, and a walk from
/// this Mac would record the maintainer's own network). Their shape follows
/// the recorded rows; a parser that reads them is tested on its reading of
/// that shape, not on a measurement.
enum JumpProbeSamples {
    // MARK: getent hosts

    static let rigGetentOverSSH = RemoteCommandOutput(
        standardOutput: "172.20.0.2        sshd2  sshd2\n", exitStatus: 0)
    static let rigGetentLocalhost = RemoteCommandOutput(
        standardOutput: "::1               localhost  localhost\n", exitStatus: 0)
    static let rigGetentMissing = RemoteCommandOutput(standardOutput: "", exitStatus: 2)
    static let debianGetentLocalhost = RemoteCommandOutput(
        standardOutput: "::1             localhost ip6-localhost ip6-loopback\n", exitStatus: 0)
    static let debianGetentMissing = RemoteCommandOutput(standardOutput: "", exitStatus: 2)

    // MARK: ping -c 3

    static let rigPingOverSSH = RemoteCommandOutput(
        standardOutput: """
            PING sshd2 (172.20.0.2): 56 data bytes
            64 bytes from 172.20.0.2: seq=0 ttl=42 time=0.040 ms
            64 bytes from 172.20.0.2: seq=1 ttl=42 time=0.407 ms
            64 bytes from 172.20.0.2: seq=2 ttl=42 time=0.053 ms

            --- sshd2 ping statistics ---
            3 packets transmitted, 3 packets received, 0% packet loss
            round-trip min/avg/max = 0.040/0.166/0.407 ms

            """, exitStatus: 0)
    static let rigPingSilent = RemoteCommandOutput(
        standardOutput: """
            PING 192.0.2.1 (192.0.2.1): 56 data bytes

            --- 192.0.2.1 ping statistics ---
            3 packets transmitted, 0 packets received, 100% packet loss

            """, exitStatus: 1)
    static let debianPingLoopback = RemoteCommandOutput(
        standardOutput: """
            PING 127.0.0.1 (127.0.0.1) 56(84) bytes of data.
            64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.019 ms
            64 bytes from 127.0.0.1: icmp_seq=2 ttl=64 time=0.025 ms
            64 bytes from 127.0.0.1: icmp_seq=3 ttl=64 time=0.017 ms

            --- 127.0.0.1 ping statistics ---
            3 packets transmitted, 3 received, 0% packet loss, time 2040ms
            rtt min/avg/max/mdev = 0.017/0.020/0.025/0.003 ms

            """, exitStatus: 0)
    /// `ping -c 3 192.0.2.1` with no route: `ping: connect: Network is
    /// unreachable` went to standard error, and nothing to standard output.
    static let debianPingNoRoute = RemoteCommandOutput(standardOutput: "", exitStatus: 2)
    static let macOSPingLoopback = RemoteCommandOutput(
        standardOutput: """
            PING 127.0.0.1 (127.0.0.1): 56 data bytes
            64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.055 ms
            64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.128 ms
            64 bytes from 127.0.0.1: icmp_seq=2 ttl=64 time=0.091 ms

            --- 127.0.0.1 ping statistics ---
            3 packets transmitted, 3 packets received, 0.0% packet loss
            round-trip min/avg/max/stddev = 0.055/0.091/0.128/0.030 ms

            """, exitStatus: 0)

    // MARK: ping with a deadline (fix round 1)

    /// Recorded 2026-09-18 for fix round 1. `ping -w 5` from a transient
    /// container of the local image (`alpine:latest`, BusyBox v1.37.0 — the
    /// rig's version) on Docker's default bridge to a second transient
    /// container, which was killed 2.5 s in: three answers, then silence.
    static let busyBoxPingPartialLoss = RemoteCommandOutput(
        standardOutput: """
            PING 172.17.0.5 (172.17.0.5): 56 data bytes
            64 bytes from 172.17.0.5: seq=0 ttl=64 time=0.143 ms
            64 bytes from 172.17.0.5: seq=1 ttl=64 time=0.074 ms
            64 bytes from 172.17.0.5: seq=2 ttl=64 time=0.076 ms

            --- 172.17.0.5 ping statistics ---
            5 packets transmitted, 3 packets received, 40% packet loss
            round-trip min/avg/max = 0.074/0.097/0.143 ms

            """, exitStatus: 0)
    /// The same, from `ddev/ddev-webserver:v1.25.4` (iputils 20240905).
    static let debianPingPartialLoss = RemoteCommandOutput(
        standardOutput: """
            PING 172.17.0.5 (172.17.0.5) 56(84) bytes of data.
            64 bytes from 172.17.0.5: icmp_seq=1 ttl=64 time=0.169 ms
            64 bytes from 172.17.0.5: icmp_seq=2 ttl=64 time=0.037 ms
            64 bytes from 172.17.0.5: icmp_seq=3 ttl=64 time=0.060 ms

            --- 172.17.0.5 ping statistics ---
            5 packets transmitted, 3 received, 40% packet loss, time 4118ms
            rtt min/avg/max/mdev = 0.037/0.088/0.169/0.057 ms

            """, exitStatus: 0)
    /// iputils `ping -w 4` to an unused address on Docker's default bridge:
    /// no answer, one ICMP error, and the statistics line's `+1 errors`.
    static let debianPingDeadlineUnreachable = RemoteCommandOutput(
        standardOutput: """
            PING 172.17.255.254 (172.17.255.254) 56(84) bytes of data.
            From 172.17.0.5 icmp_seq=1 Destination Host Unreachable

            --- 172.17.255.254 ping statistics ---
            4 packets transmitted, 0 received, +1 errors, 100% packet loss, time 3078ms
            pipe 4

            """, exitStatus: 1)
    /// BusyBox `ping -w 4` over SSH on the rig to an unused address of its
    /// Docker network (172.20.0.0/16): returned after 4.09 s.
    static let rigPingDeadlineSilentOverSSH = RemoteCommandOutput(
        standardOutput: """
            PING 172.20.255.254 (172.20.255.254): 56 data bytes

            --- 172.20.255.254 ping statistics ---
            4 packets transmitted, 0 packets received, 100% packet loss

            """, exitStatus: 1)
    /// macOS `ping -c 3 -w 4 127.0.0.1`: `ping: invalid option -- w` and the
    /// usage on standard error, EX_USAGE.
    static let macOSPingUnknownOption = RemoteCommandOutput(standardOutput: "", exitStatus: 64)
    /// macOS `ping -t 4 127.0.0.1`.
    static let macOSPingTimeoutLoopback = RemoteCommandOutput(
        standardOutput: """
            PING 127.0.0.1 (127.0.0.1): 56 data bytes
            64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.086 ms
            64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.093 ms
            64 bytes from 127.0.0.1: icmp_seq=2 ttl=64 time=0.095 ms
            64 bytes from 127.0.0.1: icmp_seq=3 ttl=64 time=0.117 ms

            --- 127.0.0.1 ping statistics ---
            4 packets transmitted, 4 packets received, 0.0% packet loss
            round-trip min/avg/max/stddev = 0.086/0.098/0.117/0.012 ms

            """, exitStatus: 0)
    /// CONSTRUCTED: BSD's partial loss. No machine here that runs BSD
    /// `ping` could reach a target that stops answering (this Mac cannot
    /// reach Docker's bridge). The lines are the recorded BSD ones above,
    /// with one reply missing and the statistics saying so.
    static let constructedBSDPingPartialLoss = RemoteCommandOutput(
        standardOutput: """
            PING 10.0.0.5 (10.0.0.5): 56 data bytes
            64 bytes from 10.0.0.5: icmp_seq=0 ttl=64 time=0.412 ms
            64 bytes from 10.0.0.5: icmp_seq=2 ttl=64 time=0.388 ms

            --- 10.0.0.5 ping statistics ---
            3 packets transmitted, 2 packets received, 33.3% packet loss
            round-trip min/avg/max/stddev = 0.388/0.400/0.412/0.012 ms

            """, exitStatus: 0)

    // MARK: traceroute -n -q 1 -w 1

    static let rigTracerouteToSshd2 = RemoteCommandOutput(
        standardOutput: """
            traceroute to sshd2 (172.20.0.2), 30 hops max, 46 byte packets
             1  172.20.0.2  0.002 ms

            """, exitStatus: 0)
    /// `-m 4` toward a documentation address: the Docker gateway answers,
    /// then nothing.
    static let rigTracerouteSilentTail = RemoteCommandOutput(
        standardOutput: """
            traceroute to 192.0.2.1 (192.0.2.1), 4 hops max, 46 byte packets
             1  172.20.0.1  0.004 ms
             2  *
             3  *
             4  *

            """, exitStatus: 0)
    /// `traceroute: socket(AF_INET,3,1): Operation not permitted` on standard
    /// error, nothing on standard output.
    static let rigTracerouteAsTestuserOverSSH = RemoteCommandOutput(
        standardOutput: "", exitStatus: 1)
    /// `bash: line 1: tracepath: command not found` on standard error.
    static let rigTracepathOverSSH = RemoteCommandOutput(standardOutput: "", exitStatus: 127)
    static let macOSTracerouteLoopback = RemoteCommandOutput(
        standardOutput: " 1  127.0.0.1  0.274 ms\n", exitStatus: 0)

    /// CONSTRUCTED: a router, then the destination.
    static let constructedTracerouteTwoHops = RemoteCommandOutput(
        standardOutput: """
            traceroute to target.invalid (10.0.0.5), 30 hops max, 60 byte packets
             1  10.0.0.1  0.412 ms
             2  10.0.0.5  0.930 ms

            """, exitStatus: 0)
    /// CONSTRUCTED: a router that answers administratively prohibited.
    static let constructedTracerouteProhibited = RemoteCommandOutput(
        standardOutput: """
            traceroute to target.invalid (10.0.0.5), 30 hops max, 60 byte packets
             1  10.0.0.1  0.412 ms
             2  10.0.9.9  1.204 ms !X

            """, exitStatus: 0)

    // MARK: tracepath -n (all CONSTRUCTED)

    static let constructedTracepathReached = RemoteCommandOutput(
        standardOutput: """
             1?: [LOCALHOST]                      pmtu 1500
             1:  10.0.0.1                                              0.402ms
             1:  10.0.0.1                                              0.388ms
             2:  no reply
             3:  10.0.0.5                                              1.117ms reached
                 Resume: pmtu 1500 hops 3 back 3

            """, exitStatus: 0)
}
