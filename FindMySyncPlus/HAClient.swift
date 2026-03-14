import Foundation

struct HAPayload: Codable, Sendable {
    let dev_id: String
    let host_name: String
    let mac: String
    let gps: [Double]
    let gps_accuracy: Double
    let battery: Int?
}

private actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = max(1, value)
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            value += 1
        }
    }
}

enum AuthError: LocalizedError {
    case invalidURL(String)
    case requestFailed(Int)
    case authRejected(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let reason):
            return "Auth Test Failed: \(reason)"
        case .requestFailed(let status):
            return "Auth Test Failed: Server responded with HTTP status \(status)."
        case .authRejected(let status):
            return "Auth Test Failed: Authentication was rejected (HTTP \(status)). Check your Authorization Header."
        case .networkError(let error):
            return "Auth Test Failed: \(error.localizedDescription)"
        }
    }
}

enum PostResult: Sendable {
    case success(id: String, status: Int)
    case authRejected(id: String, status: Int)   // 401/403
    case transient(id: String, reason: String)   // network/other HTTP
}

struct PostSummary: Sendable {
    let successCount: Int
    let authRejectedCount: Int
    let transientCount: Int
}

enum HAClient {

    @MainActor static func testEndpointAuthentication(settings: SettingsStore) async throws {
        guard
            let fullURL = URL(string: settings.endpointURL),
            let scheme = fullURL.scheme, scheme.hasPrefix("http"),
            let host = fullURL.host
        else {
            throw AuthError.invalidURL("Invalid URL format")
        }

        guard fullURL.path.range(of: #"^/api(?:/|$)"#, options: .regularExpression) != nil else {
            throw AuthError.invalidURL("URL path must start with /api")
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = fullURL.port
        components.path = "/api/"

        guard let testURL = components.url else {
            throw AuthError.invalidURL("Could not construct base /api/ URL")
        }

        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmed = settings.endpointAuth.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            req.setValue(trimmed, forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 12

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AuthError.requestFailed(-1)
            }

            let status = http.statusCode
            if (200...299).contains(status) {
                return // Success!
            } else if status == 401 || status == 403 {
                throw AuthError.authRejected(status)
            } else {
                throw AuthError.requestFailed(status)
            }
        } catch {
            if let authError = error as? AuthError {
                throw authError // Re-throw our specific error
            }
            throw AuthError.networkError(error) // Wrap any other error
        }
    }

    @MainActor static func post(_ devices: [DevicePoint],
                                 aliasByUUID: [String: String],
                                 settings: SettingsStore,
                                 logger: LogStore,
                                 dryRun: Bool = false) async -> PostSummary {

        if dryRun {
            for d in devices {
                let uuid = d.id.normalized()
                if let alias = aliasByUUID[uuid] {
                    let dev = DeviceAlias.entityID(for: alias)
                    let mac = macFromAlias(alias)
                    logger.info("[DRY] Would post dev_id=\(dev), host_name=\(dev), mac=\(mac)")
                } else {
                    // Defensive (toPost should already be filtered)
                    logger.warn("[DRY] Skipping \(uuid): no alias mapping found")
                }
            }
            return PostSummary(successCount: 0, authRejectedCount: 0, transientCount: 0)
        }

        let endpointURL = settings.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpointURL), !endpointURL.isEmpty else {
            logger.error("Invalid endpoint URL")
            return PostSummary(successCount: 0, authRejectedCount: 0, transientCount: 0)
        }
        let authHeader = settings.endpointAuth.trimmingCharacters(in: .whitespacesAndNewlines)

        var successCount = 0
        var authRejectedCount = 0
        var transientCount = 0

        let semaphore = AsyncSemaphore(value: 8)

        await withTaskGroup(of: PostResult.self) { group in
            for d in devices {
                group.addTask { @Sendable in
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    let result: PostResult

                    // Resolve alias (toPost should ensure this exists)
                    let uuid = d.id.normalized()
                    guard let alias = aliasByUUID[uuid] else {
                        result = .transient(id: d.id, reason: "No alias for UUID \(uuid)")
                        return result
                    }

                    let dev = DeviceAlias.entityID(for: alias)
                    let mac = macFromAlias(alias)

                    // Build payload per HA behavior using Codable
                    let payload = HAPayload(
                        dev_id: dev,
                        host_name: dev,
                        mac: mac,
                        gps: [d.latitude, d.longitude],
                        gps_accuracy: d.accuracy,
                        battery: d.battery.map { Int(($0 * 100).rounded()) }
                    )

                    // Encode once per task (JSONEncoder isn't guaranteed thread-safe)
                    guard let body = try? JSONEncoder().encode(payload) else {
                        result = .transient(id: d.id, reason: "Failed to encode JSON payload.")
                        return result
                    }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.httpBody = body
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !authHeader.isEmpty {
                        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
                    }

                    do {
                        let (_, response) = try await URLSession.shared.data(for: req)
                        if let http = response as? HTTPURLResponse {
                            let status = http.statusCode
                            if status == 401 || status == 403 {
                                result = .authRejected(id: d.id, status: status)
                            } else if (200...299).contains(status) {
                                result = .success(id: dev, status: status)
                            } else {
                                result = .transient(id: dev, reason: "HTTP \(status)")
                            }
                        } else {
                            result = .transient(id: dev, reason: "Non-HTTP response")
                        }
                    } catch {
                        result = .transient(id: dev, reason: "POST request failed with network error: \(error.localizedDescription)")
                    }

                    return result
                }
            }

            for await result in group {
                switch result {
                case .success(let id, let status):
                    successCount += 1
                    logger.info("[\(id)] Data sent: HTTP \(status)")
                case .authRejected(let id, let status):
                    authRejectedCount += 1
                    logger.error("[\(id)] Authentication failed (HTTP \(status)). Check your Authorization header.")
                case .transient(let id, let reason):
                    transientCount += 1
                    logger.warn("[\(id)] POST failed: \(reason)")
                }
            }
        }

        return PostSummary(successCount: successCount,
                           authRejectedCount: authRejectedCount,
                           transientCount: transientCount)
    }
}
