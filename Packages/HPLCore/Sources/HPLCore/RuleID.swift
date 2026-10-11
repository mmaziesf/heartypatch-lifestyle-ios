/// Stable ids of deterministic rules (architecture §5.4 step 3). Engines key templates and prompts on these.
public enum RuleID {
    public static let sleepShort = "SLEEP_SHORT_VS_BASELINE"
    public static let deepSleepLow = "DEEP_SLEEP_LOW_VS_BASELINE"
    public static let bedtimeLate = "BEDTIME_AFTER_MIDNIGHT"
    public static let hrvLow = "HRV_BELOW_P10"
    public static let restingHRHigh = "RESTING_HR_ABOVE_BASELINE"
    public static let stepsLow = "STEPS_LOW_VS_BASELINE"
    public static let stepsHigh = "STEPS_HIGH_VS_BASELINE"
    public static let noExercise = "NO_EXERCISE_MINUTES"
    public static let hardWorkout = "HARD_WORKOUT"
    public static let lateMealAlcohol = "LATE_MEAL_ALCOHOL"
    public static let experimentActive = "EXPERIMENT_IN_PROGRESS"
    public static let lowCompleteness = "LOW_DATA_COMPLETENESS"
    /// Fixed clinician-prompt copy only; never written by an LLM (§6.6 red-flag passthrough).
    public static let clinicianLabCritical = "CLINICIAN_PROMPT_LAB_CRITICAL_FLAG"

    public static func isClinicianPrompt(_ id: String) -> Bool { id.hasPrefix("CLINICIAN_PROMPT_") }
}
