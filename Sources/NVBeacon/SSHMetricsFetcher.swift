import Foundation

struct SSHMetricsFetcher: Sendable {
    static let processDetailsCommand = "nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
    private static let processSectionSeparator = "__GPUUSAGE_PROCESS_SECTION__"
    private static let psSectionSeparator = "__GPUUSAGE_PS_SECTION__"
    private static let hostStatsSectionSeparator = "__GPUUSAGE_HOST_SECTION__"
    private static let hostProcessesSeparator = "__GPUUSAGE_HOST_PROCS__"
    private static let slurmSectionSeparator = "__GPUUSAGE_SLURM_SECTION__"
    private static let slurmJobsSeparator = "__GPUUSAGE_SLURM_JOBS__"
    private static let controlSocketPath = "/tmp/nvbeacon-ssh-%C.sock"

    enum FetchError: LocalizedError, Equatable {
        case commandFailed(Int32, String)
        case commandTimedOut(Int)
        case emptyResponse
        case invalidOutput(String)
        case invalidProcessOutput(String)
        case invalidPSOutput(String)
        case askPassScriptCreationFailed
        case missingTarget

        var errorDescription: String? {
            let language = AppLocalizer.currentLanguage()
            switch self {
            case .commandFailed(_, let message):
                return message.isEmpty ? language.text("ssh command failed.", "ssh 명령이 실패했습니다.") : message
            case .commandTimedOut(let seconds):
                return language.text(
                    "ssh command timed out after \(seconds) seconds.",
                    "ssh 명령이 \(seconds)초 뒤 시간 초과되었습니다."
                )
            case .emptyResponse:
                return language.text("nvidia-smi output was empty.", "nvidia-smi 출력이 비어 있습니다.")
            case .invalidOutput(let line):
                return language.text("nvidia-smi output could not be parsed: \(line)", "nvidia-smi 출력을 파싱할 수 없습니다: \(line)")
            case .invalidProcessOutput(let line):
                return language.text("nvidia-smi process output could not be parsed: \(line)", "nvidia-smi process 출력을 파싱할 수 없습니다: \(line)")
            case .invalidPSOutput(let line):
                return language.text("ps output could not be parsed: \(line)", "ps 출력을 파싱할 수 없습니다: \(line)")
            case .askPassScriptCreationFailed:
                return language.text("Failed to create the temporary script for SSH password authentication.", "SSH 비밀번호 인증을 위한 임시 스크립트를 만들지 못했습니다.")
            case .missingTarget:
                return language.text("SSH target is missing.", "SSH target이 비어 있습니다.")
            }
        }
    }

    func fetchSummary(settings: AppSettings, password: String? = nil) async throws -> GPUSnapshot {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let output = try await runSSHCommand(
            settings: normalized,
            remoteCommand: Self.buildSummaryRemoteCommand(summaryCommand: normalized.remoteCommand),
            password: password
        )
        let gpus = try Self.parseSnapshot(output)
        return GPUSnapshot(
            takenAt: Date(),
            gpus: gpus,
            hostStats: Self.parseHostStatsSection(Self.section(named: Self.hostStatsSectionSeparator, from: output)),
            slurmStatus: Self.parseSlurmSection(Self.section(named: Self.slurmSectionSeparator, from: output))
        )
    }

    func fetchProcessDetails(
        settings: AppSettings,
        processes: [GPUProcessReading],
        password: String? = nil
    ) async throws -> [GPUProcessReading] {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let uniquePIDs = Array(Set(processes.map(\.pid))).sorted()
        guard !uniquePIDs.isEmpty else {
            return processes
        }

        let output = try await runSSHCommand(
            settings: normalized,
            remoteCommand: Self.buildDetailedPSLookupCommand(pids: uniquePIDs),
            password: password,
            allowEmptyOutput: true
        )
        let processDetails = try Self.parseDetailedPSSection(output)
        let processDetailsByPID = Dictionary(uniqueKeysWithValues: processDetails.map { ($0.pid, $0) })

        return processes.map { process in
            guard let details = processDetailsByPID[process.pid] else {
                return process
            }

            return GPUProcessReading(
                gpuUUID: process.gpuUUID,
                pid: process.pid,
                processName: process.processName,
                usedGPUMemoryMB: process.usedGPUMemoryMB,
                userID: details.userID,
                user: details.user,
                commandLine: details.commandLine
            )
        }
    }

