import Foundation

/// One dictionary analyte. `conversions` maps a normalized unit to the factor that converts it INTO `unit`.
public struct Analyte: Sendable, Hashable {
    public let key: String
    public let name: String
    public let loinc: String
    /// Canonical unit (UCUM-style spelling used across HPL).
    public let unit: String
    public let aliases: [String]
    public let conversions: [String: Double]

    init(_ key: String, _ name: String, _ loinc: String, _ unit: String, _ aliases: [String], _ conversions: [String: Double] = [:]) {
        self.key = key; self.name = name; self.loinc = loinc; self.unit = unit
        self.aliases = ([name] + aliases).map { $0.lowercased() }; self.conversions = conversions
    }

    /// `value` in `unit` converted to the canonical unit, or nil when no conversion is known (never guessed).
    public func toCanonical(_ value: Double, unit from: String) -> Double? {
        if from == unit { return value }
        return conversions[from].map { value * $0 }
    }
}

/// Analyte dictionary v1 (§5.2): ~80 common analytes with LOINC codes and linear unit conversions.
/// Out-of-dictionary rows are still shown for confirmation, but stay out of summaries until mapped.
/// LOINC codes VERIFY: checked against common usage, not yet against a LOINC release file.
public enum AnalyteDictionary {
    public static let all: [Analyte] = metabolic + lipids + cbc + endocrine + micronutrients + other

    static let metabolic: [Analyte] = [
        Analyte("glucose", "Glucose", "2345-7", "mg/dL", ["glucose, serum", "glucose, fasting", "fasting glucose", "glucose fasting",
            "glucose, plasma"], ["mmol/L": 18.016]),
        Analyte("hba1c", "Hemoglobin A1c", "4548-4", "%", ["hba1c", "a1c", "glycated hemoglobin", "glycohemoglobin", "hemoglobin a1c (hba1c)"]),
        Analyte("insulin", "Insulin", "20448-7", "uIU/mL", ["insulin, fasting", "fasting insulin"], ["pmol/L": 1 / 6.0, "mIU/L": 1]),
        Analyte("bun", "Urea Nitrogen (BUN)", "3094-0", "mg/dL", ["bun", "urea nitrogen", "blood urea nitrogen"], ["mmol/L": 2.801]),
        Analyte("creatinine", "Creatinine", "2160-0", "mg/dL", ["creatinine, serum"], ["umol/L": 1 / 88.42]),
        Analyte("egfr", "eGFR", "98979-8", "mL/min/1.73m2", ["estimated gfr", "egfr ckd-epi", "egfr (ckd-epi)", "egfr non-afr. american",
            "egfr if nonafricn am"]),
        Analyte("bun_creatinine_ratio", "BUN/Creatinine Ratio", "3097-3", "ratio", ["bun/creat ratio", "urea nitrogen/creatinine ratio"]),
        Analyte("sodium", "Sodium", "2951-2", "mmol/L", ["sodium, serum"], ["mEq/L": 1]),
        Analyte("potassium", "Potassium", "2823-3", "mmol/L", ["potassium, serum"], ["mEq/L": 1]),
        Analyte("chloride", "Chloride", "2075-0", "mmol/L", ["chloride, serum"], ["mEq/L": 1]),
        Analyte("co2", "Carbon Dioxide, Total", "2028-9", "mmol/L", ["carbon dioxide", "co2", "bicarbonate", "total co2"], ["mEq/L": 1]),
        Analyte("calcium", "Calcium", "17861-6", "mg/dL", ["calcium, serum"], ["mmol/L": 4.008]),
        Analyte("protein_total", "Protein, Total", "2885-2", "g/dL", ["total protein"], ["g/L": 0.1]),
        Analyte("albumin", "Albumin", "1751-7", "g/dL", ["albumin, serum"], ["g/L": 0.1]),
        Analyte("globulin", "Globulin", "10834-0", "g/dL", ["globulin, total"], ["g/L": 0.1]),
        Analyte("ag_ratio", "A/G Ratio", "1759-0", "ratio", ["albumin/globulin ratio"]),
        Analyte("bilirubin_total", "Bilirubin, Total", "1975-2", "mg/dL", ["total bilirubin"], ["umol/L": 1 / 17.1]),
        Analyte("alk_phos", "Alkaline Phosphatase", "6768-6", "U/L", ["alk phos", "alp"]),
        Analyte("ast", "AST", "1920-8", "U/L", ["ast (sgot)", "sgot", "aspartate aminotransferase"]),
        Analyte("alt", "ALT", "1742-6", "U/L", ["alt (sgpt)", "sgpt", "alanine aminotransferase"]),
        Analyte("ggt", "GGT", "2324-2", "U/L", ["gamma-glutamyl transferase", "gamma gt"]),
        Analyte("uric_acid", "Uric Acid", "3084-1", "mg/dL", ["urate"], ["umol/L": 1 / 59.48]),
        Analyte("magnesium", "Magnesium", "19123-9", "mg/dL", ["magnesium, serum"], ["mmol/L": 2.431]),
        Analyte("phosphorus", "Phosphorus", "2777-1", "mg/dL", ["phosphate", "phosphorus, inorganic"], ["mmol/L": 3.097]),
        Analyte("cystatin_c", "Cystatin C", "33863-2", "mg/L", []),
        Analyte("uacr", "Albumin/Creatinine Ratio, Urine", "9318-7", "mg/g", ["albumin/creatinine ratio", "microalbumin/creatinine ratio", "uacr"]),
    ]

