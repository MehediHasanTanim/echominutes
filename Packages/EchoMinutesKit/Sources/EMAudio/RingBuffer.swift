import Atomics
import Foundation

/// Lock-free single-producer / single-consumer ring buffer of Float32 samples (Technical Design §7.4, EM-040).
///
/// * Producer = Core Audio IO thread: `write…` methods never allocate, lock or block.
/// * Consumer = writer queue: `read`, `discard…`.
/// * When full, the producer drops the *new* samples and counts an overrun (it never touches the read index).
/// * Pre-roll: the consumer keeps only the last N samples with `discardAllButLast(_:)`.
public final class SPSCRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = ManagedAtomic<Int>(0)   // total samples ever written (monotonic)
    private let readIndex = ManagedAtomic<Int>(0)    // total samples ever consumed (monotonic)
    private let overrunCounter = ManagedAtomic<Int>(0)

    /// Capacity is rounded up to a power of two.
    public init(minimumCapacity: Int) {
        var c = 1
        while c < max(minimumCapacity, 2) { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    public var availableToRead: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed) }
    public var availableToWrite: Int { capacity - (writeIndex.load(ordering: .relaxed) - readIndex.load(ordering: .acquiring)) }
    /// Samples dropped because the buffer was full.
    public var overruns: Int { overrunCounter.load(ordering: .relaxed) }
    /// Total samples written since creation (incl. later-discarded ones).
    public var totalWritten: Int { writeIndex.load(ordering: .acquiring) }

    // MARK: Producer (real-time safe)

    /// Copies `count` samples from `src` taking every `stride`-th value (e.g. channel 0 of interleaved audio).
    /// Returns samples written; the rest is counted as overrun.
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int, stride: Int = 1) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let free = capacity - (w - readIndex.load(ordering: .acquiring))
        let n = min(count, free)
        for i in 0..<n { storage[(w + i) & mask] = src[i * stride] }
        if n < count { overrunCounter.wrappingIncrement(by: count - n, ordering: .relaxed) }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Writes the average of `channels` interleaved channels for `frames` frames (stereo → mono downmix).
    @discardableResult
    public func writeDownmix(_ src: UnsafePointer<Float>, frames: Int, channels: Int) -> Int {
        guard channels > 1 else { return write(src, count: frames) }
        let w = writeIndex.load(ordering: .relaxed)
        let free = capacity - (w - readIndex.load(ordering: .acquiring))
        let n = min(frames, free)
        let scale = 1 / Float(channels)
        for i in 0..<n {
            var sum: Float = 0
            for c in 0..<channels { sum += src[i * channels + c] }
            storage[(w + i) & mask] = sum * scale
        }
        if n < frames { overrunCounter.wrappingIncrement(by: frames - n, ordering: .relaxed) }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Writes `count` zeros (keeps tracks aligned when one side delivers no buffer).
    @discardableResult
    public func writeSilence(count: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let free = capacity - (w - readIndex.load(ordering: .acquiring))
        let n = min(count, free)
        for i in 0..<n { storage[(w + i) & mask] = 0 }
        if n < count { overrunCounter.wrappingIncrement(by: count - n, ordering: .relaxed) }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    // MARK: Consumer

    /// Reads up to `maxCount` samples into `dst`; returns the number read.
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let n = min(maxCount, writeIndex.load(ordering: .acquiring) - r)
        for i in 0..<n { dst[i] = storage[(r + i) & mask] }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    /// Convenience for tests / non-RT code.
    public func read(maxCount: Int) -> [Float] {
        [Float](unsafeUninitializedCapacity: maxCount) { buf, initialized in
            initialized = read(into: buf.baseAddress!, maxCount: maxCount)
        }
    }

    /// Drops everything except the newest `keep` samples (pre-roll window). Returns samples dropped.
    @discardableResult
    public func discardAllButLast(_ keep: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let drop = max(0, (w - r) - keep)
        if drop > 0 { readIndex.store(r + drop, ordering: .releasing) }
        return drop
    }

    @discardableResult
    public func discardAll() -> Int { discardAllButLast(0) }
}
