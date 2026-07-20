import Foundation

/// SMF (format 0/1) から note-on を抽出した、ループ用 MIDI データ。
/// テンポ情報は無視し、beat 位置 (ticks / division) のみ使用する。
struct MidiLoop {
    struct Note {
        let beat: Double
        let note: UInt8
        let velocity: UInt8
    }

    let notes: [Note]     // beat 昇順
    let loopBeats: Double // WAV 未読み込み時に使う SMF EOT 由来のフォールバック

    static func load(path: String) throws -> MidiLoop {
        let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))

        func err(_ msg: String) -> NSError {
            NSError(domain: "MidiLoop", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard data.count > 14, Array(data[0..<4]) == Array("MThd".utf8) else {
            throw err("Not a Standard MIDI File")
        }
        func u16(_ p: Int) -> Int { Int(data[p]) << 8 | Int(data[p + 1]) }
        func u32(_ p: Int) -> Int {
            Int(data[p]) << 24 | Int(data[p + 1]) << 16 | Int(data[p + 2]) << 8 | Int(data[p + 3])
        }
        let ntracks = u16(10)
        let division = u16(12)
        guard division > 0, division & 0x8000 == 0 else {
            throw err("SMPTE division is not supported")
        }

        var notes: [Note] = []
        var maxTick = 0
        var pos = 14

        for _ in 0..<ntracks {
            guard pos + 8 <= data.count, Array(data[pos..<pos + 4]) == Array("MTrk".utf8) else {
                throw err("MTrk chunk not found")
            }
            let trackEnd = pos + 8 + u32(pos + 4)
            var p = pos + 8
            var tick = 0
            var status: UInt8 = 0

            func varLen() -> Int {
                var v = 0
                while p < data.count {
                    let b = data[p]; p += 1
                    v = (v << 7) | Int(b & 0x7F)
                    if b & 0x80 == 0 { break }
                }
                return v
            }

            while p < trackEnd {
                tick += varLen()
                guard p < trackEnd else { break }
                if data[p] & 0x80 != 0 {
                    status = data[p]; p += 1
                }
                switch status {
                case 0xFF:
                    p += 1 // meta type
                    let len = varLen()
                    p += len
                case 0xF0, 0xF7:
                    let len = varLen()
                    p += len
                default:
                    switch status & 0xF0 {
                    case 0x80, 0xA0, 0xB0, 0xE0:
                        p += 2
                    case 0x90:
                        let note = data[p], vel = data[p + 1]
                        p += 2
                        if vel > 0 {
                            notes.append(Note(beat: Double(tick) / Double(division),
                                              note: note, velocity: vel))
                        }
                    case 0xC0, 0xD0:
                        p += 1
                    default:
                        throw err("Invalid MIDI event")
                    }
                }
            }
            maxTick = max(maxTick, tick)
            pos = trackEnd
        }

        notes.sort { $0.beat < $1.beat }
        // EOT を最も近い整数拍に丸めてループ長にする (例: 15.98 → 16)
        let eotBeats = Double(maxTick) / Double(division)
        let loopBeats = max(1.0, eotBeats.rounded())
        return MidiLoop(notes: notes, loopBeats: loopBeats)
    }
}
