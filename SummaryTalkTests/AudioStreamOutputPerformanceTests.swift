import XCTest
import CoreMedia
import AVFoundation
@testable import SummaryTalk

class AudioStreamOutputPerformanceTests: XCTestCase {

    var audioStreamOutput: AudioStreamOutput!
    var sampleBuffer: CMSampleBuffer!

    override func setUp() {
        super.setUp()
        audioStreamOutput = AudioStreamOutput { _ in }
        sampleBuffer = createDummyAudioSampleBuffer()
    }

    override func tearDown() {
        audioStreamOutput = nil
        sampleBuffer = nil
        super.tearDown()
    }

    func testProcessingPerformance() {
        guard let sampleBuffer = sampleBuffer else {
            XCTFail("Failed to create sample buffer")
            return
        }

        measure {
            for _ in 0..<1000 {
                audioStreamOutput.processAudioSampleBuffer(sampleBuffer)
            }
        }
    }

    private func createDummyAudioSampleBuffer() -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)

        guard status == noErr, let formatDescription = formatDesc else { return nil }

        let frameCount = 1024
        let dataSize = frameCount * 4
        var blockBuffer: CMBlockBuffer?

        let status2 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )

        guard status2 == kCMBlockBufferNoErr, let buffer = blockBuffer else { return nil }

        // Fill with dummy data
        let status3 = CMBlockBufferFillDataBytes(with: 0, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: dataSize)
        guard status3 == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: CMTime.zero, decodeTimeStamp: CMTime.invalid)

        let status4 = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return status4 == noErr ? sampleBuffer : nil
    }
}
