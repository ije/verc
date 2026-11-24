import AppKit
import Observation
import Security

@MainActor @Observable final class Updater {
  private(set) var busy = false
  // Only a Developer ID build can verify an update, so local builds skip the automatic check.
  @ObservationIgnored private let team: String? = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
    else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
  }()

  private struct Release: Decodable {
    struct Asset: Decodable {
      let name: String
      let browserDownloadUrl: URL
    }
    let tagName: String
    let htmlUrl: URL
    let body: String?
    let assets: [Asset]
  }

  func check(manual: Bool) {
    let defaults = UserDefaults.standard
    guard !busy,
      manual || team != nil && Date().timeIntervalSince1970 - defaults.double(forKey: "updateCheckedAt") > 86400
    else { return }
    busy = true
    Task {
      defer { busy = false }
      let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
      let release: Release
      do {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/ije/verc/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        release = try decoder.decode(Release.self, from: data)
        defaults.set(Date().timeIntervalSince1970, forKey: "updateCheckedAt")
      } catch {
        if manual { alert("Cannot Check for Updates", error.localizedDescription) }
        return
      }
      let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
      guard version.compare(current, options: .numeric) == .orderedDescending else {
        if manual { alert("Verc Is Up to Date", "Version \(current) is the latest version.") }
        return
      }
      if !manual && defaults.string(forKey: "skippedVersion") == version { return }

      let app = Bundle.main.bundleURL
      let fm = FileManager.default
      let dmg = release.assets.first { $0.name == "Verc.dmg" }?.browserDownloadUrl
      let installable =
        team != nil && dmg != nil && !app.path.contains("/AppTranslocation/")
        && fm.isWritableFile(atPath: app.path)
        && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
      let prompt = NSAlert()
      prompt.messageText = "Verc \(version) Is Available"
      prompt.informativeText =
        "You have version \(current).\n\n"
        + (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      prompt.addButton(withTitle: installable ? "Install and Relaunch" : "Download")
      prompt.addButton(withTitle: "Later")
      if !manual { prompt.addButton(withTitle: "Skip This Version") }
      switch prompt.runModal() {
      case .alertFirstButtonReturn: break
      case .alertThirdButtonReturn:
        defaults.set(version, forKey: "skippedVersion")
        return
      default: return
      }
      guard installable, let dmg, let team, let identifier = Bundle.main.bundleIdentifier else {
        NSWorkspace.shared.open(release.htmlUrl)
        return
      }

      let work: URL
      do {
        work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
      } catch {
        alert("Cannot Install the Update", error.localizedDescription)
        return
      }
      defer { try? fm.removeItem(at: work) }
      do {
        let staged = try await Task.detached {
          let fm = FileManager.default
          let (download, response) = try await URLSession.shared.download(from: dmg)
          guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
          let image = work.appending(path: "Verc.dmg")
          let mount = work.appending(path: "mount")
          let staged = work.appending(path: "Verc.app")
          try fm.moveItem(at: download, to: image)
          func hdiutil(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
          }
          try hdiutil(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path])
          defer { try? hdiutil(["detach", mount.path, "-force"]) }
          try fm.copyItem(at: mount.appending(path: "Verc.app"), to: staged)
          // Accept only a bundle signed by the same Developer ID team as this app.
          var code: SecStaticCode?
          var requirement: SecRequirement?
          guard SecStaticCodeCreateWithPath(staged as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(
              "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
                as CFString, [], &requirement) == errSecSuccess,
            SecStaticCodeCheckValidity(
              code,
              SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode),
              requirement) == errSecSuccess
          else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The update has an invalid signature."]) }
          return staged
        }.value
        _ = try fm.replaceItemAt(app, withItemAt: staged)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
          "-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; open \"$1\"", "\(getpid())", app.path,
        ]
        try relaunch.run()
        NSApp.terminate(nil)
      } catch {
        alert("Cannot Install the Update", error.localizedDescription)
      }
    }
  }

  private func alert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }
}
