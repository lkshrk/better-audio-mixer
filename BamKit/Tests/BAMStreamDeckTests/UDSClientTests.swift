import Foundation
import Testing
@testable import BAMStreamDeck

@MainActor
struct UDSClientTests {
    @Test func consumedBytesDoNotAccumulateBehindPartialFrame() {
        let client = UDSClient()
        var received = 0
        client.onFrame = { _ in received += 1 }
        client.consume(Data("{\"t\":\"meter\"".utf8))
        let batch = Data("}\n{\"t\":\"meter\"".utf8)
        for _ in 0..<10_000 { client.consume(batch) }
        #expect(received == 10_000)
        #expect(client.readBuffer == Data("{\"t\":\"meter\"".utf8))
        #expect(client.readBuffer.startIndex == 0)
    }

    @Test func fragmentedAndCoalescedFramesPreserveOrderAndPartialBytes() {
        let client = UDSClient()
        var types: [String] = []
        client.onFrame = { if let type = $0["t"] as? String { types.append(type) } }
        client.consume(Data("\n{\"t\":\"sta".utf8))
        #expect(types.isEmpty)
        client.consume(Data("te\"}\ninvalid json\n\n{\"t\":\"meter\"}\n{\"t\":\"del".utf8))
        #expect(types == ["state", "meter"])
        #expect(client.readBuffer == Data("{\"t\":\"del".utf8))
        client.consume(Data("ta\"}\n".utf8))
        #expect(types == ["state", "meter", "delta"])
        #expect(client.readBuffer.isEmpty)
    }
}
