import SwiftUI
import AppKit

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--version") {
            print("LinkOSC \(AppInfo.display)")
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else if CommandLine.arguments.contains("--publish") {
            PublishTest.run()
        } else if CommandLine.arguments.contains("--bench") {
            BenchTest.run()
        } else if CommandLine.arguments.contains("--bpmtest") {
            AutoBPMTest.run()
        } else if CommandLine.arguments.contains("--desttest") {
            DestTest.run()
        } else if CommandLine.arguments.contains("--ifacetest") {
            IfaceTest.run()
        } else if CommandLine.arguments.contains("--inputtest") {
            InputDeviceTest.run()
        } else if CommandLine.arguments.contains("--autogaintest") {
            AutoGainTest.run()
        } else if CommandLine.arguments.contains("--docshot") {
            DocShot.runStandalone()
        } else if CommandLine.arguments.contains("--pacetest") {
            PaceTest.run()
        } else if CommandLine.arguments.contains("--oscstress") {
            OSCStressTest.run()
        } else if CommandLine.arguments.contains("--devtest") {
            DevTest.run()
        } else if CommandLine.arguments.contains("--probe") {
            ProbeTest.run()
        } else if CommandLine.arguments.contains("--rxtest") {
            RxTest.run()
        } else {
            LinkOSCApp.main()
        }
    }
}

struct LinkOSCApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("LinkOSC \(AppInfo.display)") {
            ContentView(model: model)
                .onAppear {
                    // bare executable (swift run) でもウィンドウを表示するための
                    // ポリシー設定のみ。activate(ignoringOtherApps:) は onAppear の
                    // 再発火のたびに自分を最前面へ出してしまうため呼ばない —
                    // このアプリは他ツールの裏で動き続けるユーティリティ。
                    NSApplication.shared.setActivationPolicy(.regular)
                    Self.migrateWindowHeightOnce()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1280, height: 900)
    }

    /// v1.0.13 の高さ拡張 (720 → 900) を既存ユーザーのウィンドウに一度だけ適用する。
    /// 旧サイズは defaults の "NSWindow Frame" キーを消しても復元される
    /// (ウィンドウサーバ側の永続化) ため、コードで引き上げるしかない。
    /// 位置と幅・上端は維持し、以後の手動リサイズはこのフラグにより尊重される。
    private static func migrateWindowHeightOnce() {
        let flag = "com.fil.linkosc.height900migrated"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: { $0.isVisible }),
                  w.frame.height < 920 else { return }
            var f = w.frame
            let top = f.maxY
            f.size.height = 932 // content 900 + titlebar
            f.origin.y = max(top - f.size.height, 0)
            w.setFrame(f, display: true, animate: false)
        }
    }
}
