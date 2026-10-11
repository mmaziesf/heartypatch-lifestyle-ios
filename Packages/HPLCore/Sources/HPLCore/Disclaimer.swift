/// Disclaimer copy v1 (architecture §13). Shown in onboarding (must acknowledge), Settings, and recommendation detail.
public enum Disclaimer {
    public static let version = "disclaimer-v1"
    public static let title = "Not medical advice"
    public static let text = """
    HeartyPatch Lifestyle provides general wellness information and self-experiment ideas based on data you \
    choose to share with it. It is not a medical device and does not diagnose, treat, cure, or prevent any \
    disease or provide medical advice. Lab values are shown as printed on your report; we do not interpret them. \
    Talk to a qualified clinician about any health concern or before changing medications, diet, or exercise in \
    significant ways. If you think you may have a medical emergency, call your local emergency number.
    """
    public static let footer = "General wellness information, not medical advice."
    public static let syntheticDataBanner = "EXAMPLE DATA: not yours. Connect Apple Health to see your own."
}
