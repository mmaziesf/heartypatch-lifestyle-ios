// Package api holds the wire contract shared with the iOS client: hpl.cloud_payload.v1 in, hpl.cloud_insights.v1 out
// (Spec/*.schema.json in the repo root). Decoding is strict: unknown keys, duplicate keys, nulls, trailing data and
// anything the JSON Schema rejects are refused. Nothing here logs or retains a payload.
package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
)

// Limits shared with the client (HPLCloud.EgressGate).
const (
	MaxPayloadBytes  = 16_384
	MaxResponseBytes = 65_536
	PayloadSchema    = "hpl.cloud_payload.v1"
	InsightsSchema   = "hpl.cloud_insights.v1"
	maxDepth         = 8
)

// ErrInvalid wraps every rejection. Messages name fields and rules only, never values, so they are safe to count but
// are still not logged by the server.
var ErrInvalid = errors.New("invalid payload")

func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, a...))
}

var (
	requestIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	halfHourRe  = regexp.MustCompile(`^([01][0-9]|2[0-3]):(00|30)$`)
	ageBandRe   = regexp.MustCompile(`^((1[5-9]|[2-7][0-9])-(1[5-9]|[2-7][0-9])|80\+)$`)
)

// ValidRequestID reports whether s has the lowercase UUID shape the client sends.
func ValidRequestID(s string) bool { return requestIDRe.MatchString(s) }

type Stat struct {
	Median *float64 `json:"median"`
	P10    *float64 `json:"p10"`
	P90    *float64 `json:"p90"`
}

type Week struct {
	Week         *int             `json:"week"`
	DaysWithData *int             `json:"days_with_data"`
	Metrics      map[string]*Stat `json:"metrics"`
}

type Meal struct {
	TLocal *string  `json:"t_local"`
	Label  *string  `json:"label"`
	Tags   []string `json:"tags"`
}

type Workout struct {
	Type        *string `json:"type"`
	DurationMin *int    `json:"duration_min"`
}

type Day struct {
	Day           *int      `json:"day"`
	Dow           *string   `json:"dow"`
	SleepTotalMin *int      `json:"sleep_total_min,omitempty"`
	RestingHR     *int      `json:"resting_hr,omitempty"`
	HRVMs         *int      `json:"hrv_ms,omitempty"`
	Steps         *int      `json:"steps,omitempty"`
	ExerciseMin   *int      `json:"exercise_min,omitempty"`
	BedLocal      *string   `json:"bed_local,omitempty"`
	WakeLocal     *string   `json:"wake_local,omitempty"`
	Meals         []Meal    `json:"meals"`
	Workouts      []Workout `json:"workouts"`
}

type Lab struct {
	Analyte   *string  `json:"analyte"`
	Value     *float64 `json:"value"`
	Unit      *string  `json:"unit"`
	AgeBucket *string  `json:"age_bucket"`
}

type Profile struct {
	AgeBand      *string `json:"age_band,omitempty"`
	SexForRanges *string `json:"sex_for_ranges,omitempty"`
}

// Payload is hpl.cloud_payload.v1. Pointers/nil slices let Validate tell "missing" from "zero".
type Payload struct {
	Schema       *string  `json:"schema"`
	RequestID    *string  `json:"request_id"`
	Provenance   *string  `json:"provenance"`
	WindowDays   *int     `json:"window_days"`
	DaysWithData *int     `json:"days_with_data"`
	Profile      *Profile `json:"profile,omitempty"`
	Weeks        []Week   `json:"weeks"`
	Daily        []Day    `json:"daily"`
	Labs         []Lab    `json:"labs"`
}

// ID returns the request id (only valid after a successful Decode).
func (p *Payload) ID() string { return *p.RequestID }

