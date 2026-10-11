import Foundation

/// Normalizes printed unit spellings to the canonical forms used by `AnalyteDictionary`.
public enum LabUnits {
    static let table: [String: String] = [
        "mg/dl": "mg/dL", "g/dl": "g/dL", "ug/dl": "ug/dL", "µg/dl": "ug/dL", "mcg/dl": "ug/dL", "ng/dl": "ng/dL",
        "mmol/l": "mmol/L", "meq/l": "mEq/L", "umol/l": "umol/L", "µmol/l": "umol/L", "nmol/l": "nmol/L", "pmol/l": "pmol/L",
        "mmol/mol": "mmol/mol", "g/l": "g/L", "mg/l": "mg/L", "ug/l": "ug/L", "µg/l": "ug/L", "mcg/l": "ug/L",
        "ng/ml": "ng/mL", "pg/ml": "pg/mL", "uiu/ml": "uIU/mL", "µiu/ml": "uIU/mL", "miu/l": "mIU/L",
        "u/l": "U/L", "iu/l": "U/L", "%": "%", "fl": "fL", "pg": "pg", "mg/g": "mg/g", "mg/gcreat": "mg/g", "ratio": "ratio",
        "x10e3/ul": "10*3/uL", "10e3/ul": "10*3/uL", "10^3/ul": "10*3/uL", "10*3/ul": "10*3/uL", "k/ul": "10*3/uL",
        "thousand/ul": "10*3/uL", "10^9/l": "10*9/L", "x10^9/l": "10*9/L", "10*9/l": "10*9/L", "x10e9/l": "10*9/L",
        "x10e6/ul": "10*6/uL", "10e6/ul": "10*6/uL", "10^6/ul": "10*6/uL", "10*6/ul": "10*6/uL", "m/ul": "10*6/uL",
        "million/ul": "10*6/uL", "10^12/l": "10*12/L", "x10^12/l": "10*12/L", "10*12/l": "10*12/L", "x10e12/l": "10*12/L",
        "ml/min/1.73m2": "mL/min/1.73m2", "ml/min/1.73": "mL/min/1.73m2", "ml/min/1.73m^2": "mL/min/1.73m2",
    ]

    /// Canonical unit for a printed token, or nil if it isn't a unit we know.
    public static func normalize(_ token: String) -> String? {
        let t = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[],;"))
        return table[t]
    }

    /// Joins units that reports print with spaces ("mL/min/1.73 m2", "x10E3 /uL") so they tokenize as one.
    static func preJoin(_ s: String) -> String {
        s.replacingOccurrences(of: "1.73 m2", with: "1.73m2")
            .replacingOccurrences(of: "1.73 m^2", with: "1.73m^2")
            .replacingOccurrences(of: " /uL", with: "/uL")
            .replacingOccurrences(of: " /L", with: "/L")
            .replacingOccurrences(of: "mg/g creat", with: "mg/gcreat")
    }
}
