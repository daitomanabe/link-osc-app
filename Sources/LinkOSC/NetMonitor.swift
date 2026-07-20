import Foundation
import Network

/// 送信インターフェースの選択肢 (UI Picker 用)
struct IfaceChoice: Identifiable, Equatable {
    let name: String   // "en0" — 設定にはこのキーを保存する
    let label: String  // "en0 (Wi-Fi)"
    var id: String { name }
}

/// NWPathMonitor のラッパー。送信インターフェース選択と構成変化の監視を担う。
///
/// - 選択肢は実在するインターフェースだけを列挙する。NWInterface は名前から
///   構築できず、NWPath 経由でしか取得できないため、ここが唯一の入手経路
/// - 構成変化 (ケーブル挿抜 / Wi-Fi 切替) で onChange を呼び、呼び出し側は
///   全宛先の NWConnection を張り直す — 古い経路を掴んだままの接続を残さない
/// - 選択された NIC が消えたら resolve が nil を返し、呼び出し側は Auto へ
///   フォールバックする (「昔選んだ USB-LAN が無くて全滅」を防ぐ)
final class NetMonitor {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var ifaces: [(name: String, type: NWInterface.InterfaceType, iface: NWInterface)] = []
    private var lastStatus: NWPath.Status?
    private var primed = false
    /// 構成が変わったときに monitor のキュー上で呼ばれる
    var onChange: (() -> Void)?

    func start(queue: DispatchQueue) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // 物理 NIC のみ (Wi-Fi / 有線)。utun 等の仮想 IF はノイズなので出さない —
            // VPN 宛のユニキャストは Auto (OS ルーティング) が正しく処理する。
            // availableInterfaces は同名を重複して返すことがある (実測) ので
            // 名前でデデュープする — 重複タグは SwiftUI Picker を壊す
            var seen = Set<String>()
            let list = path.availableInterfaces
                .filter { $0.type == .wifi || $0.type == .wiredEthernet }
                .filter { seen.insert($0.name).inserted }
                .map { (name: $0.name, type: $0.type, iface: $0) }
            lock.lock()
            let changed = !primed
                || ifaces.map(\.name) != list.map(\.name)
                || lastStatus != path.status
            ifaces = list
            lastStatus = path.status
            primed = true
            lock.unlock()
            if changed { onChange?() }
        }
        monitor.start(queue: queue)
    }

    /// 最初の path 更新を受け取ったか (起動直後の「NIC が無い」誤警告を防ぐ)
    func isPrimed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return primed
    }

    func choices() -> [IfaceChoice] {
        lock.lock(); defer { lock.unlock() }
        return ifaces.map { i in
            IfaceChoice(name: i.name,
                        label: "\(i.name) (\(i.type == .wifi ? "Wi-Fi" : "Ethernet"))")
        }
    }

    /// 保存された名前を実在の NWInterface へ解決。見つからなければ nil (= Auto)
    func resolve(_ name: String) -> NWInterface? {
        lock.lock(); defer { lock.unlock() }
        return ifaces.first { $0.name == name }?.iface
    }
}