var (
	metricKeys  = set("sleep_total_min", "sleep_deep_min", "resting_hr", "hrv_ms", "steps", "exercise_min", "active_kcal")
	dows        = set("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
	mealLabels  = set("breakfast", "lunch", "dinner", "snack", "drink", "meal")
	mealTags    = set("late", "alcohol", "high-sugar", "high-protein", "high-fiber", "home-cooked", "restaurant", "caffeine", "processed")
	workoutKind = set("running", "cycling", "strength", "walking", "yoga", "swimming", "hiking", "hiit", "other")
	analytes    = set("ldl", "hdl", "cholesterol_total", "non_hdl", "triglycerides", "glucose", "hba1c")
	labUnits    = set("mg/dL", "%")
	ageBuckets  = set("0-30", "31-90", "91-180", "180+")
	provenances = set("device", "synthetic_fixture")
	// Every key that may appear anywhere in the payload, exact spelling.
	wireKeys = set("schema", "request_id", "provenance", "window_days", "days_with_data", "profile", "age_band", "sex_for_ranges",
		"weeks", "week", "metrics", "median", "p10", "p90", "sleep_total_min", "sleep_deep_min", "resting_hr", "hrv_ms", "steps",
		"exercise_min", "active_kcal", "daily", "day", "dow", "bed_local", "wake_local", "meals", "t_local", "label", "tags",
		"workouts", "type", "duration_min", "labs", "analyte", "value", "unit", "age_bucket")
)

func set(xs ...string) map[string]bool {
	m := make(map[string]bool, len(xs))
	for _, x := range xs {
		m[x] = true
	}
	return m
}

// Decode parses and validates body as hpl.cloud_payload.v1. It never echoes values in its errors.
func Decode(body []byte) (*Payload, error) {
	if len(body) > MaxPayloadBytes {
		return nil, invalid("body larger than %d bytes", MaxPayloadBytes)
	}
	if err := checkStructure(body); err != nil {
		return nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	var p Payload
	if err := dec.Decode(&p); err != nil {
		return nil, invalid("does not match schema types or has unknown keys")
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, invalid("trailing data after the object")
	}
	if err := p.Validate(); err != nil {
		return nil, err
	}
	return &p, nil
}

// checkStructure rejects duplicate object keys (Go's decoder silently keeps the last one), JSON null anywhere, a
// non-object top level and nesting deeper than the schema allows.
func checkStructure(body []byte) error {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var stack []*frame
	first := true
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return invalid("not valid JSON")
		}
		if first {
			if d, ok := tok.(json.Delim); !ok || d != '{' {
				return invalid("top level must be an object")
			}
			first = false
		}
		var top *frame
		if len(stack) > 0 {
			top = stack[len(stack)-1]
		}
		if top != nil && top.obj && top.expectKey {
			if d, ok := tok.(json.Delim); ok && d == '}' {
				stack = stack[:len(stack)-1]
				markValueDone(stack)
				continue
			}
			k, _ := tok.(string)
			if !wireKeys[k] {
				// encoding/json matches keys case-insensitively; only the exact lowercase spellings are accepted.
				return invalid("unknown key")
			}
			if top.seen[k] {
				return invalid("duplicate key")
			}
			top.seen[k] = true
			top.expectKey = false
			continue
		}
		switch t := tok.(type) {
		case json.Delim:
			switch t {
			case '{':
				stack = append(stack, &frame{obj: true, seen: map[string]bool{}, expectKey: true})
			case '[':
				stack = append(stack, &frame{})
			case ']':
				stack = stack[:len(stack)-1]
				markValueDone(stack)
			}
			if len(stack) > maxDepth {
				return invalid("nested too deeply")
			}
		case nil:
			return invalid("null is not allowed")
		default:
			markValueDone(stack)
		}
	}
	if first {
		return invalid("empty body")
	}
	return nil
}

func markValueDone(stack []*frame) {
	if len(stack) > 0 && stack[len(stack)-1].obj {
		stack[len(stack)-1].expectKey = true
	}
}

type frame struct {
	obj       bool
	seen      map[string]bool
	expectKey bool
}

