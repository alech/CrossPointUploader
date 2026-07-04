import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

final class Uploader: ObservableObject {
    static let shared = Uploader()

    @Published var epubURL: URL?
    @Published var ssid: String = "CrossPoint-Reader"
    @Published var password: String = ""            // open network -> leave empty
    @Published var targetPath: String = "/"          // folder on the device's SD card
    @Published var reconnectAfter: Bool = true
    @Published var log: String = ""
    @Published var busy: Bool = false

    /// Headless mode: run the whole sequence on launch and exit when done.
    var autoRun = false
    /// Also echo the log to stdout (so it's visible when launched from a terminal).
    var mirrorToStdout = false

    private let host = "crosspoint.local"

    // MARK: UI-thread helpers

    private func append(_ s: String) {
        if mirrorToStdout {
            FileHandle.standardOutput.write(Data((s + "\n").utf8))
        }
        DispatchQueue.main.async { self.log += s + "\n" }
    }
    private func setBusy(_ b: Bool) {
        DispatchQueue.main.async { self.busy = b }
    }

    // MARK: Shell

    @discardableResult
    private func shell(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "failed to launch \(path): \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, text)
    }

    private func wifiDevice() -> String? {
        let out = shell("/usr/sbin/networksetup", ["-listallhardwareports"]).out
        let lines = out.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            guard i + 1 < lines.count, let r = lines[i + 1].range(of: "Device: ") else { continue }
            return String(lines[i + 1][r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func currentSSID(device: String) -> String? {
        let out = shell("/usr/sbin/networksetup", ["-getairportnetwork", device]).out
        guard let r = out.range(of: "Current Wi-Fi Network: ") else { return nil }
        return String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Entry point

    func start() {
        guard !busy else { return }
        guard let url = epubURL else {
            append("⚠️  Choose an EPUB file first.")
            if autoRun { finish(false) }
            return
        }
        setBusy(true)
        let ssid = self.ssid, pw = self.password, target = self.targetPath, reconnect = self.reconnectAfter
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.run(url: url, ssid: ssid, pw: pw, target: target, reconnect: reconnect)
            self.setBusy(false)
            if self.autoRun { self.finish(ok) }
        }
    }

    /// Flush a final beat, then exit the process with a shell-friendly status code.
    private func finish(_ ok: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(ok ? 0 : 1) }
    }

    @discardableResult
    private func run(url: URL, ssid: String, pw: String, target: String, reconnect: Bool) -> Bool {
        append("── Starting ──")
        guard let dev = wifiDevice() else { append("❌ Could not find a Wi-Fi interface."); return false }
        append("Wi-Fi interface: \(dev)")

        let previous = currentSSID(device: dev)
        if let prev = previous, !prev.isEmpty { append("Current network: \(prev)") }

        // Make sure the radio is on, otherwise the join silently fails.
        _ = shell("/usr/sbin/networksetup", ["-setairportpower", dev, "on"])

        append("Joining “\(ssid)” …")
        var args = ["-setairportnetwork", dev, ssid]
        if !pw.isEmpty { args.append(pw) }
        let join = shell("/usr/sbin/networksetup", args)
        let joinOut = join.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !joinOut.isEmpty { append(joinOut) }
        if join.code != 0 {
            append("❌ Failed to join network (exit \(join.code)).")
            return false     // never left the original network, nothing to restore
        }

        append("Waiting for http://\(host) … (put the reader in File Transfer mode)")
        if !waitForDevice(timeout: 30) {
            append("❌ Device did not respond. Is it in File Transfer mode and are you on its Wi-Fi?")
            maybeReconnect(reconnect, dev: dev, previous: previous)
            return false
        }
        append("✅ Device is reachable.")

        append("Uploading “\(url.lastPathComponent)” → \(target) …")
        var ok = false
        switch upload(fileURL: url, targetPath: target) {
        case .success(let status, let body):
            ok = (200..<300).contains(status)
            append(ok ? "✅ Upload complete (HTTP \(status))."
                      : "⚠️  Server returned HTTP \(status).")
            if !body.isEmpty { append(body) }
        case .failure(let err):
            append("❌ Upload failed: \(err.localizedDescription)")
        }

        maybeReconnect(reconnect, dev: dev, previous: previous)
        append("── Done ──")
        return ok
    }

    private func maybeReconnect(_ reconnect: Bool, dev: String, previous: String?) {
        guard reconnect else { return }

        // Explicitly rejoin the network we were on before. It's already in the
        // preferred list, so macOS has the saved credentials and no password
        // needs to be supplied.
        if let prev = previous, !prev.isEmpty {
            append("Reconnecting to “\(prev)” …")
            let res = shell("/usr/sbin/networksetup", ["-setairportnetwork", dev, prev])
            let out = res.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if res.code == 0 && !out.lowercased().contains("could not") && !out.lowercased().contains("error") {
                if !out.isEmpty { append(out) }
                append("✅ Back on “\(prev)”.")
                return
            }
            append("Direct rejoin didn’t take\(out.isEmpty ? "" : " (\(out))"); power-cycling Wi-Fi …")
        } else {
            append("No previous network was recorded; power-cycling Wi-Fi so macOS reconnects …")
        }

        // Fallback: bounce the radio and let macOS auto-associate with its
        // highest-priority known network.
        _ = shell("/usr/sbin/networksetup", ["-setairportpower", dev, "off"])
        Thread.sleep(forTimeInterval: 1.5)
        _ = shell("/usr/sbin/networksetup", ["-setairportpower", dev, "on"])
    }

    // MARK: Networking

    private func waitForDevice(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard let url = URL(string: "http://\(host)/") else { return false }
        while Date() < deadline {
            let sem = DispatchSemaphore(value: 0)
            var reachable = false
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let task = URLSession.shared.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse, http.statusCode > 0 { reachable = true }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 4)
            if reachable { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private enum Outcome {
        case success(Int, String)
        case failure(Error)
    }

    private func upload(fileURL: URL, targetPath: String) -> Outcome {
        guard var comps = URLComponents(string: "http://\(host)/upload") else {
            return .failure(err("Bad URL"))
        }
        comps.queryItems = [URLQueryItem(name: "path", value: targetPath.isEmpty ? "/" : targetPath)]
        guard let endpoint = comps.url else { return .failure(err("Bad URL")) }

        guard let fileData = try? Data(contentsOf: fileURL) else {
            return .failure(err("Cannot read \(fileURL.lastPathComponent)"))
        }

        let boundary = "----CrossPoint-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        add("Content-Type: application/epub+zip\r\n\r\n")
        body.append(fileData)
        add("\r\n--\(boundary)--\r\n")

        let sem = DispatchSemaphore(value: 0)
        var outcome: Outcome = .failure(err("No response from device"))
        let task = URLSession.shared.uploadTask(with: req, from: body) { data, resp, error in
            if let error = error {
                outcome = .failure(error)
            } else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let text = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                outcome = .success(status, text)
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 610)
        return outcome
    }

    private func err(_ msg: String) -> Error {
        NSError(domain: "CrossPoint", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - View

struct ContentView: View {
    @EnvironmentObject var model: Uploader
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CrossPoint Uploader")
                .font(.title2).bold()

            dropZone

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Wi-Fi SSID").gridColumnAlignment(.trailing)
                    TextField("CrossPoint-Reader", text: $model.ssid)
                }
                GridRow {
                    Text("Password")
                    SecureField("(leave empty for open network)", text: $model.password)
                }
                GridRow {
                    Text("Device folder")
                    TextField("/", text: $model.targetPath)
                }
            }
            .textFieldStyle(.roundedBorder)

            Toggle("Reconnect to my usual Wi-Fi when finished", isOn: $model.reconnectAfter)

            HStack {
                Button(action: choose) { Text("Choose EPUB…") }
                Spacer()
                if model.busy { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button(action: model.start) {
                    Text(model.busy ? "Working…" : "Connect & Upload").bold()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || model.epubURL == nil)
            }

            LogView(text: model.log)
                .frame(minHeight: 150)
        }
        .padding(18)
        .frame(minWidth: 500, minHeight: 540)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundColor(dropTargeted ? .accentColor : .secondary.opacity(0.5))
            .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .frame(height: 72)
            .overlay(
                Text(model.epubURL?.lastPathComponent ?? "Drop an .epub here or click “Choose EPUB…”")
                    .foregroundColor(model.epubURL == nil ? .secondary : .primary)
                    .padding(.horizontal, 10)
                    .lineLimit(1).truncationMode(.middle)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in
                    guard let url = obj as? URL, url.pathExtension.lowercased() == "epub" else { return }
                    DispatchQueue.main.async { model.epubURL = url }
                }
                return true
            }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let epub = UTType(filenameExtension: "epub") {
            panel.allowedContentTypes = [epub]
        }
        if panel.runModal() == .OK { model.epubURL = panel.url }
    }
}

/// Read-only, auto-scrolling log backed by NSTextView.
struct LogView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.scrollToEndOfDocument(nil)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // An .epub given on the command line triggers headless auto mode:
        //   ./CrossPointUploader.app/Contents/MacOS/CrossPointUploader book.epub
        //   open CrossPointUploader.app --args /path/book.epub
        let epubArg = CommandLine.arguments.dropFirst()
            .map { URL(fileURLWithPath: $0) }
            .first {
                $0.pathExtension.lowercased() == "epub"
                    && FileManager.default.fileExists(atPath: $0.path)
            }

        if let url = epubArg {
            // Headless: no window focus-stealing, run everything, then exit.
            NSApp.setActivationPolicy(.accessory)
            let m = Uploader.shared
            m.epubURL = url
            m.mirrorToStdout = true
            m.autoRun = true
            m.start()
        } else {
            // Interactive: normal windowed app, brought to the front.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Finder double-click, or: open -a CrossPointUploader.app book.epub
    func application(_ application: NSApplication, open urls: [URL]) {
        if let epub = urls.first(where: { $0.pathExtension.lowercased() == "epub" }) {
            Uploader.shared.epubURL = epub
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CrossPointUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Uploader.shared

    var body: some Scene {
        WindowGroup("CrossPoint Uploader") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
