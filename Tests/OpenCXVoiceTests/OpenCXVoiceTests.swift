import XCTest
import OpenCXVoice

final class OpenCXVoiceTests: XCTestCase {
    @MainActor func testMuteAndUnmuteRejectWithoutAnActiveCall() async throws {
        let voice = try OpenCXVoice { _ in
            XCTFail("Mute must not request call credentials")
            throw VoiceError.invalidCredentials
        }
        for muted in [true, false] {
            do {
                try await voice.setMuted(muted)
                XCTFail("Mute must reject when no call is active")
            } catch VoiceError.notStarted {
                XCTAssertEqual(voice.state, .idle)
            }
        }
    }
}
