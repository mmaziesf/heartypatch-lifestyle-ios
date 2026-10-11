package api

import (
	"encoding/json"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Insight is one hpl.cloud_insights.v1 item. Evidence entries are dotted paths into the payload that was sent.
type Insight struct {
	Kind     string   `json:"kind"`
	Title    string   `json:"title"`
	Body     string   `json:"body"`
	Evidence []string `json:"evidence"`
}

// Insights is hpl.cloud_insights.v1.
type Insights struct {
	Schema    string    `json:"schema"`
	RequestID string    `json:"request_id"`
	Insights  []Insight `json:"insights"`
}

const MaxInsights = 5

// CheckInsights applies the response schema plus the rule the client enforces in OutputGuard: every evidence path
// must resolve in the payload that was sent. Insights that fail are dropped (the server never returns something the
// client would have to hide); the envelope itself must be right.
func CheckInsights(out Insights, sent []byte) (Insights, error) {
	if out.Schema != InsightsSchema || !requestIDRe.MatchString(out.RequestID) {
		return Insights{}, invalid("insights envelope")
	}
	var doc any
	if err := json.Unmarshal(sent, &doc); err != nil {
		return Insights{}, invalid("sent payload")
	}
	kept := make([]Insight, 0, MaxInsights)
	for _, in := range out.Insights {
		if len(kept) == MaxInsights {
			break
		}
		if insightOK(in, doc) {
			kept = append(kept, in)
		}
	}
	out.Insights = kept
	return out, nil
}

func insightOK(in Insight, doc any) bool {
	if in.Kind != "observation" && in.Kind != "nudge" {
		return false
	}
	if n := utf8.RuneCountInString(in.Title); n < 1 || n > 80 {
		return false
	}
	if n := utf8.RuneCountInString(in.Body); n < 1 || n > 400 {
		return false
	}
	if len(in.Evidence) < 1 || len(in.Evidence) > 4 {
		return false
	}
	for _, e := range in.Evidence {
		if !evidenceRe.MatchString(e) || !resolves(doc, e) {
			return false
		}
	}
	return true
}

var evidenceRe = mustRe(`^(weeks|daily|labs|profile)(\.[A-Za-z0-9_]+)+$`)

// resolves walks a dotted path ("weeks.0.metrics.steps.median") through decoded JSON.
func resolves(doc any, path string) bool {
	cur := doc
	for _, part := range strings.Split(path, ".") {
		switch v := cur.(type) {
		case map[string]any:
			next, ok := v[part]
			if !ok {
				return false
			}
			cur = next
		case []any:
			i, err := strconv.Atoi(part)
			if err != nil || i < 0 || i >= len(v) {
				return false
			}
			cur = v[i]
		default:
			return false
		}
	}
	return true
}
