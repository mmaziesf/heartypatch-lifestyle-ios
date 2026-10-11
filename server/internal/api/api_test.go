package api

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func repo(t testing.TB, rel string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", rel))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// golden is the fixture as the client sends it: compact JSON (the fixture file is pretty-printed for review).
func golden(t testing.TB) []byte {
	var buf bytes.Buffer
	if err := json.Compact(&buf, repo(t, "Fixtures/cloud/payload-28d.synthetic.json")); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestGoldenPayloadDecodes(t *testing.T) {
	p, err := Decode(golden(t))
	if err != nil {
		t.Fatal(err)
	}
	if p.ID() != "00000000-0000-4000-8000-000000000001" || len(p.Daily) != 28 {
		t.Fatalf("unexpected decode: %s %d", p.ID(), len(p.Daily))
	}
}

// Server analyzer == iOS DemoCloudAnalyzer on the golden fixture (both produce Fixtures/cloud/insights-28d).
func TestRulesAnalyzerMatchesIOSGolden(t *testing.T) {
	body := golden(t)
	p, err := Decode(body)
	if err != nil {
		t.Fatal(err)
	}
	out, err := RulesAnalyzer{}.Analyze(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	out, err = CheckInsights(out, body)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := json.Marshal(out)
	var a, b any
	_ = json.Unmarshal(got, &a)
	_ = json.Unmarshal(repo(t, "Fixtures/cloud/insights-28d.synthetic.json"), &b)
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("server insights differ from iOS golden:\n%s", got)
	}
}

func TestInvalidFixturesRejected(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join("..", "..", "..", "Fixtures", "invalid", "cloud-payload-*.json"))
	if len(files) == 0 {
		t.Fatal("no invalid fixtures found")
	}
	for _, f := range files {
		b, _ := os.ReadFile(f)
		if _, err := Decode(b); err == nil {
			t.Errorf("%s: accepted", filepath.Base(f))
		}
	}
}

// mutate decodes the golden payload, applies f, and re-encodes it.
func mutate(t *testing.T, f func(m map[string]any)) []byte {
	var m map[string]any
	if err := json.Unmarshal(golden(t), &m); err != nil {
		t.Fatal(err)
	}
	f(m)
	b, _ := json.Marshal(m)
	return b
}

func day0(m map[string]any) map[string]any { return m["daily"].([]any)[0].(map[string]any) }

func TestRejections(t *testing.T) {
	g := string(golden(t))
	cases := map[string][]byte{
		"name field":         mutate(t, func(m map[string]any) { m["name"] = "Arash" }),
		"calendar date":      mutate(t, func(m map[string]any) { day0(m)["date"] = "2026-10-10" }),
		"food name":          mutate(t, func(m map[string]any) { day0(m)["meals"].([]any)[0].(map[string]any)["name"] = "pho" }),
		"free-text tag":      mutate(t, func(m map[string]any) { day0(m)["meals"].([]any)[0].(map[string]any)["tags"] = []any{"pho at Joe's"} }),
		"duplicate tag":      mutate(t, func(m map[string]any) { day0(m)["meals"].([]any)[0].(map[string]any)["tags"] = []any{"late", "late"} }),
		"bad label":          mutate(t, func(m map[string]any) { day0(m)["meals"].([]any)[0].(map[string]any)["label"] = "brunch" }),
		"minute time":        mutate(t, func(m map[string]any) { day0(m)["bed_local"] = "23:17" }),
		"steps out of range": mutate(t, func(m map[string]any) { day0(m)["steps"] = 99999 }),
		"fractional steps":   mutate(t, func(m map[string]any) { day0(m)["steps"] = 1000.5 }),
		"day out of window":  mutate(t, func(m map[string]any) { day0(m)["day"] = -40 }),
		"workout not x5": mutate(t, func(m map[string]any) {
			day0(m)["workouts"] = []any{map[string]any{"type": "running", "duration_min": 33}}
		}),
		"workout free type": mutate(t, func(m map[string]any) {
			day0(m)["workouts"] = []any{map[string]any{"type": "run w/ Sam", "duration_min": 30}}
		}),
		"missing meals": mutate(t, func(m map[string]any) { delete(day0(m), "meals") }),
		"rare lab": mutate(t, func(m map[string]any) {
			m["labs"] = []any{map[string]any{"analyte": "psa", "value": 1.0, "unit": "ng/mL", "age_bucket": "0-30"}}
		}),
		"lab name": mutate(t, func(m map[string]any) {
			m["labs"] = []any{map[string]any{"analyte": "ldl", "value": 100.0, "unit": "mg/dL", "age_bucket": "0-30", "lab": "Quest"}}
		}),
		"exact age":      mutate(t, func(m map[string]any) { m["profile"] = map[string]any{"age_band": "37"} }),
		"uppercase uuid": mutate(t, func(m map[string]any) { m["request_id"] = "00000000-0000-4000-8000-00000000000A" }),
		"few days":       mutate(t, func(m map[string]any) { m["days_with_data"] = 7 }),
		"window 30":      mutate(t, func(m map[string]any) { m["window_days"] = 30 }),
		"wrong schema":   mutate(t, func(m map[string]any) { m["schema"] = "hpl.cloud_payload.v2" }),
		"unknown metric": mutate(t, func(m map[string]any) {
			m["weeks"].([]any)[0].(map[string]any)["metrics"].(map[string]any)["weight_kg"] = map[string]any{"median": 80, "p10": 79, "p90": 81}
		}),
		"null value":       mutate(t, func(m map[string]any) { day0(m)["steps"] = nil }),
		"duplicate key":    []byte(strings.Replace(g, `"provenance"`, `"schema":"hpl.cloud_payload.v1","provenance"`, 1)),
		"case-variant key": []byte(strings.Replace(g, `"provenance"`, `"Request_ID":"x","provenance"`, 1)),
		"trailing data":    []byte(g + ` {"name":"x"}`),
		"array top level":  []byte(`[` + g + `]`),
		"empty":            []byte(``),
		"too large":        []byte(g + strings.Repeat(" ", MaxPayloadBytes)),
	}
	for name, b := range cases {
		if _, err := Decode(b); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestErrorsNeverEchoValues(t *testing.T) {
	canary := "CANARY-7f3e"
	b := mutate(t, func(m map[string]any) { day0(m)["meals"].([]any)[0].(map[string]any)["label"] = canary })
	_, err := Decode(b)
	if err == nil || strings.Contains(err.Error(), canary) {
		t.Fatalf("error leaks value or is nil: %v", err)
	}
}

func TestCheckInsightsDropsUnresolvableEvidence(t *testing.T) {
	body := golden(t)
	in := Insights{Schema: InsightsSchema, RequestID: "00000000-0000-4000-8000-000000000001", Insights: []Insight{
		{Kind: "observation", Title: "ok", Body: "ok", Evidence: []string{"daily.0.steps"}},
		{Kind: "observation", Title: "x", Body: "x", Evidence: []string{"daily.99.steps"}},
		{Kind: "diagnosis", Title: "x", Body: "x", Evidence: []string{"daily.0.steps"}},
		{Kind: "nudge", Title: strings.Repeat("t", 81), Body: "x", Evidence: []string{"daily.0.steps"}},
		{Kind: "nudge", Title: "x", Body: "x", Evidence: nil},
		{Kind: "nudge", Title: "x", Body: "x", Evidence: []string{"name"}},
	}}
	out, err := CheckInsights(in, body)
	if err != nil || len(out.Insights) != 1 {
		t.Fatalf("kept %d, err %v", len(out.Insights), err)
	}
}

func FuzzDecode(f *testing.F) {
	f.Add(golden(f))
	f.Add([]byte(`{"schema":"hpl.cloud_payload.v1"}`))
	f.Fuzz(func(t *testing.T, b []byte) {
		p, err := Decode(b)
		if err == nil {
			if _, err := (RulesAnalyzer{}).Analyze(context.Background(), p); err != nil {
				t.Fatal(err)
			}
		}
	})
}