// Validate mirrors Spec/hpl.cloud_payload.v1.schema.json rule for rule.
func (p *Payload) Validate() error {
	switch {
	case p.Schema == nil || *p.Schema != PayloadSchema:
		return invalid("schema")
	case p.RequestID == nil || !requestIDRe.MatchString(*p.RequestID):
		return invalid("request_id")
	case p.Provenance == nil || !provenances[*p.Provenance]:
		return invalid("provenance")
	case p.WindowDays == nil || (*p.WindowDays != 28 && *p.WindowDays != 56):
		return invalid("window_days")
	case p.DaysWithData == nil || *p.DaysWithData < 14 || *p.DaysWithData > 56:
		return invalid("days_with_data")
	case p.Weeks == nil || len(p.Weeks) > 8:
		return invalid("weeks")
	case p.Daily == nil || len(p.Daily) > 28:
		return invalid("daily")
	case p.Labs == nil:
		return invalid("labs")
	}
	if pr := p.Profile; pr != nil {
		if pr.AgeBand != nil && !ageBandRe.MatchString(*pr.AgeBand) {
			return invalid("profile.age_band")
		}
		if pr.SexForRanges != nil && *pr.SexForRanges != "M" && *pr.SexForRanges != "F" {
			return invalid("profile.sex_for_ranges")
		}
	}
	for i, w := range p.Weeks {
		if !intIn(w.Week, -7, 0) || !intIn(w.DaysWithData, 0, 7) || w.Metrics == nil {
			return invalid("weeks.%d", i)
		}
		for k, s := range w.Metrics {
			if !metricKeys[k] || s == nil || s.Median == nil || s.P10 == nil || s.P90 == nil {
				return invalid("weeks.%d.metrics", i)
			}
		}
	}
	for i, d := range p.Daily {
		if err := d.validate(); err != nil {
			return invalid("daily.%d.%s", i, err.Error())
		}
	}
	for i, l := range p.Labs {
		if l.Analyte == nil || !analytes[*l.Analyte] || l.Value == nil || *l.Value < 0 ||
			l.Unit == nil || !labUnits[*l.Unit] || l.AgeBucket == nil || !ageBuckets[*l.AgeBucket] {
			return invalid("labs.%d", i)
		}
	}
	return nil
}

func (d Day) validate() error {
	switch {
	case !intIn(d.Day, -27, 0):
		return errors.New("day")
	case d.Dow == nil || !dows[*d.Dow]:
		return errors.New("dow")
	case !optIntIn(d.SleepTotalMin, 180, 720):
		return errors.New("sleep_total_min")
	case !optIntIn(d.RestingHR, 38, 100):
		return errors.New("resting_hr")
	case !optIntIn(d.HRVMs, 8, 160):
		return errors.New("hrv_ms")
	case !optIntIn(d.Steps, 0, 35_000):
		return errors.New("steps")
	case !optIntIn(d.ExerciseMin, 0, 240):
		return errors.New("exercise_min")
	case d.BedLocal != nil && !halfHourRe.MatchString(*d.BedLocal):
		return errors.New("bed_local")
	case d.WakeLocal != nil && !halfHourRe.MatchString(*d.WakeLocal):
		return errors.New("wake_local")
	case d.Meals == nil:
		return errors.New("meals")
	case d.Workouts == nil:
		return errors.New("workouts")
	}
	for j, m := range d.Meals {
		if m.TLocal == nil || !halfHourRe.MatchString(*m.TLocal) || m.Label == nil || !mealLabels[*m.Label] || m.Tags == nil {
			return fmt.Errorf("meals.%d", j)
		}
		seen := map[string]bool{}
		for _, t := range m.Tags {
			if !mealTags[t] || seen[t] {
				return fmt.Errorf("meals.%d.tags", j)
			}
			seen[t] = true
		}
	}
	for j, w := range d.Workouts {
		if w.Type == nil || !workoutKind[*w.Type] || !intIn(w.DurationMin, 0, 300) || *w.DurationMin%5 != 0 {
			return fmt.Errorf("workouts.%d", j)
		}
	}
	return nil
}

func intIn(v *int, lo, hi int) bool    { return v != nil && *v >= lo && *v <= hi }
func optIntIn(v *int, lo, hi int) bool { return v == nil || (*v >= lo && *v <= hi) }

func mustRe(s string) *regexp.Regexp { return regexp.MustCompile(s) }
