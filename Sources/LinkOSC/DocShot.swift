import AppKit
import SwiftUI
import CoreGraphics

/// `LinkOSC --docshot <out.png> [delaySeconds]` : ドキュメント用の自己スクリーンショット。
///
/// README / マニュアルのスクリーンショットを再現性のある形で生成する開発モード。
/// 通常の GUI と同じ ContentView + AppModel を NSWindow に直接ホストし、
/// delay 秒後に自分のウィンドウをウィンドウサーバからキャプチャして PNG に
/// 書き出して終了する。
///
/// SwiftUI の WindowGroup を使わない理由: バックグラウンドのプロセスから
/// `open` で起動するとアクティベーションが成立せず (macOS 14+ の協調
/// アクティベーション)、SwiftUI はウィンドウ生成を保留し続ける。
/// NSWindow + `orderFrontRegardless()` はアクティベーション無しで表示でき、
/// 可視化 (OcclusionPausingMTKView) も遮蔽されないため描画が動く。
/// 自プロセスのウィンドウのキャプチャは画面収録権限 (TCC) が不要。
enum DocShot {
    private static var window: NSWindow?

    /// open 経由だと stdout/stderr が見えないため、<out>.log に段階ログを残す
    private static func log(_ s: String, _ out: String) {
        let u = URL(fileURLWithPath: out + ".log")
        let line = s + "\n"
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: u, atomically: true, encoding: .utf8)
        }
    }

    static func runStandalone() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--docshot"),
              CommandLine.arguments.count > idx + 1 else {
            print("usage: LinkOSC --docshot <out.png> [delaySeconds]")
            exit(64)
        }
        let out = CommandLine.arguments[idx + 1]
        let delay = Double(CommandLine.arguments.count > idx + 2
                           ? CommandLine.arguments[idx + 2] : "") ?? 12.0
        log("standalone start delay=\(delay)", out)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let model = AppModel()
        let host = NSHostingView(rootView: ContentView(model: model))
        // ContentView の ideal サイズに追従 (ハードコードすると本体と乖離する)
        var size = host.fittingSize
        if size.width < 800 || size.height < 500 {
            size = NSSize(width: 1280, height: 900)
        }
        let win = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "LinkOSC \(AppInfo.display)"
        win.contentView = host
        win.orderFrontRegardless()
        window = win
        log("window up num=\(win.windowNumber) frame=\(win.frame)", out)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(win: win, out: out)
        }
        app.run()
    }

    private static func capture(win: NSWindow, out: String) {
        var img = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(win.windowNumber),
            [.boundsIgnoreFraming, .bestResolution])
        if img == nil {
            // ウィンドウサーバ経由が塞がれている場合のフォールバック:
            // 自ビューの描画 (タイトルバー無し・Metal は写らない可能性)
            log("CGWindowListCreateImage nil -> cacheDisplay fallback", out)
            if let view = win.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                img = rep.cgImage
            }
        }
        guard let cg = img else {
            log("FAIL both capture paths nil", out)
            exit(3)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            log("FAIL png encode", out)
            exit(4)
        }
        do {
            try png.write(to: URL(fileURLWithPath: out))
            log("OK \(cg.width)x\(cg.height) -> \(out)", out)
            exit(0)
        } catch {
            log("FAIL write: \(error)", out)
            exit(5)
        }
    }
}
