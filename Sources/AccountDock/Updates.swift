import SwiftUI
import Sparkle

struct ReleaseConfiguration: Decodable {
    let version: String
    let build: Int
    let channel: String
    static let url = Bundle.main.url(forResource: "release", withExtension: "json") ?? Bundle.module.url(forResource: "release", withExtension: "json")!
    static let current = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
}

struct ProductVersion: Decodable, Identifiable {
    let id: String
    let installed: String?
    let latest: String?
    let check: String
    let tested: [String]
    let scope: String
    let known_version: Bool
    let update_available: Bool
    var name: String { switch id { case "accountdock": "Account Dock"; case "chatgpt": "ChatGPT"; default: "VS Code · Codex" } }
    var latestLabel: String {
        if let latest { return latest }
        switch check { case "not_released": return "첫 릴리즈 준비 중"; case "unavailable": return "확인할 수 없음"; default: return "아직 확인 안 함" }
    }
}
struct VersionReport: Decodable { let products: [ProductVersion] }

@MainActor
final class UpdateCenter: ObservableObject {
    @Published var products: [ProductVersion] = []
    @Published var busy = false
    @Published var message: String?
    @Published var checkedAt: Date?
    private var controller: SPUStandardUpdaterController?
    var selfUpdateReady: Bool { controller != nil }
    init() {
        // Development binaries and unsigned previews must never run an updater.
        if Bundle.main.bundleURL.pathExtension == "app",
           let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           URL(string: feed)?.scheme == "https",
           let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           Data(base64Encoded: key)?.count == 32 {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
    }
    func checkSelf() { controller?.checkForUpdates(nil) }
    func refresh(online: Bool = false, update: String? = nil) async {
        guard !busy else { return }
        busy = true
        message = update == nil ? nil : "VS Code 공식 설치 도구로 확장을 업데이트하고 있습니다."
        defer { busy = false }
        do {
            let value = try await run(online: online, update: update)
            products = value.products
            if online { checkedAt = Date() }
            if update != nil { message = "Codex 확장을 업데이트했습니다. VS Code 창을 다시 로드한 뒤 계정을 확인해 주세요. 새 버전의 Account Dock 호환성은 재검증이 필요합니다." }
        } catch { message = "버전 정보를 확인하거나 업데이트하지 못했습니다. 네트워크와 VS Code 설치 상태를 확인해 주세요." }
    }
    private func run(online: Bool, update: String?) async throws -> VersionReport {
        try await VersionService.inventory(online: online, update: update)
    }
}

struct UpdatePanel: View {
    @ObservedObject var center: UpdateCenter
    @State private var pending: ProductVersion?
    @State private var showConfirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("연결된 도구의 버전").font(.system(size: 17, weight: .semibold))
                    Text("최신 버전과 확인된 호환 범위를 따로 관리합니다.").font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                }
                Spacer()
                Button { Task { await center.refresh(online: true) } } label: {
                    Label(center.busy ? "확인 중…" : "업데이트 확인", systemImage: "arrow.triangle.2.circlepath")
                }.buttonStyle(DockButtonStyle(kind: .primary)).disabled(center.busy)
            }
            if let message = center.message {
                Text(message).font(.system(size: 12)).padding(15).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DockTheme.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(center.products) { product in
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(product.name).font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text(product.update_available ? "UPDATE AVAILABLE" : product.id == "accountdock" ? "PREVIEW" : product.known_version ? "OBSERVED" : "NOT VERIFIED")
                            .font(.system(size: 9, weight: .bold)).tracking(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(product.update_available ? DockTheme.orange.opacity(0.18) : DockTheme.blue.opacity(0.35), in: Capsule())
                    }
                    HStack(spacing: 28) {
                        version("설치된 버전", value: product.installed ?? "설치 감지 안 됨")
                        version("공식 최신 버전", value: product.latestLabel)
                        Spacer()
                    }
                    Divider().overlay(DockTheme.blue.opacity(0.5))
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            if product.id == "accountdock" {
                                Text("GitHub Releases · Build \(ReleaseConfiguration.current.build)")
                                Text(center.selfUpdateReady ? "서명 검증 후 앱 안에서 업데이트합니다." : "앱 내 설치는 서명된 첫 배포본부터 활성화됩니다.")
                            } else {
                                Text("확인한 버전: \(product.tested.joined(separator: ", "))")
                                Text(product.scope)
                                if !product.known_version { Text("현재 버전은 호환성 재확인이 필요합니다.").foregroundStyle(Color(red: 0.65, green: 0.24, blue: 0.08)) }
                            }
                        }.font(.system(size: 10)).foregroundStyle(DockTheme.muted)
                        Spacer()
                        if product.id == "accountdock" {
                            Button("앱 업데이트") { center.checkSelf() }.buttonStyle(DockButtonStyle())
                                .disabled(!center.selfUpdateReady || center.busy)
                        } else if product.id == "codex" {
                            Button("확장 업데이트") { pending = product; showConfirm = true }.buttonStyle(DockButtonStyle())
                                .disabled(!product.update_available || center.busy)
                        } else {
                            Button("공식 업데이트 안내") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/download/")!) }
                                .buttonStyle(DockButtonStyle())
                        }
                    }
                }.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(DockTheme.navy.opacity(0.09)))
            }
            Text("ChatGPT 업데이트 설치는 공식 앱에서 진행합니다. 확장 버전은 기본 로컬 VS Code 설치 기준이며, 실행 중인 버전과 다를 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
            if let date = center.checkedAt {
                Text("마지막 온라인 확인 · \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(DockTheme.muted)
            }
        }
        .sheet(isPresented: $showConfirm) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Codex 확장 업데이트").font(.system(size: 21, weight: .bold))
                Text("\(pending?.installed ?? "—") → \(pending?.latest ?? "—")").font(.system(.body, design: .monospaced))
                Text("새 버전은 Account Dock과의 호환성이 아직 확인되지 않았을 수 있습니다. 작업을 저장한 뒤 진행하세요. 설치 후 VS Code 창을 다시 로드해야 할 수 있습니다.").font(.system(size: 12))
                HStack {
                    Spacer()
                    Button("취소") { showConfirm = false }.buttonStyle(DockButtonStyle())
                    Button("업데이트") {
                        let version = pending?.latest
                        showConfirm = false
                        if let version { Task { await center.refresh(online: true, update: version) } }
                    }.buttonStyle(DockButtonStyle(kind: .primary))
                }
            }.padding(28).frame(width: 430).background(DockTheme.canvas)
        }
    }
    private func version(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(DockTheme.muted)
            Text(value).font(.system(size: 16, weight: .medium, design: .monospaced))
        }
    }
}
