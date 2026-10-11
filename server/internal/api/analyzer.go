package api

import (
	"context"
	"strconv"
)

// Analyzer turns a validated payload into insights. Implementations must be pure functions of the payload: no
// storage, no logging of inputs or outputs, no outbound calls that carry the payload to a third party.
type Analyzer interface {
	Analyze(ctx context.Context, p *Payload) (Insights, error)
}

// RulesAnalyzer is the deterministic multi-week analyzer. It is a line-for-line port of the iOS DemoCloudAnalyzer
// (Packages/HPLCloud/Sources/HPLCloud/CloudTransport.swift), so the server answers the golden fixture with the golden
// insights (tested). Every number it writes is copied from the payload, so the client's OutputGuard accepts it.
type RulesAnalyzer struct{}

func (RulesAnalyzer) Analyze(_ context.Context, p *Payload) (Insights, error) {
	out := make([]Insight, 0, MaxInsights)
	add := func(i *Insight) {
		if i != nil {
			out = append(out, *i)
		}
	}
	add(trend(p, "sleep_total_min", "Sleep across your weeks", "minutes", "sleep"))
	add(trend(p, "steps", "Steps across your weeks", "steps", "step count"))
	add(trend(p, "resting_hr", "Resting heart rate across your weeks", "bpm", "resting heart rate"))
	add(busiestDay(p))
	add(lateMeals(p))
	if len(out) > MaxInsights {
		out = out[:MaxInsights]
	}
	return Insights{Schema: InsightsSchema, RequestID: p.ID(), Insights: out}, nil
}

// num matches Swift's CloudPreview.num: whole numbers without a decimal point, others in shortest form.
func num(v float64) string {
	if v == float64(int64(v)) {
		return strconv.FormatInt(int64(v), 10)
	}
	return strconv.FormatFloat(v, 'f', -1, 64)
}

func trend(p *Payload, metric, title, unit, noun string) *Insight {
	first, last := -1, -1
	for i, w := range p.Weeks {
		if _, ok := w.Metrics[metric]; ok {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 || first == last {
		return nil
	}
	a, b := *p.Weeks[first].Metrics[metric].Median, *p.Weeks[last].Metrics[metric].Median
	direction := "held steady at"
	if a != b {
		if b > a {
			direction = "rose from " + num(a) + " to"
		} else {
			direction = "fell from " + num(a) + " to"
		}
	}
	return &Insight{
		Kind:  "observation",
		Title: title,
		Body:  "Your weekly median " + noun + " " + direction + " " + num(b) + " " + unit + " between the first and the most recent week.",
		Evidence: []string{
			"weeks." + strconv.Itoa(first) + ".metrics." + metric + ".median",
			"weeks." + strconv.Itoa(last) + ".metrics." + metric + ".median",
		},
	}
}

func busiestDay(p *Payload) *Insight {
	best := -1
	for i, d := range p.Daily {
		if d.Steps != nil && (best < 0 || *d.Steps > *p.Daily[best].Steps) { // ties keep the earliest row, as on iOS
			best = i
		}
	}
	if best < 0 {
		return nil
	}
	d := p.Daily[best]
	return &Insight{
		Kind:     "observation",
		Title:    "Your most active recent day",
		Body:     "Your highest step count in the recent rows was " + strconv.Itoa(*d.Steps) + " steps, on a " + *d.Dow + ".",
		Evidence: []string{"daily." + strconv.Itoa(best) + ".steps"},
	}
}

func lateMeals(p *Payload) *Insight {
	for i, d := range p.Daily {
		for j, m := range d.Meals {
			for _, t := range m.Tags {
				if t == "late" {
					return &Insight{
						Kind:     "nudge",
						Title:    "Late meals showed up",
						Body:     "Some recent evenings had late meals. Finishing dinner a little earlier is an easy thing to try for 14 days.",
						Evidence: []string{"daily." + strconv.Itoa(i) + ".meals." + strconv.Itoa(j) + ".tags"},
					}
				}
			}
		}
	}
	return nil
}
