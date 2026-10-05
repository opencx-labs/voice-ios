import Foundation
import AVFoundation
internal import LiveKit

public struct VoiceCredentials: Codable, Sendable {
    public let callId: String
    public let sessionId: String
    public let controlToken: String
    public let expiresAt: String
}
public enum VoiceState: String, Sendable, Decodable {
    case idle, connecting, waiting, queued, connected, reconnecting, ended
}
public enum VoiceError: Error { case alreadyStarted, notStarted, microphoneDenied, invalidCredentials, requestFailed(Int), connectionTimeout, callFailed }
private struct AudioConnection: Decodable { let serverUrl: String; let participantToken: String }
private struct CallStatus: Decodable { let state: VoiceState }

/// All UI callbacks run on the main actor. Keep the instance alive for the duration of the call.
@MainActor
public final class OpenCXVoice: NSObject {
    public private(set) var state: VoiceState = .idle {
        didSet { onStateChanged?(state) }
    }
    public var onStateChanged: ((VoiceState) -> Void)?
    public var onError: ((VoiceError) -> Void)?
    public var sessionId: String? { active?.credentials?.sessionId ?? lastSessionId }
    private let getToken: @Sendable (UUID) async throws -> VoiceCredentials
    private let apiURL: URL
    private let session: URLSession
    private var lastSessionId: String?
    private var active: Call?

    private final class AudioDelegate: NSObject, RoomDelegate {
        let onConnectionState: @Sendable (Room, ConnectionState) -> Void
        init(_ onConnectionState: @escaping @Sendable (Room, ConnectionState) -> Void) {
            self.onConnectionState = onConnectionState
        }
        nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState,
                              from oldState: ConnectionState) {
            onConnectionState(room, state)
        }
    }
    private lazy var audioDelegate = AudioDelegate { [weak self] room, connectionState in
        Task { @MainActor [weak self] in
            guard let self, let call = self.active, call.room === room, !call.stopped else { return }
            if connectionState == .reconnecting { self.state = .reconnecting }
            if connectionState == .disconnected {
                do { try await self.stop(call) } catch { self.onError?(self.normalizeError(error)) }
            }
        }
    }
    private func normalizeError(_ error: Error) -> VoiceError { (error as? VoiceError) ?? .callFailed }
    private final class Call {
        let room = Room()
        var credentials: VoiceCredentials?
        var stopped = false
        var canceledByUser = false
        var polling: Task<Void, Never>?
        var waitingSince: Date? = Date()
    }
    public init(apiURL: String = "https://api.open.cx", session: URLSession = .shared,
                getToken: @escaping @Sendable (UUID) async throws -> VoiceCredentials) throws {
        guard let apiURL = URL(string: apiURL),
              apiURL.scheme == "https" || (apiURL.scheme == "http" && ["localhost", "127.0.0.1"].contains(apiURL.host ?? "")) else { throw VoiceError.invalidCredentials }
        self.apiURL = apiURL; self.session = session; self.getToken = getToken
        super.init()
    }
    public func start() async throws {
        guard active == nil else { throw VoiceError.alreadyStarted }
        lastSessionId = nil
        let call = Call(); active = call; state = .connecting
        call.room.add(delegate: audioDelegate)
        do {
            let permitted = await AVCaptureDevice.requestAccess(for: .audio)
            guard !call.stopped else { return }
            guard permitted else { throw VoiceError.microphoneDenied }
            call.credentials = try await getToken(UUID())
            if active === call { lastSessionId = call.credentials?.sessionId }
            guard !call.stopped else { try await release(call); return }
            guard let credentials = call.credentials,
                  UUID(uuidString: credentials.callId) != nil else { throw VoiceError.invalidCredentials }
            try Task.checkCancellation()
            let connection = try JSONDecoder().decode(AudioConnection.self, from: await control(call, method: "POST", suffix: "connection"))
            guard !call.stopped else { try await release(call); return }
            guard URL(string: connection.serverUrl)?.scheme == "wss", !connection.participantToken.isEmpty else { throw VoiceError.invalidCredentials }
            try await call.room.connect(url: connection.serverUrl, token: connection.participantToken)
            guard !call.stopped else { try await release(call); return }
            try await call.room.localParticipant.setMicrophone(enabled: true)
            guard !call.stopped else { try await release(call); return }
            _ = try await control(call, method: "POST", suffix: "connect")
            guard !call.stopped else { return }
            call.waitingSince = Date()
            state = .waiting
            call.polling = Task { [weak self] in await self?.poll(call) }
        } catch {
            let canceled = call.canceledByUser
            do { try await stop(call) } catch { onError?(normalizeError(error)) }
            if !canceled { onError?(normalizeError(error)); throw normalizeError(error) }
        }
    }
    public func setMuted(_ muted: Bool) async throws {
        guard let call = active else { throw VoiceError.notStarted }
        do { try await call.room.localParticipant.setMicrophone(enabled: !muted) } catch { throw normalizeError(error) }
    }
    public func setSpeakerEnabled(_ enabled: Bool) throws {
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none) } catch { throw normalizeError(error) }
        #endif
    }
    public func end() async throws { do { if let call = active { call.canceledByUser = true; try await stop(call) } } catch { throw normalizeError(error) } }
    private func control(_ call: Call, method: String, suffix: String = "") async throws -> Data {
        guard let credentials = call.credentials else { return Data() }
        var url = apiURL.appendingPathComponent("phone/web-calls").appendingPathComponent(credentials.callId)
        if !suffix.isEmpty { url.appendPathComponent(suffix) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.controlToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
    private func poll(_ call: Call) async {
        var failures = 0
        while !call.stopped && !Task.isCancelled {
            do {
                let response = try JSONDecoder().decode(CallStatus.self, from: await control(call, method: "GET"))
                guard !call.stopped else { return }
                failures = 0
                if response.state == .ended {
                    do { try await stop(call) } catch { onError?(normalizeError(error)) }
                    return
                }
                if response.state == .waiting { call.waitingSince = call.waitingSince ?? Date() }
                else { call.waitingSince = nil }
                if let waitingSince = call.waitingSince, Date().timeIntervalSince(waitingSince) > 60 {
                    onError?(VoiceError.connectionTimeout)
                    do { try await stop(call) } catch { onError?(normalizeError(error)) }
                    return
                }
                state = response.state
            } catch {
                guard !call.stopped && !Task.isCancelled else { return }
                failures += 1
                if failures >= 3 {
                    onError?(normalizeError(error))
                    do { try await stop(call) } catch { onError?(normalizeError(error)) }
                    return
                }
            }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }
    private func release(_ call: Call) async throws {
        await call.room.disconnect()
        _ = try await control(call, method: "DELETE")
    }
    private func stop(_ call: Call) async throws {
        call.stopped = true; call.polling?.cancel(); call.room.remove(delegate: audioDelegate)
        if active === call { active = nil; state = .ended }
        // Run cleanup outside a canceled polling/start task so the server still receives hangup.
        try await Task { @MainActor in try await release(call) }.value
    }
}
