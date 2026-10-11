import Testing
@testable import HPLHealth

@Test func metricFamiliesDeclared() { #expect(HealthSync.MetricFamily.allCases.count == 5) }
