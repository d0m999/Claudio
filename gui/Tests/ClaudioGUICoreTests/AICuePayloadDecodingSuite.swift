import ClaudioGUICore
import Foundation

@MainActor
func runAICuePayloadDecodingSuites() {
    suite("AI 提示音 decoded ceilings：三家 wire/decoded 常量按 ticket 独立冻结") {
        expect(
            AICueTransportCeilings.elevenLabsWireBytes == 5 * 1_024 * 1_024,
            "ElevenLabs wire = 5 MiB")
        expect(
            AICueTransportCeilings.elevenLabsDecodedBytes == 5 * 1_024 * 1_024,
            "ElevenLabs decoded = 5 MiB")
        expect(
            AICueTransportCeilings.miniMaxWireBytes == (10 * 1_024 * 1_024) + (512 * 1_024),
            "MiniMax wire = 10 MiB hex + 512 KiB envelope")
        expect(
            AICueTransportCeilings.miniMaxDecodedBytes == 5 * 1_024 * 1_024,
            "MiniMax decoded = 5 MiB")
        expect(AICueTransportCeilings.qwenSSEWireBytes == 256 * 1_024, "Qwen SSE wire = 256 KiB")
        expect(
            AICueTransportCeilings.qwenDecodedPCMBytes == 144_000, "Qwen PCM decoded = 144000 bytes"
        )
    }

    suite("AI 提示音 hex decoder：合法跨字节值解码，奇数/非法/decoded oversize 拒绝") {
        expect(
            try! AICueBoundedHexDecoder.decode("494433", maximumDecodedBytes: 3)
                == Data([0x49, 0x44, 0x33]),
            "MiniMax hex 必须无损解为独立 decoded bytes")
        let cases: [(String, Int, AICueDecodedPayloadError)] = [
            ("0", 3, .invalidEncoding),
            ("GG", 3, .invalidEncoding),
            ("00010203", 3, .decodedPayloadTooLarge),
        ]
        for (value, limit, expectedError) in cases {
            var observed: AICueDecodedPayloadError?
            do {
                _ = try AICueBoundedHexDecoder.decode(value, maximumDecodedBytes: limit)
            } catch let error as AICueDecodedPayloadError {
                observed = error
            } catch {}
            expect(observed == expectedError, "hex 错误必须是脱敏分类")
        }
    }

    suite("AI 提示音 Base64 decoder：跨任意 append 分片且 decoded ceiling 独立于 SSE wire") {
        var split = AICueBoundedBase64Decoder(maximumDecodedBytes: 3)
        for fragment in ["Q", "U", "J", "D"] {
            try! split.append(fragment)
        }
        expect(try! split.finish() == Data("ABC".utf8), "Base64 quartet 跨 callback 仍须正确解码")

        var oversized = AICueBoundedBase64Decoder(maximumDecodedBytes: 2)
        var oversizedError: AICueDecodedPayloadError?
        do {
            try oversized.append("QUJD")
            _ = try oversized.finish()
        } catch let error as AICueDecodedPayloadError {
            oversizedError = error
        } catch {}
        expect(oversizedError == .decodedPayloadTooLarge, "decoded bytes 超限必须在 append 时失败")

        var malformed = AICueBoundedBase64Decoder(maximumDecodedBytes: 8)
        var malformedError: AICueDecodedPayloadError?
        do {
            try malformed.append("QU J")
            _ = try malformed.finish()
        } catch let error as AICueDecodedPayloadError {
            malformedError = error
        } catch {}
        expect(malformedError == .invalidEncoding, "Base64 空白或残缺不能被宽松忽略")
    }
}
