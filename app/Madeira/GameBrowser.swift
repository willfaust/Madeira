// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit
import WebKit
import Combine
import Darwin
import GameBrowserKit

@_cdecl("madeira_browser_register")
func madeiraBrowserRegister(_ prefix: UnsafePointer<CChar>?) {
    guard getenv("MADEIRA_BROWSER_ADDRESS") != nil, let prefix else { return }
    let file = URL(fileURLWithPath: String(cString: prefix)).appendingPathComponent("user.reg")
    guard file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL else { return }
    do {
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else { return }
        let updated = BrowserRegistry.install(in: text)
        guard updated != text else { return }
        let backup = file.appendingPathExtension("madeira-browser.bak")
        if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .withoutOverwriting) }
        try Data(updated.utf8).write(to: file, options: .atomic)
    } catch { fputs("[game-browser] protocol registration unavailable\n", stderr) }
}

private final class GameBrowserSocket: @unchecked Sendable {
    let address: String
    private let fd: Int32
    private let token = UUID().uuidString
    private let lock = NSLock()
    private var stopped = false

    init(receive: @escaping @Sendable (UrlOpenRequest) -> Void) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        fd = socketFD
        guard fd >= 0 else { throw LibraryError.message("Cannot create the game browser socket.") }
        var local = sockaddr_in(); local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET); local.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) }
        }
        guard bound == 0, named == 0, listen(fd, 4) == 0 else { close(fd); throw LibraryError.message("Cannot start the game browser socket.") }
        address = "\(UInt16(bigEndian: local.sin_port))/\(token)"
        Thread { [self] in
            defer { close(fd) }
            while !lock.withLock({ stopped }) {
                var wait = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&wait, 1, 250) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                serve(client, receive: receive)
                close(client)
            }
        }.start()
    }

    func stop() { lock.withLock { stopped = true; shutdown(fd, SHUT_RDWR) } }

    private func serve(_ client: Int32, receive: @Sendable (UrlOpenRequest) -> Void) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0), one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        var request: UrlOpenRequest?
        while bytes.count <= 6144 && !lock.withLock({ stopped }) {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            bytes.append(contentsOf: buffer.prefix(count))
            do {
                request = try BrowserHTTPRequest.parse(bytes, token: token)
                if request != nil { break }
            } catch { break }
        }
        if let request { receive(request) }
        let reply = Data("HTTP/1.1 \(request == nil ? "400 Bad Request" : "202 Accepted")\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        reply.withUnsafeBytes { raw in _ = send(client, raw.baseAddress, raw.count, 0) }
    }
}

@MainActor final class GameBrowser {
    static let shared = GameBrowser()
    private var server: GameBrowserSocket?
    private var watching: AnyCancellable?
    private var presenting = false
    private var previousMenu = false

    private init() {
        watching = LibraryModel.shared.$current.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] current in
            if current == nil { self?.server?.stop(); self?.server = nil; unsetenv("MADEIRA_BROWSER_ADDRESS") }
        }
    }

    func start() {
        guard server == nil else { return }
        do {
            server = try GameBrowserSocket { request in Task { @MainActor in GameBrowser.shared.offer(request) } }
            setenv("MADEIRA_BROWSER_ADDRESS", server!.address, 1)
        } catch { LogStore.shared.log("[game-browser] unavailable") }
    }

    private func offer(_ request: UrlOpenRequest) {
        guard !presenting, LibraryModel.shared.current != nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let session = LibraryModel.shared.current
        presenting = true
        previousMenu = LibraryModel.shared.menu
        LibraryModel.shared.showMenu()
        let alert = UIAlertController(title: "Open \(request.host)?", message: "The running game requested this web page.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finished() })
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self, weak top] _ in
            guard let top else { self?.finished(); return }
            top.dismiss(animated: true) {
            Task { @MainActor in
                guard let self, LibraryModel.shared.current != nil else { self?.finished(); return }
                let url = await EpicLibrary.shared.browserActivationURL(request)
                guard LibraryModel.shared.current == session else { self.finished(); return }
                let panel = GameWebPanel(url: url, epic: request.kind == .epicActivation) { [weak self] in self?.finished() }
                let nav = UINavigationController(rootViewController: panel)
                top.present(nav, animated: true) { nav.presentationController?.delegate = panel }
            }
            }
        })
        top.present(alert, animated: true)
    }

    private func finished() {
        guard presenting else { return }
        presenting = false
        if LibraryModel.shared.current != nil { LibraryModel.shared.menu = previousMenu }
    }
}

private final class GameWebPanel: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    private let url: URL
    private let epic: Bool
    private let finished: () -> Void
    private var web: WKWebView!
    init(url: URL, epic: Bool, finished: @escaping () -> Void) { self.url = url; self.epic = epic; self.finished = finished; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func loadView() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; web.uiDelegate = self
        view = web; title = url.host
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Back", style: .plain, target: self, action: #selector(back))
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        web.load(URLRequest(url: url))
    }
    @objc private func back() { web.goBack() }
    @objc private func close() { dismiss(animated: true, completion: finished) }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finished() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { title = webView.url?.host; navigationItem.leftBarButtonItem?.isEnabled = webView.canGoBack }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let alert = UIAlertController(title: "Page unavailable", message: "Check the connection, then try again.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in self?.close() })
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in self?.web.reload() })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, UrlOpenRequest.classify(url.absoluteString) != nil else { decisionHandler(.cancel); return }
        if epic {
            let host = url.host?.lowercased() ?? ""
            guard url.scheme == "https", host == "epicgames.com" || host.hasSuffix(".epicgames.com") else { decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }
}
