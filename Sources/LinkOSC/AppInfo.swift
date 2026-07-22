import Foundation

/// アプリバージョンの単一の管理元。
/// build_app.sh がこの値を読んで .app の Info.plist に書き込むため、
/// ここを更新するだけで UI 表示・ウィンドウタイトル・バンドルすべてに反映される。
enum AppInfo {
    static let version = "1.0.17"
    static let build = "21"

    static var display: String { "v\(version) (\(build))" }
}