    func fetchRemoteUserID(
        settings: AppSettings,
        username: String,
        password: String? = nil
    ) async throws -> Int {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let output = try await runSSHCommand(
            settings: normalized,
            remoteCommand: Self.buildRemoteUIDLookupCommand(username: username),
            password: password
        )

        guard let uid = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FetchError.invalidPSOutput(output)
        }

        return uid
    }

    func fetchProcessStatuses(
        settings: AppSettings,
        pids: [Int],
        password: String? = nil
    ) async throws -> [RemoteProcessStatus] {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let uniquePIDs = Array(Set(pids)).sorted()
        guard !uniquePIDs.isEmpty else {
            return []
        }

        let output = try await runSSHCommand(
            settings: normalized,
            remoteCommand: Self.buildPSLookupCommand(pids: uniquePIDs),
            password: password,
            allowEmptyOutput: true
        )

        return try Self.parsePSSection(output)
    }

    static func parse(_ output: String) throws -> [GPUReading] {
        try parseGPUSection(output)
    }

    static func parseSnapshot(_ output: String) throws -> [GPUReading] {
        let gpuSection = section(named: nil, from: output)
        let processSection = section(named: processSectionSeparator, from: output)
        let psSection = section(named: psSectionSeparator, from: output)

        let gpus = try parseGPUSection(gpuSection)
        let processes = try parseProcessSection(processSection)
        let processDetails = try parsePSSection(psSection)

        let processDetailsByPID = Dictionary(uniqueKeysWithValues: processDetails.map { ($0.pid, $0) })
        let enrichedProcesses = processes.map { process in
            let details = processDetailsByPID[process.pid]
            return GPUProcessReading(
                gpuUUID: process.gpuUUID,
                pid: process.pid,
                processName: process.processName,
                usedGPUMemoryMB: process.usedGPUMemoryMB,
                userID: process.userID,
                user: details?.user,
                commandLine: details?.commandLine
            )
        }

        guard !enrichedProcesses.isEmpty else {
            return gpus
        }

        let processesByGPU = Dictionary(grouping: enrichedProcesses, by: \.gpuUUID)
        return gpus.map { gpu in
            GPUReading(
                index: gpu.index,
                name: gpu.name,
                uuid: gpu.uuid,
                utilization: gpu.utilization,
                memoryUsedMB: gpu.memoryUsedMB,
                memoryTotalMB: gpu.memoryTotalMB,
                temperatureCelsius: gpu.temperatureCelsius,
                processes: gpu.uuid.flatMap { processesByGPU[$0] } ?? []
            )
        }
    }

    private static func parseGPUSection(_ output: String) throws -> [GPUReading] {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        guard !lines.isEmpty else {
            throw FetchError.emptyResponse
        }

        return try lines.map(parseLine(_:)).sorted { $0.index < $1.index }
    }

    private static func parseProcessSection(_ output: String) throws -> [GPUProcessReading] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        return try lines.map(parseProcessLine(_:))
    }

    private static func parsePSSection(_ output: String) throws -> [RemoteProcessStatus] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        return try lines.map(parsePSLine(_:))
    }

    private static func parseDetailedPSSection(_ output: String) throws -> [RemoteProcessStatus] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        return try lines.map(parseDetailedPSLine(_:))
    }

    static func parseHostStatsSection(_ output: String) -> HostStats? {
        var statsLines = output.components(separatedBy: "\n")

        var topUserProcesses = [HostProcessReading]()
        if let markerIndex = statsLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == hostProcessesSeparator }) {
            topUserProcesses = statsLines[(markerIndex + 1)...]
                .compactMap { parseHostProcessLine(Substring($0)) }
            statsLines = Array(statsLines[..<markerIndex])
        }

        let lines = statsLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
        guard let line = lines.first else {
            return nil
        }

        let columns = line
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard columns.count >= 6,
              let cpuCoreCount = Int(columns[0]),
              let loadAverage1 = Double(columns[1]),
              let loadAverage5 = Double(columns[2]),
              let loadAverage15 = Double(columns[3]),
              let memoryTotalMB = Int(columns[4]),
              let memoryAvailableMB = Int(columns[5]),
              cpuCoreCount > 0 || memoryTotalMB > 0 else {
            return nil
        }

        let hostname = columns.count >= 7 ? columns[6] : ""

        // Optional second line: aggregate CPU busy % followed by per-core percentages.
        var cpuUtilizationPercent: Int?
        var coreUtilizationPercents = [Int]()
        if lines.count >= 2 {
            let utilizationColumns = lines[1]
                .split(separator: ",", omittingEmptySubsequences: false)
                .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let aggregate = utilizationColumns.first {
                cpuUtilizationPercent = aggregate
                coreUtilizationPercents = Array(utilizationColumns.dropFirst())
            }
        }

        return HostStats(
            cpuCoreCount: cpuCoreCount,
            loadAverage1: loadAverage1,
            loadAverage5: loadAverage5,
            loadAverage15: loadAverage15,
            memoryTotalMB: memoryTotalMB,
            memoryAvailableMB: memoryAvailableMB,
            hostname: hostname.isEmpty ? nil : hostname,
            cpuUtilizationPercent: cpuUtilizationPercent,
            coreUtilizationPercents: coreUtilizationPercents,
            topUserProcesses: topUserProcesses
        )
    }

    private static func parseHostProcessLine(_ line: Substring) -> HostProcessReading? {
        let columns = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)

        guard columns.count >= 4,
              let pid = Int(columns[0]),
              let cpuPercent = Double(columns[1]),
              let memoryPercent = Double(columns[2]) else {
            return nil
        }

        return HostProcessReading(
            pid: pid,
            cpuPercent: cpuPercent,
            memoryPercent: memoryPercent,
            commandLine: String(columns[3])
        )
    }

    static func parseSlurmSection(_ output: String) -> SlurmStatus? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lines = trimmed.components(separatedBy: "\n")
        let nodeLines: ArraySlice<String>
        let jobLines: ArraySlice<String>

        if let markerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == slurmJobsSeparator }) {
            nodeLines = lines[..<markerIndex]
            jobLines = lines[(markerIndex + 1)...]
        } else {
            nodeLines = lines[...]
            jobLines = []
        }

        let nodes = nodeLines.compactMap { parseSlurmNodeLine(Substring($0)) }
        let jobs = jobLines.compactMap { parseSlurmJobLine(Substring($0)) }

        guard !nodes.isEmpty || !jobs.isEmpty else {
            return nil
        }

        return SlurmStatus(nodes: nodes, jobs: jobs)
    }

    private static func parseSlurmNodeLine(_ line: Substring) -> SlurmNode? {
        let columns = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard columns.count >= 3, !columns[0].isEmpty else {
            return nil
        }

        return SlurmNode(
            name: columns[0],
            partition: columns[1],
            state: columns[2]
        )
    }

    private static func parseSlurmJobLine(_ line: Substring) -> SlurmJob? {
        let columns = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Slurm job IDs are numeric ("769", "769_3", "769+1"); rejecting anything
        // else keeps stray pipe-delimited text out of the job list.
        guard columns.count >= 8, columns[0].first?.isNumber == true else {
            return nil
        }

        return SlurmJob(
            jobID: columns[0],
            partition: columns[1],
            name: columns[2],
            user: columns[3],
            state: columns[4],
            elapsedTime: columns[5],
            nodeCount: Int(columns[6]) ?? 0,
            nodeListOrReason: columns[7...].joined(separator: "|")
        )
    }

    private func runSSHCommand(
        settings: AppSettings,
        remoteCommand: String,
        password: String?,
        allowEmptyOutput: Bool = false
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let trimmedPassword = password?.trimmingCharacters(in: .newlines)
            do {
                return try Self.executeSSHCommand(
                    settings: settings,
                    remoteCommand: remoteCommand,
                    trimmedPassword: trimmedPassword,
                    allowEmptyOutput: allowEmptyOutput
                )
            } catch let error as FetchError {
                guard settings.sshConnectionReuseMode == .reuseWhenPossible,
                      Self.shouldRetryWithoutConnectionReuse(after: error) else {
                    throw error
                }

                var fallbackSettings = settings
                fallbackSettings.sshConnectionReuseMode = .newConnectionEachRefresh
                return try Self.executeSSHCommand(
                    settings: fallbackSettings,
                    remoteCommand: remoteCommand,
                    trimmedPassword: trimmedPassword,
                    allowEmptyOutput: allowEmptyOutput
                )
            }
        }.value
    }

    private static func executeSSHCommand(
        settings: AppSettings,
        remoteCommand: String,
        trimmedPassword: String?,
        allowEmptyOutput: Bool
    ) throws -> String {
        let askPassScriptURL: URL?

        if let trimmedPassword, !trimmedPassword.isEmpty {
            askPassScriptURL = try createAskPassScript()
        } else {
            askPassScriptURL = nil
        }

        defer {
            if let askPassScriptURL {
                try? FileManager.default.removeItem(at: askPassScriptURL)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = buildSSHArguments(
            settings: settings,
            prefersPasswordAuth: !(trimmedPassword?.isEmpty ?? true),
            remoteCommand: remoteCommand
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        if let askPassScriptURL, let trimmedPassword {
            process.environment = ProcessInfo.processInfo.environment.merging(
                [
                    "SSH_ASKPASS": askPassScriptURL.path,
                    "SSH_ASKPASS_REQUIRE": "force",
                    "GPUUSAGE_SSH_PASSWORD": trimmedPassword,
                    "DISPLAY": "nvbeacon:0",
                ],
                uniquingKeysWith: { _, newValue in newValue }
            )
        }

        try process.run()
        try waitForProcessToExit(process, timeoutSeconds: 15)

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw FetchError.commandFailed(process.terminationStatus, stderr.isEmpty ? stdout : stderr)
        }

        guard allowEmptyOutput || !stdout.isEmpty else {
            throw FetchError.emptyResponse
        }

        return stdout
    }

    private static func buildSSHArguments(
        settings: AppSettings,
        prefersPasswordAuth: Bool,
        remoteCommand: String
    ) -> [String] {
        var arguments = [
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "TCPKeepAlive=yes",
        ]

        if settings.sshConnectionReuseMode == .reuseWhenPossible {
            arguments.append(contentsOf: [
                "-o", "ControlMaster=auto",
                "-o", "ControlPersist=45",
                "-o", "ControlPath=\(controlSocketPath)",
                "-o", "StreamLocalBindUnlink=yes",
            ])
        }

        if prefersPasswordAuth {
            arguments.append(contentsOf: [
                "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PreferredAuthentications=password,keyboard-interactive,publickey",
            ])
        } else {
            arguments.append(contentsOf: [
                "-o", "BatchMode=yes",
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
            ])
        }

        if !settings.sshIdentityFilePath.isEmpty {
            arguments.append(contentsOf: ["-i", settings.sshIdentityFilePath])
        }

        if let port = settings.resolvedPort {
            arguments.append(contentsOf: ["-p", String(port)])
        }

        arguments.append(settings.sshTarget)
        arguments.append(contentsOf: [
            "/bin/sh",
            "-lc",
            shellQuoted(remoteCommand),
        ])

        return arguments
    }

    private static func shouldRetryWithoutConnectionReuse(after error: FetchError) -> Bool {
        switch error {
        case .commandFailed(_, let message):
            let normalized = message.lowercased()
            return normalized.contains("control socket")
                || normalized.contains("mux_client")
                || normalized.contains("master is dead")
                || normalized.contains("session open refused by peer")
                || normalized.contains("broken pipe")
        case .commandTimedOut:
            return true
        default:
            return false
        }
    }

    private static func waitForProcessToExit(_ process: Process, timeoutSeconds: Int) throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while process.isRunning {
            try Task.checkCancellation()

            if Date() >= deadline {
                process.terminate()

                let forceKillDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < forceKillDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }

                if process.isRunning {
                    process.interrupt()
                }

                throw FetchError.commandTimedOut(timeoutSeconds)
            }

            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func parseLine(_ line: String) throws -> GPUReading {
        let columns = line
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let index = Int(columns.first ?? "") else {
            throw FetchError.invalidOutput(line)
        }

        if columns.count >= 7 {
            return GPUReading(
                index: index,
                name: columns[1],
                uuid: columns[2],
                utilization: Int(columns[3]) ?? 0,
                memoryUsedMB: Int(columns[4]) ?? 0,
                memoryTotalMB: Int(columns[5]) ?? 0,
                temperatureCelsius: columns[6] == "N/A" ? nil : Int(columns[6]),
                processes: []
            )
        }

        guard columns.count >= 6 else {
            throw FetchError.invalidOutput(line)
        }

        return GPUReading(
            index: index,
            name: columns[1],
            uuid: nil,
            utilization: Int(columns[2]) ?? 0,
            memoryUsedMB: Int(columns[3]) ?? 0,
            memoryTotalMB: Int(columns[4]) ?? 0,
            temperatureCelsius: columns[5] == "N/A" ? nil : Int(columns[5]),
            processes: []
        )
    }

    private static func parseProcessLine(_ line: String) throws -> GPUProcessReading {
        let columns = line
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard columns.count >= 4, let pid = Int(columns[1]) else {
            throw FetchError.invalidProcessOutput(line)
        }

        let hasUIDColumn = columns.count >= 5
        return GPUProcessReading(
            gpuUUID: columns[0],
            pid: pid,
            processName: hasUIDColumn ? columns[3] : columns[2],
            usedGPUMemoryMB: Int(hasUIDColumn ? columns[4] : columns[3]) ?? 0,
            userID: hasUIDColumn ? Int(columns[2]) : nil,
            user: nil,
            commandLine: nil
        )
    }

    // The remote shell's argv (visible in `ps … args=`) contains this entire script,
    // so a marker written literally here can echo back into the output we parse.
    // Emit it as two adjacent single-quoted halves the shell rejoins at runtime.
    private static func scriptMarker(_ separator: String) -> String {
        let mid = separator.index(separator.startIndex, offsetBy: separator.count / 2)
        return "\(separator[..<mid])''\(separator[mid...])"
    }

    static func buildSummaryRemoteCommand(summaryCommand: String) -> String {
        """
        \(summaryCommand)
        printf '\\n\(scriptMarker(processSectionSeparator))\\n'
        process_output="$(\(processDetailsCommand) 2>/dev/null || true)"
        printf '%s\\n' "$process_output" | while IFS=, read -r gpu_uuid pid pname used_mem; do
          gpu_uuid="$(printf '%s' "$gpu_uuid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
          pid="$(printf '%s' "$pid" | tr -d '[:space:]')"
          pname="$(printf '%s' "$pname" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
          used_mem="$(printf '%s' "$used_mem" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
          [ -n "$pid" ] || continue
          [ -r "/proc/$pid/status" ] || continue
          uid_line="$(grep '^Uid:' "/proc/$pid/status" 2>/dev/null || true)"
          [ -n "$uid_line" ] || continue
          set -- $uid_line
          real_uid="$2"
          [ -n "$real_uid" ] || continue
          printf '%s,%s,%s,%s,%s\\n' "$gpu_uuid" "$pid" "$real_uid" "$pname" "$used_mem"
        done
        printf '\\n\(scriptMarker(hostStatsSectionSeparator))\\n'
        host_cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
        host_load="$(cut -d ' ' -f 1-3 /proc/loadavg 2>/dev/null || uptime 2>/dev/null | sed 's/.*load average[s]*: *//; s/,/ /g' || echo '0 0 0')"
        set -- $host_load
        host_mem="$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {avail=$2} END {printf "%d %d", total/1024, avail/1024}' /proc/meminfo 2>/dev/null || echo '0 0')"
        host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '')"
        printf '%s,%s,%s,%s,%s,%s\\n' "$host_cpus" "${1:-0}" "${2:-0}" "${3:-0}" "$(printf '%s' "$host_mem" | tr ' ' ',')" "$host_name"
        { grep '^cpu' /proc/stat; sleep 0.5; grep '^cpu' /proc/stat; } 2>/dev/null | awk '
        {
          key=$1; total=0
          for (i=2; i<=NF; i++) total+=$i
          idle=$5+$6
          if (key in t1) {
            dt=total-t1[key]; di=idle-i1[key]
            pct=(dt>0) ? 100*(dt-di)/dt : 0
            out[key]=int(pct+0.5); order[n++]=key
          } else {
            t1[key]=total; i1[key]=idle
          }
        }
        END {
          if ("cpu" in out) {
            line=out["cpu"]
            for (j=0; j<n; j++) { k=order[j]; if (k!="cpu") line=line","out[k] }
            print line
          }
        }'
        printf '\(scriptMarker(hostProcessesSeparator))\\n'
        ps -u "$(id -un)" -o pid=,pcpu=,pmem=,args= --sort=-pcpu 2>/dev/null | grep -v _GPUUSAGE | head -n 5 || true
        printf '\\n\(scriptMarker(slurmSectionSeparator))\\n'
        if command -v squeue >/dev/null 2>&1; then
          sinfo -N -h -o '%N|%P|%t' 2>/dev/null || true
          printf '\\n\(scriptMarker(slurmJobsSeparator))\\n'
          squeue -h -o '%i|%P|%j|%u|%T|%M|%D|%R' 2>/dev/null || true
        fi
        """
    }

    private static func buildPSLookupCommand(pids: [Int]) -> String {
        let pidList = pids.map(String.init).joined(separator: ",")
        return """
        ps -o pid= -o user= -o args= -p "\(pidList)" 2>/dev/null || true
        """
    }

    private static func buildDetailedPSLookupCommand(pids: [Int]) -> String {
        let pidList = pids.map(String.init).joined(separator: ",")
        return """
        ps -o pid= -o uid= -o user= -o args= -p "\(pidList)" 2>/dev/null || true
        """
    }

    private static func buildRemoteUIDLookupCommand(username: String) -> String {
        "id -u -- \(shellQuoted(username))"
    }

    private static func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func createAskPassScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-askpass-\(UUID().uuidString).sh")
        let contents = """
        #!/bin/sh
        printf '%s' "$GPUUSAGE_SSH_PASSWORD"
        """

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            throw FetchError.askPassScriptCreationFailed
        }
    }

    private static let sectionSeparators: Set<String> = [
        processSectionSeparator, psSectionSeparator, hostStatsSectionSeparator, slurmSectionSeparator,
    ]

    // Separators count only as whole lines: the remote `ps … args=` listing can
    // include processes whose command line embeds marker-like text mid-line.
    static func section(named name: String?, from output: String) -> String {
        let lines = output.components(separatedBy: "\n")

        var startIndex = 0
        if let name {
            guard let markerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == name }) else {
                return ""
            }
            startIndex = markerIndex + 1
        }

        let endIndex = lines[startIndex...].firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed != name && sectionSeparators.contains(trimmed)
        } ?? lines.endIndex

        return lines[startIndex..<endIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parsePSLine(_ line: String) throws -> RemoteProcessStatus {
        let columns = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)

        guard columns.count >= 2, let pid = Int(columns[0]) else {
            throw FetchError.invalidPSOutput(line)
        }

        let commandLine = columns.count == 3 ? String(columns[2]) : nil
        return RemoteProcessStatus(
            pid: pid,
            userID: nil,
            user: String(columns[1]),
            commandLine: commandLine
        )
    }

    private static func parseDetailedPSLine(_ line: String) throws -> RemoteProcessStatus {
        let columns = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)

        guard columns.count >= 3, let pid = Int(columns[0]) else {
            throw FetchError.invalidPSOutput(line)
        }

        let commandLine = columns.count == 4 ? String(columns[3]) : nil
        return RemoteProcessStatus(
            pid: pid,
            userID: Int(columns[1]),
            user: String(columns[2]),
            commandLine: commandLine
        )
    }

}
