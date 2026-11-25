import Sparkle
import SwiftUI

@MainActor final class Updater: ObservableObject {
    let driver = UpdateDriver()
    let engine: SPUUpdater
    @Published private(set) var canCheckForUpdates = false

    init() {
        engine = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        engine.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

@MainActor @Observable final class UpdateDriver: NSObject, SPUUserDriver {
    struct Notice: Identifiable {
        enum Kind { case progress, current, offer, ready, error }
        let id = UUID()
        let kind: Kind
        let title: String
        var action: (label: String, perform: () -> Void)?
        var dismiss: (() -> Void)?
    }

    var notice: Notice?

    func respond(to item: Notice, accept: Bool = false) {
        guard notice?.id == item.id else { return }
        notice = nil
        if accept { item.action?.perform() } else { item.dismiss?() }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        notice = Notice(kind: .progress, title: "Checking for updates", dismiss: cancellation)
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard item.signingValidationStatus == .succeeded else {
            notice = Notice(kind: .error, title: "Couldn’t verify the update feed")
            reply(.dismiss)
            return
        }
        let title = "Verc \(item.displayVersionString) is available"
        if item.isInformationOnlyUpdate {
            let details = item.infoURL.map { url in
                (label: "Details", perform: { NSWorkspace.shared.open(url); reply(.dismiss) })
            }
            notice = Notice(kind: .offer, title: title, action: details, dismiss: { reply(.dismiss) })
        } else if state.stage == .installing {
            // At this stage, .install can relaunch Verc immediately.
            showReady(toInstallAndRelaunch: reply)
        } else if !item.isMajorUpgrade && item.installationType == "application" {
            notice = Notice(kind: .progress, title: state.stage == .downloaded ? "Preparing update" : "Downloading update")
            reply(.install)
        } else {
            notice = Notice(kind: .offer, title: title, action: (state.stage == .downloaded ? "Prepare" : "Download", {
                reply(.install)
            }), dismiss: { reply(.dismiss) })
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        notice = Notice(kind: .progress, title: "Downloading update", dismiss: cancellation)
    }

    func showDownloadDidStartExtractingUpdate() {
        notice = Notice(kind: .progress, title: "Preparing update")
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        notice = Notice(kind: .ready, title: "Update ready.", action: ("Relaunch Now", { reply(.install) }),
                        dismiss: { reply(.dismiss) })
    }

    func showInstallingUpdate(withApplicationTerminated terminated: Bool,
                              retryTerminatingApplication retry: @escaping () -> Void) {
        notice = terminated ? Notice(kind: .progress, title: "Installing update")
            : Notice(kind: .ready, title: "Relaunching Verc", action: ("Retry", retry))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        if !relaunched { notice = Notice(kind: .current, title: "Update installed.") }
        acknowledgement()
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let value = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let reason = value.flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        if reason == .onLatestVersion || reason == .onNewerThanLatestVersion {
            notice = Notice(kind: .current, title: "Verc is up to date")
        } else {
            notice = Notice(kind: .error, title: error.localizedDescription)
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        notice = Notice(kind: .error, title: error.localizedDescription)
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        // Sparkle ends the session immediately after we acknowledge a result.
        if notice?.kind != .current && notice?.kind != .error { notice = nil }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showExtractionReceivedProgress(_ progress: Double) {}
}

struct UpdateBar: View {
    let driver: UpdateDriver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            if let item = driver.notice {
                UpdateNotice(driver: driver, item: item)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .trailing)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: driver.notice != nil)
    }
}

private struct UpdateNotice: View {
    let driver: UpdateDriver
    let item: UpdateDriver.Notice

    var body: some View {
        let color: Color = item.kind == .ready ? .green : .primary
        HStack(spacing: 8) {
            if item.kind == .progress {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Image(systemName: item.kind == .error ? "exclamationmark.circle.fill"
                      : item.kind == .offer ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 15))
            }
            Text(item.title).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let action = item.action {
                Button {
                    driver.respond(to: item, accept: true)
                } label: {
                    Text(action.label).fixedSize().padding(.horizontal, 9).frame(height: 23)
                        .background(color.opacity(0.14), in: Capsule()).contentShape(Capsule())
                }
            }
            if item.kind == .current || item.kind == .error || (item.kind != .progress && item.dismiss != nil) {
                Button {
                    driver.respond(to: item)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
                .foregroundStyle(Color.secondary).accessibilityLabel("Dismiss")
            }
        }
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        .buttonStyle(.plain)
        .padding(.leading, 12).padding(.trailing, item.kind == .progress ? 12 : 6)
        .padding(.vertical, 5).frame(minHeight: 32)
        .glassEffect(.regular, in: Capsule())
        .task(id: item.id) {
            guard item.kind == .current else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { driver.respond(to: item) }
        }
    }
}
