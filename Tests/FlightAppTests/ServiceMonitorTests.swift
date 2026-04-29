import Foundation
import XCTest
@testable import FlightApp

final class ServiceMonitorTests: XCTestCase {
    func testParseArrayPayloadWithMetricsArray() throws {
        let output = """
        [
          {
            "name": "web",
            "status": "online",
            "health": "healthy",
            "metrics": [
              { "label": "uptime", "value": "2d 0h" },
              { "label": "restarts", "value": "0" }
            ]
          }
        ]
        """

        let services = try ServiceMonitor.parse(output)

        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services[0].name, "web")
        XCTAssertEqual(services[0].status, "online")
        XCTAssertEqual(services[0].health, .healthy)
        XCTAssertEqual(services[0].metrics, [
            ServiceMonitorMetric(label: "uptime", value: "2d 0h"),
            ServiceMonitorMetric(label: "restarts", value: "0"),
        ])
    }

    func testParseRootPayloadWithMetricsObject() throws {
        let output = """
        {
          "services": [
            {
              "name": "worker",
              "status": "degraded",
              "metrics": {
                "cpu": "0.0%",
                "restarts": 3
              }
            }
          ]
        }
        """

        let services = try ServiceMonitor.parse(output)

        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services[0].health, .warning)
        XCTAssertEqual(services[0].metrics.map(\.label), ["cpu", "restarts"])
        XCTAssertEqual(services[0].metrics.first { $0.label == "restarts" }?.value, "3")
    }

    func testParseInfersCriticalStatusAndAllowsLogPrefix() throws {
        let output = """
        collecting service state
        [{"name":"api","status":"failed"}]
        """

        let services = try ServiceMonitor.parse(output)

        XCTAssertEqual(services[0].name, "api")
        XCTAssertEqual(services[0].health, .critical)
    }
}