    static let lipids: [Analyte] = [
        Analyte("cholesterol_total", "Cholesterol, Total", "2093-3", "mg/dL", ["total cholesterol", "cholesterol"], ["mmol/L": 38.67]),
        Analyte("ldl", "LDL Cholesterol", "13457-7", "mg/dL", ["ldl-cholesterol", "ldl chol calc (nih)", "ldl cholesterol calc", "ldl-c",
            "ldl"], ["mmol/L": 38.67]),
        Analyte("hdl", "HDL Cholesterol", "2085-9", "mg/dL", ["hdl-cholesterol", "hdl-c", "hdl"], ["mmol/L": 38.67]),
        Analyte("triglycerides", "Triglycerides", "2571-8", "mg/dL", ["triglyceride"], ["mmol/L": 88.57]),
        Analyte("vldl", "VLDL Cholesterol", "13458-5", "mg/dL", ["vldl cholesterol cal", "vldl"], ["mmol/L": 38.67]),
        Analyte("non_hdl", "Non-HDL Cholesterol", "43396-1", "mg/dL", ["non hdl cholesterol", "non-hdl-c"], ["mmol/L": 38.67]),
        Analyte("chol_hdl_ratio", "Chol/HDL Ratio", "9830-1", "ratio", ["cholesterol/hdl ratio", "total chol/hdl ratio", "chol/hdlc ratio"]),
        Analyte("apob", "Apolipoprotein B", "1884-6", "mg/dL", ["apob", "apo b"], ["g/L": 100]),
        Analyte("lpa", "Lipoprotein (a)", "10835-7", "nmol/L", ["lipoprotein(a)", "lp(a)"]),
    ]

    static let cbc: [Analyte] = [
        Analyte("wbc", "WBC", "6690-2", "10*3/uL", ["white blood cell count", "white blood cells", "wbc count"], ["10*9/L": 1]),
        Analyte("rbc", "RBC", "789-8", "10*6/uL", ["red blood cell count", "red blood cells", "rbc count"], ["10*12/L": 1]),
        Analyte("hemoglobin", "Hemoglobin", "718-7", "g/dL", ["hgb", "haemoglobin"], ["g/L": 0.1]),
        Analyte("hematocrit", "Hematocrit", "4544-3", "%", ["hct", "haematocrit"]),
        Analyte("mcv", "MCV", "787-2", "fL", ["mean corpuscular volume"]),
        Analyte("mch", "MCH", "785-6", "pg", ["mean corpuscular hemoglobin"]),
        Analyte("mchc", "MCHC", "786-4", "g/dL", [], ["g/L": 0.1]),
        Analyte("rdw", "RDW", "788-0", "%", ["rdw-cv"]),
        Analyte("platelets", "Platelets", "777-3", "10*3/uL", ["platelet count", "plt"], ["10*9/L": 1]),
        Analyte("mpv", "MPV", "32623-1", "fL", ["mean platelet volume"]),
        Analyte("neutrophils_pct", "Neutrophils", "770-8", "%", ["neutrophils %", "neut %"]),
        Analyte("lymphocytes_pct", "Lymphs", "736-9", "%", ["lymphocytes", "lymphocytes %"]),
        Analyte("monocytes_pct", "Monocytes", "5905-5", "%", ["monocytes %"]),
        Analyte("eosinophils_pct", "Eos", "713-8", "%", ["eosinophils", "eosinophils %"]),
        Analyte("basophils_pct", "Basos", "706-2", "%", ["basophils", "basophils %"]),
        Analyte("neutrophils_abs", "Neutrophils (Absolute)", "751-8", "10*3/uL", ["neutrophils, absolute", "absolute neutrophils"], ["10*9/L": 1]),
        Analyte("lymphocytes_abs", "Lymphs (Absolute)", "731-0", "10*3/uL", ["lymphocytes, absolute", "absolute lymphocytes"], ["10*9/L": 1]),
        Analyte("monocytes_abs", "Monocytes (Absolute)", "742-7", "10*3/uL", ["monocytes, absolute", "absolute monocytes"], ["10*9/L": 1]),
        Analyte("eosinophils_abs", "Eos (Absolute)", "711-2", "10*3/uL", ["eosinophils, absolute", "absolute eosinophils"], ["10*9/L": 1]),
        Analyte("basophils_abs", "Baso (Absolute)", "704-7", "10*3/uL", ["basophils, absolute", "absolute basophils"], ["10*9/L": 1]),
    ]

