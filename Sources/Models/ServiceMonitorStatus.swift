import Foundation

enum ServiceMonitorHealth: String, Codable, Equatable {
    case healthy
    case warning
    case critical
}

struct ServiceMonitorMetric: Identifiable, Codable, Equatable {
    let label: String
    let value: String

    var id: String { label }

    enum CodingKeys: String, CodingKey {
        case label, value
    }

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        value = try container.decode(MonitorValue.self, forKey: .value).description
    }
}

private struct MonitorValue: Decodable, CustomStringConvertible {
    let description: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            description = string
        } else if let int = try? container.decode(Int.self) {
            description = "\(int)"
        } else if let double = try? container.decode(Double.self) {
            description = "\(double)"
        } else if let bool = try? container.decode(Bool.self) {
            description = bool ? "true" : "false"
        } else {
            description = "-"
        }
    }
}

struct ServiceMonitorStatus: Identifiable, Equatable {
    let name: String
    let status: String
    let healthOverride: ServiceMonitorHealth?
    let metrics: [ServiceMonitorMetric]

    var id: String { name }

    var health: ServiceMonitorHealth {
        if let healthOverride { return healthOverride }

        switch status.lowercased() {
        case "ok", "online", "running", "healthy", "up", "ready":
            return .healthy
        case "error", "errored", "failed", "failure", "offline", "stopped", "down", "critical":
            return .critical
        default:
            return .warning
        }
    }

    var healthLabel: String {
        status.isEmpty ? health.rawValue : status
    }
}

enum ServiceMonitor {
    private struct ServicePayload: Decodable {
        let name: String
        let status: String?
        let health: ServiceMonitorHealth?
        let metrics: [ServiceMonitorMetric]

        enum CodingKeys: String, CodingKey {
            case name, status, health, metrics
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            health = try container.decodeIfPresent(ServiceMonitorHealth.self, forKey: .health)

            if let metricArray = try? container.decode([ServiceMonitorMetric].self, forKey: .metrics) {
                metrics = metricArray
            } else if let metricObject = try? container.decode([String: MonitorValue].self, forKey: .metrics) {
                metrics = metricObject
                    .map { ServiceMonitorMetric(label: $0.key, value: $0.value.description) }
                    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            } else {
                metrics = []
            }
        }
    }

    private struct RootPayload: Decodable {
        let services: [ServicePayload]
    }

    static func parse(_ output: String) throws -> [ServiceMonitorStatus] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = try decodePayload(from: trimmed)

        return payload
            .map {
                ServiceMonitorStatus(
                    name: $0.name,
                    status: $0.status ?? $0.health?.rawValue ?? "unknown",
                    healthOverride: $0.health,
                    metrics: $0.metrics
                )
            }
            .sorted { lhs, rhs in
                if healthRank(lhs.health) != healthRank(rhs.health) {
                    return healthRank(lhs.health) < healthRank(rhs.health)
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static func decodePayload(from output: String) throws -> [ServicePayload] {
        let decoder = JSONDecoder()
        if let data = output.data(using: .utf8) {
            if let services = try? decoder.decode([ServicePayload].self, from: data) {
                return services
            }
            if let root = try? decoder.decode(RootPayload.self, from: data) {
                return root.services
            }
        }

        if let lastJSONLine = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .last(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
            }),
           let data = lastJSONLine.data(using: .utf8) {
            if let services = try? decoder.decode([ServicePayload].self, from: data) {
                return services
            }
            if let root = try? decoder.decode(RootPayload.self, from: data) {
                return root.services
            }
        }

        throw DecodingError.dataCorrupted(.init(
            codingPath: [],
            debugDescription: "Monitor output must be JSON: an array of services or an object with a services array."
        ))
    }

    private static func healthRank(_ health: ServiceMonitorHealth) -> Int {
        switch health {
        case .critical: return 0
        case .warning: return 1
        case .healthy: return 2
        }
    }
}
