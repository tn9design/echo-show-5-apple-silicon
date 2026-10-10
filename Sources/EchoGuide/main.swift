import SwiftUI
import AppKit
import CryptoKit

func command(_ executable: String, _ args: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "Check unavailable" }
        return String(decoding: data, as: UTF8.self)
    } catch { return "Check unavailable" }
}

@main struct EchoGuide: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Echo Guide") { GuideView().onAppear { NSApplication.shared.activate(ignoringOtherApps: true) } }
    }
}

struct GuideView: View {
    @State private var status = "Start with a check of this Mac and the connected Echo."
    @State private var files = "Choose a folder containing hashes.json and the publisher downloads."
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("A calmer path to LineageOS").font(.largeTitle.bold())
            Text("Echo Show 5 · First generation · Apple Silicon").foregroundStyle(.secondary)
            GroupBox("1. Check your connection") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(status).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Check this Mac and USB") { checkHost() }.disabled(busy)
                }.padding(10)
            }
            GroupBox("2. Verify your downloads") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(files).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button("Choose download folder…") { verifyFolder() }.disabled(busy)
                    Button("Prepare UTM and ROM downloads…") { prepareDownloads() }.disabled(busy)
                }.padding(10)
            }
            GroupBox("When connecting to the Linux VM") {
                Text("At the top right of the Mac menu bar, open Virtual Machine Accessories → Android → Use with UTM. Then choose the Echo in UTM’s USB Devices menu. Leave your mouse and other accessories on This Mac.")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            if busy { ProgressView("Checking…") }
            Text("Preparation prototype: checks and verified downloads only. It cannot unlock, wipe, flash, install, or reboot your Echo. A detected USB device does not prove a supported model or successful Android boot.").font(.footnote).foregroundStyle(.secondary)
        }.padding(28).frame(minWidth: 680, minHeight: 540)
    }

    func checkHost() {
        busy = true
        Task {
            let result = await Task.detached {
                let cpu = command("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let os = command("/usr/bin/sw_vers", ["-productVersion"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let usb = command("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w", "0"])
                let detected = usb.contains("\"USB Product Name\" = \"Echo Show 5\"") || usb.contains("\"USB Product Name\" = \"Android\"")
                let usbMessage = usb == "Check unavailable" ? "USB inspection unavailable; device presence is unknown." : (detected ? "Echo or Android USB device detected. Exact CHECKERS identity still needs verification." : "No Echo/Android USB name detected. Check wall power and a Micro-USB data cable; VM-assigned devices may be absent from this host view.")
                return "Mac: \(cpu), macOS \(os).\n" + (cpu == "arm64" ? "Apple Silicon confirmed.\n" : "This guide requires Apple Silicon.\n") + usbMessage
            }.value
            status = result
            busy = false
        }
    }

    func verifyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        busy = true
        Task {
            let result = await Task.detached {
                do {
                    let data = try Data(contentsOf: folder.appendingPathComponent("hashes.json"))
                    let hashes = try JSONDecoder().decode([String: String].self, from: data)
                    var lines: [String] = []
                    for name in hashes.keys.sorted() {
                        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("/") else { throw CocoaError(.fileReadInvalidFileName) }
                        let url = folder.appendingPathComponent(name)
                        guard FileManager.default.fileExists(atPath: url.path) else { lines.append("Missing: \(name)"); continue }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        var hasher = SHA256()
                        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
                        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                        lines.append((actual == hashes[name] ? "Matches selected manifest: " : "HASH MISMATCH: ") + name)
                    }
                    return lines.isEmpty ? "Manifest is empty; nothing verified." : lines.joined(separator: "\n")
                } catch { return "Unable to verify: \(error.localizedDescription)" }
            }.value
            files = result
            busy = false
        }
    }

    func prepareDownloads() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to save UTM 5.0.6 and the CHECKERS ROM (about 790 MB). Files are verified before they become available; nothing is installed."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        busy = true
        Task {
            var completed: [String] = []
            do {
                for artifact in preparationArtifacts {
                    files = (completed + ["Downloading or checking \(artifact.name)…"]).joined(separator: "\n")
                    let result = try await Task.detached { try await prepareArtifact(artifact, in: folder) }.value
                    completed.append(result)
                }
                files = (completed + ["Download preparation complete. VM creation and the maintainer’s unlock package remain separate steps."]).joined(separator: "\n")
            } catch { files = (completed + ["Stopped: \(error.localizedDescription)"]).joined(separator: "\n") }
            busy = false
        }
    }
}
