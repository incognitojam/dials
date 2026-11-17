import Foundation

package struct EQInfo: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Sendable { case parametric = "parametric_eq" }

    package let type: Kind
    package let author: String
    package let details: String?
    package let link: String?
    package let productID: String?
    package let parameters: ParametricEQ

    enum CodingKeys: String, CodingKey {
        case type, author, details, link, parameters
        case productID = "product_id"
    }

    package init(author: String, details: String? = nil, link: String? = nil,
                productID: String? = nil, parameters: ParametricEQ) {
        self.type = .parametric
        self.author = author
        self.details = details
        self.link = link
        self.productID = productID
        self.parameters = parameters
    }
}

package struct ParametricEQ: Codable, Hashable, Sendable {
    package var gainDB: Double
    package var bands: [Band]

    enum CodingKeys: String, CodingKey {
        case gainDB = "gain_db"
        case bands
    }

    package init(gainDB: Double, bands: [Band]) {
        self.gainDB = gainDB
        self.bands = bands
    }
}

package struct Band: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case peakDip = "peak_dip", lowShelf = "low_shelf", highShelf = "high_shelf"
        case lowPass = "low_pass", highPass = "high_pass", bandPass = "band_pass", bandStop = "band_stop"
    }

    package enum Invalid: Error { case frequency, gain, q, slope }

    package let kind: Kind
    package let frequency: Double
    package let gainDB: Double
    package let q: Double?
    package let slope: Int?

    enum CodingKeys: String, CodingKey {
        case kind = "type", frequency, gainDB = "gain_db", q, slope
    }

    package init(_ kind: Kind, frequency: Double, gainDB: Double = 0, q: Double? = nil, slope: Int? = nil) throws {
        guard frequency.isFinite, frequency > 0 else { throw Invalid.frequency }
        guard gainDB.isFinite else { throw Invalid.gain }
        switch kind {
        case .lowPass, .highPass:
            guard [6, 12, 18, 24, 30, 36].contains(slope ?? 12) else { throw Invalid.slope }
            self.slope = slope ?? 12
            self.q = nil
        default:
            guard let q, q.isFinite, q >= 0.1 else { throw Invalid.q }
            self.q = q
            self.slope = nil
        }
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let value = try c.decodeIfPresent(Double.self, forKey: .slope)
            let slope = value.flatMap(Int.init(exactly:))
            if value != nil && slope == nil {
                throw DecodingError.dataCorruptedError(forKey: .slope, in: c,
                                                       debugDescription: "Expected a whole-number slope in dB/octave")
            }
            try self.init(c.decode(Kind.self, forKey: .kind),
                          frequency: c.decode(Double.self, forKey: .frequency),
                          gainDB: c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0,
                          q: c.decodeIfPresent(Double.self, forKey: .q),
                          slope: slope)
        } catch let reason as Invalid {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid band \(reason)"))
        }
    }
}
