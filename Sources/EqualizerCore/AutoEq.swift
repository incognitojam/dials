import Foundation

package enum AutoEq {
    package enum ParseError: Error, Equatable {
        case invalidLine(Int)
        case missingPreamp
    }

    package static func parse(_ text: String) throws -> ParametricEQ {
        var gain: Double?
        var bands: [Band] = []
        let input = text.first == "\u{feff}" ? text.dropFirst() : text[...]
        for (i, line) in input.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let invalid = ParseError.invalidLine(i + 1)
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let colon = line.firstIndex(of: ":") else { throw invalid }
            let command = line[..<colon].split(whereSeparator: \.isWhitespace)
            let fields = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
            func number(_ index: Int) throws -> Double {
                let token = fields[index]
                if let comma = token.firstIndex(of: ","), token.distance(from: comma, to: token.endIndex) == 4 {
                    throw invalid
                }
                guard let x = Double(token.replacingOccurrences(of: ",", with: ".")), x.isFinite else { throw invalid }
                return x
            }
            if command.count == 1, command[0].lowercased() == "preamp" {
                guard gain == nil, fields.count == 2, fields[1] == "dB" else { throw invalid }
                gain = try number(0)
                continue
            }
            guard command.first == "Filter", command.count <= 2 else { throw invalid }
            if command.count == 2 {
                guard let n = Int(command[1]), n > 0 else { throw invalid }
            }
            if fields.first == "OFF" { continue }
            guard fields.count >= 5, fields[0] == "ON", fields[2] == "Fc", fields[4] == "Hz" else { throw invalid }
            let kind: Band.Kind
            switch fields[1] {
            case "PK": kind = .peakDip
            case "LSC": kind = .lowShelf
            case "HSC": kind = .highShelf
            case "LP": kind = .lowPass
            case "HP": kind = .highPass
            default: throw invalid
            }
            let f = try number(3)
            do {
                if kind == .lowPass || kind == .highPass {
                    guard fields.count == 5 else { throw invalid }
                    bands.append(try Band(kind, frequency: f, slope: 12))
                } else {
                    guard fields.count == 10, fields[5] == "Gain", fields[7] == "dB", fields[8] == "Q"
                    else { throw invalid }
                    bands.append(try Band(kind, frequency: f, gainDB: number(6), q: number(9)))
                }
            } catch { throw invalid }
        }
        guard let gain else { throw ParseError.missingPreamp }
        return ParametricEQ(gainDB: gain, bands: bands)
    }
}
