import Foundation
import Testing
@testable import VibeTunnel

@Suite("Ngrok Service Tests", .tags(.networking))
struct NgrokServiceTests {
    let testAuthToken = "test_auth_token_123"
    let testPort = 8888

    @Test
    @MainActor
    func singletonInstance() {
        let instance1 = NgrokService.shared
        let instance2 = NgrokService.shared
        #expect(instance1 === instance2)
    }

    @Test
    @MainActor
    func initialState() {
        let service = NgrokService.shared
        #expect(service.isActive == false)
        #expect(service.publicUrl == nil)
        #expect(service.tunnelStatus == nil)
    }

    @Test
    @MainActor
    func authTokenManagement() {
        let service = NgrokService.shared

        // Save original token
        let originalToken = service.authToken

        // Set test token
        service.authToken = self.testAuthToken
        #expect(service.authToken == self.testAuthToken)
        #expect(service.hasAuthToken == true)

        // Clear token
        service.authToken = nil
        #expect(service.authToken == nil)
        #expect(service.hasAuthToken == false)

        // Restore original token
        service.authToken = originalToken
    }

    @Test
    @MainActor
    func startWithoutAuthTokenFails() async throws {
        let service = NgrokService.shared

        // Save original token
        let originalToken = service.authToken

        // Clear token
        service.authToken = nil

        do {
            _ = try await service.start(port: self.testPort)
            Issue.record("Expected error to be thrown")
        } catch let error as NgrokError {
            #expect(error == .authTokenMissing)
        } catch {
            Issue.record("Expected NgrokError.authTokenMissing")
        }

        // Restore original token
        service.authToken = originalToken
    }

    @Test
    @MainActor
    func stopWhenNotRunning() async throws {
        let service = NgrokService.shared

        // Ensure not running
        if service.isActive {
            try await service.stop()
        }

        // Stop again should be safe
        try await service.stop()

        #expect(service.isActive == false)
        #expect(service.publicUrl == nil)
    }

    @Test
    @MainActor
    func isRunningCheck() async {
        let service = NgrokService.shared

        let running = await service.isRunning()
        #expect(running == service.isActive)
    }

    @Test
    @MainActor
    func getStatusWhenInactive() async {
        let service = NgrokService.shared

        // Ensure not running
        if service.isActive {
            try? await service.stop()
        }

        let status = await service.getStatus()
        #expect(status == nil)
    }

    @Test
    func ngrokerrorDescriptions() throws {
        let errors: [NgrokError] = [
            .notInstalled,
            .authTokenMissing,
            .tunnelCreationFailed("test error"),
            .invalidConfiguration,
            .networkError("connection failed"),
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
        }
    }

    @Test
    func ngrokerrorEquality() {
        #expect(NgrokError.notInstalled == NgrokError.notInstalled)
        #expect(NgrokError.authTokenMissing == NgrokError.authTokenMissing)
        #expect(NgrokError.tunnelCreationFailed("a") == NgrokError.tunnelCreationFailed("a"))
        #expect(NgrokError.tunnelCreationFailed("a") != NgrokError.tunnelCreationFailed("b"))
    }
}
