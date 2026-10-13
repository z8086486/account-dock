import SwiftUI

struct UsageWindow: Decodable, Identifiable {
    let id: String
    let bucket: String
    let usedPercent: Double
    let remainingPercent: Double
    let windowMinutes: Double?
    let resetsAt: Double?
    var title: String {
        guard let minutes = windowMinutes else { return bucket }
        if minutes >= 1440 { return "\(Int(minutes / 1440))일 한도 · \(bucket)" }
        if minutes >= 60 { return "\(Int(minutes / 60))시간 한도 · \(bucket)" }
        return "\(Int(minutes))분 한도 · \(bucket)"
    }
}
struct UsageReport: Decodable {
    let status: String
    let windows: [UsageWindow]
    let activity: [String: Double]
    let checkedAt: Double?
}

enum UsageReader {
    static func read(_ credential: Data) async throws -> UsageReport {
        let script: String?
        if CommandLine.arguments.count > 1 {
            script = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("usage.py").path
        } else { script = Bundle.main.path(forResource: "usage", ofType: "py") }
        guard let script else { throw DockError.message("사용량 조회 도구가 없습니다.") }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-B", script]
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: credential)
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw DockError.message("사용량 조회에 실패했습니다.") }
            return try JSONDecoder().decode(UsageReport.self, from: data)
        }.value
    }
}

struct AccountUsageView: View {
    let report: UsageReport?
    let loading: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("사용량 확인 중…") }
                    .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
            } else if let report {
                if report.status == "login_required" {
                    Label("사용량 조회를 위해 이 계정으로 다시 로그인해 주세요.", systemImage: "lock.rotation")
                        .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
                } else if report.windows.isEmpty && report.activity.isEmpty {
                    Text("사용량 정보를 제공받지 못했습니다. 잠시 후 다시 확인해 주세요.")
                        .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
                }
                ForEach(report.windows) { window in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(window.title).font(.system(size: 11))
                            Spacer()
                            Text("\(window.remainingPercent, specifier: "%.0f")% 남음")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(DockTheme.navy.opacity(0.07))
                                Capsule().fill(window.remainingPercent <= 20 ? DockTheme.orange : DockTheme.blue)
                                    .frame(width: geo.size.width * min(100, max(0, window.remainingPercent)) / 100)
                            }
                        }.frame(height: 6)
                        if let reset = window.resetsAt {
                            Text("초기화 · \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(DockTheme.muted)
                        }
                    }
                }
                if let lifetime = report.activity["lifetimeTokens"] {
                    Text("누적 사용 토큰 · \(lifetime.formatted(.number.precision(.fractionLength(0))))")
                        .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
                }
                if let checked = report.checkedAt {
                    Text("확인 · \(Date(timeIntervalSince1970: checked).formatted(date: .omitted, time: .shortened)) · Codex 기준")
                        .font(.system(size: 9)).foregroundStyle(DockTheme.muted)
                }
            } else {
                Text("사용량을 아직 확인하지 않았습니다.").font(.system(size: 11)).foregroundStyle(DockTheme.muted)
            }
        }
    }
}
