import Foundation
import Testing
@testable import ZettyCore

@Test func accountRunningRequestRoundTripsOverTheWire() throws {
    let request = ControlRequest.accountRunning(
        surface: "5F0C2A1E-0000-4000-8000-000000000001", account: "personal")
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)
    #expect(decoded == request)
}

@Test func accountRunningRequestUsesItsWireCommandName() throws {
    let request = ControlRequest.accountRunning(surface: "abc", account: "personal")
    let data = try JSONEncoder().encode(request)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["command"] as? String == "account-running")
}
