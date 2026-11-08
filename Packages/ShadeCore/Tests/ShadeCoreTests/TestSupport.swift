import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ShadeCore

/// A fresh temporary directory per test, removed afterwards.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("shadecore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ text: String, to name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }
}

func XCTAssertShadeError<T>(_ code: ShadeError.Code, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
    do {
        _ = try body()
        XCTFail("expected \(code.rawValue), got success", file: file, line: line)
    } catch let error as ShadeError {
        XCTAssertEqual(error.code, code, "message: \(error.message)", file: file, line: line)
    } catch {
        XCTFail("expected ShadeError \(code.rawValue), got \(error)", file: file, line: line)
    }
}

func assertShadeErrorAsync<T>(_ code: ShadeError.Code, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected \(code.rawValue), got success", file: file, line: line)
    } catch let error as ShadeError {
        XCTAssertEqual(error.code, code, "message: \(error.message)", file: file, line: line)
    } catch {
        XCTFail("expected ShadeError \(code.rawValue), got \(error)", file: file, line: line)
    }
}

/// A recipe file exactly as Shade 1.0 wrote it (pretty, sorted keys, with id and format).
let legacyFileJSON = """
{
  "author" : "Claude",
  "description" : "Flat comic colors.",
  "format" : "shade.recipe/1",
  "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "name" : "Legacy Comic",
  "passes" : [
    {
      "effect" : "posterize",
      "params" : {
        "levels" : 4
      }
    },
    {
      "code" : "float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) {\\n    return SRC(uv) * P.gain;\\n}",
      "name" : "Gain",
      "params" : [
        {
          "max" : 3,
          "min" : 0,
          "name" : "gain",
          "type" : "float",
          "value" : 1.5
        }
      ]
    }
  ]
}
"""

/// Scripted HTTP responses for ClaudeClient tests. Records every request it receives.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case http(Int, String, [String: String])
        case failure(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.locked {
            requests.append(request)
            return replies.isEmpty ? .http(500, "{}", [:]) : replies.removeFirst()
        }
        switch reply {
        case .failure(let error):
            throw error
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }

    var callCount: Int { lock.locked { requests.count } }
}

/// Records sleeps instead of waiting, so retry tests run instantly.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [TimeInterval] = []
    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] d in self.lock.locked { self.delays.append(d) } }
    }
}

func messagesBody(text: String, stop: String = "end_turn", extraBlocks: [String] = []) -> String {
    let textBlock = "{\"type\":\"text\",\"text\":\(jsonString(text))}"
    let blocks = (extraBlocks + [textBlock]).joined(separator: ",")
    return "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-opus-5-5\",\"content\":[\(blocks)],\"stop_reason\":\"\(stop)\"}"
}

func jsonString(_ s: String) -> String {
    String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