    static let endocrine: [Analyte] = [
        Analyte("tsh", "TSH", "3016-3", "uIU/mL", ["thyroid stimulating hormone"], ["mIU/L": 1]),
        Analyte("free_t4", "Free T4", "3024-7", "ng/dL", ["t4, free", "t4,free(direct)", "free thyroxine", "ft4"], ["pmol/L": 1 / 12.87]),
        Analyte("free_t3", "Free T3", "3051-0", "pg/mL", ["t3, free", "triiodothyronine, free", "ft3"], ["pmol/L": 1 / 1.536]),
        Analyte("t4_total", "T4, Total", "3026-2", "ug/dL", ["thyroxine (t4)", "total t4"]),
        Analyte("testosterone_total", "Testosterone, Total", "2986-8", "ng/dL", ["testosterone", "testosterone, serum"], ["nmol/L": 28.84]),
        Analyte("testosterone_free", "Free Testosterone", "2991-8", "pg/mL", ["testosterone, free"]),
        Analyte("shbg", "SHBG", "13967-5", "nmol/L", ["sex hormone binding globulin", "sex horm binding glob"]),
        Analyte("estradiol", "Estradiol", "2243-4", "pg/mL", ["estradiol, serum"], ["pmol/L": 1 / 3.671]),
        Analyte("dhea_s", "DHEA-Sulfate", "2191-5", "ug/dL", ["dhea sulfate", "dhea-s"]),
        Analyte("cortisol", "Cortisol", "2143-6", "ug/dL", ["cortisol, am", "cortisol, serum"], ["nmol/L": 1 / 27.59]),
        Analyte("psa", "PSA, Total", "2857-1", "ng/mL", ["psa", "prostate specific ag"]),
    ]

    static let micronutrients: [Analyte] = [
        Analyte("vitamin_d_25oh", "Vitamin D, 25-Hydroxy", "1989-3", "ng/mL",
                ["vitamin d, 25-oh, total", "vitamin d 25-oh", "25-hydroxyvitamin d", "25-oh vitamin d", "vitamin d"], ["nmol/L": 1 / 2.496]),
        Analyte("vitamin_b12", "Vitamin B12", "2132-9", "pg/mL", ["b12", "cobalamin"], ["pmol/L": 1.355]),
        Analyte("folate", "Folate", "2284-8", "ng/mL", ["folate, serum", "folic acid"], ["nmol/L": 1 / 2.266]),
        Analyte("ferritin", "Ferritin", "2276-4", "ng/mL", ["ferritin, serum"], ["ug/L": 1]),
        Analyte("iron", "Iron", "2498-4", "ug/dL", ["iron, total", "serum iron"], ["umol/L": 5.585]),
        Analyte("tibc", "TIBC", "2500-7", "ug/dL", ["iron bind.cap.(tibc)", "total iron binding capacity"], ["umol/L": 5.585]),
        Analyte("transferrin_sat", "Iron Saturation", "2502-3", "%", ["transferrin saturation", "% saturation"]),
        Analyte("transferrin", "Transferrin", "3034-6", "mg/dL", [], ["g/L": 100]),
    ]

    static let other: [Analyte] = [
        Analyte("hscrp", "hs-CRP", "30522-7", "mg/L", ["c-reactive protein, cardiac", "crp, high sensitivity", "hs crp",
            "high sensitivity crp"], ["mg/dL": 10]),
        Analyte("crp", "C-Reactive Protein", "1988-5", "mg/L", ["crp"], ["mg/dL": 10]),
        Analyte("homocysteine", "Homocysteine", "13965-9", "umol/L", []),
        Analyte("ldh", "LDH", "2532-0", "U/L", ["lactate dehydrogenase"]),
        Analyte("ck", "Creatine Kinase", "2157-6", "U/L", ["ck, total", "ck"]),
    ]

    /// (alias, analyte) sorted longest alias first, so "hemoglobin a1c" wins over "hemoglobin".
    static let aliasIndex: [(alias: String, analyte: Analyte)] = all.flatMap { a in a.aliases.map { ($0, a) } }
        .sorted { $0.alias.count != $1.alias.count ? $0.alias.count > $1.alias.count : $0.alias < $1.alias }

    public static func analyte(key: String) -> Analyte? { all.first { $0.key == key } }

    /// Longest alias that starts `line` (case-insensitive) and ends at a word boundary. Returns the analyte and alias length.
    public static func match(lineStart line: String) -> (analyte: Analyte, length: Int)? {
        let lower = line.lowercased()
        for (alias, analyte) in aliasIndex where lower.hasPrefix(alias) {
            let rest = lower.dropFirst(alias.count)
            if let next = rest.first, next.isLetter || next.isNumber { continue }
            return (analyte, alias.count)
        }
        return nil
    }
}
