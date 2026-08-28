import Foundation
import Testing
@testable import MaryBrain

/// WHO GETS THE ENGINE NEXT.
///
/// THE REGRESSION THIS PINS: the gate was strict FIFO, and with the local MLX
/// engine every generation round in the process passes through it. Five
/// detached routines were therefore a queue up to fifty rounds deep, and the
/// live turn behind them could not make its 250 ms join grace no matter how
/// small its request was — so it detached too, and the queue grew. Letting an
/// attached round past background ones is the fix; these tests pin that it
/// happens, and that it does not reorder anything else.
@Suite struct AsyncGatePriorityTests {

    /// A tiny ordered log the waiters write their names into as they wake.
    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func note(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            names.append(name)
        }
        var value: [String] {
            lock.lock(); defer { lock.unlock() }
            return names
        }
    }

    /// Queue a waiter and wait until the gate has actually parked it, so the
    /// test controls arrival order rather than racing the scheduler.
    private func enqueue(
        _ gate: AsyncGate, _ name: String,
        _ priority: AsyncGate.Priority, into order: Order,
        expecting depth: Int
    ) async -> Task<Void, Never> {
        let task = Task {
            _ = await gate.acquire(priority: priority)
            order.note(name)
            gate.release()
        }
        while gate.waiterCount < depth { await Task.yield() }
        return task
    }

    @Test func anAttachedRoundGoesAheadOfQueuedBackgroundOnes() async {
        let gate = AsyncGate()
        let order = Order()
        #expect(await gate.acquire(priority: .attached))

        var tasks: [Task<Void, Never>] = []
        tasks.append(await enqueue(gate, "bg1", .detached, into: order, expecting: 1))
        tasks.append(await enqueue(gate, "bg2", .detached, into: order, expecting: 2))
        tasks.append(await enqueue(gate, "live", .attached, into: order, expecting: 3))

        gate.release()
        for task in tasks { await task.value }
        // The live turn overtakes both background rounds; the background ones
        // keep their order relative to each other.
        #expect(order.value == ["live", "bg1", "bg2"])
    }

    @Test func attachedRoundsKeepFifoAmongThemselves() async {
        let gate = AsyncGate()
        let order = Order()
        #expect(await gate.acquire(priority: .attached))

        var tasks: [Task<Void, Never>] = []
        tasks.append(await enqueue(gate, "live1", .attached, into: order, expecting: 1))
        tasks.append(await enqueue(gate, "bg", .detached, into: order, expecting: 2))
        tasks.append(await enqueue(gate, "live2", .attached, into: order, expecting: 3))

        gate.release()
        for task in tasks { await task.value }
        // live2 goes ahead of the background round but never ahead of live1.
        #expect(order.value == ["live1", "live2", "bg"])
    }

    @Test func withNoAttachedWaitersTheOrderIsUnchanged() async {
        let gate = AsyncGate()
        let order = Order()
        #expect(await gate.acquire(priority: .detached))

        var tasks: [Task<Void, Never>] = []
        tasks.append(await enqueue(gate, "a", .detached, into: order, expecting: 1))
        tasks.append(await enqueue(gate, "b", .detached, into: order, expecting: 2))
        tasks.append(await enqueue(gate, "c", .detached, into: order, expecting: 3))

        gate.release()
        for task in tasks { await task.value }
        #expect(order.value == ["a", "b", "c"])
    }

    /// The gate's existing contract, unchanged by the tiering: a waiter that
    /// is cancelled resumes with FALSE and holds nothing, so a superseded lane
    /// never occupies a slot ahead of a live one.
    @Test func aCancelledWaiterReleasesItsPlaceAndAcquiresNothing() async {
        let gate = AsyncGate()
        #expect(await gate.acquire(priority: .attached))

        let acquired = Task { await gate.acquire(priority: .attached) }
        while gate.waiterCount < 1 { await Task.yield() }
        acquired.cancel()
        #expect(await acquired.value == false)
        #expect(gate.waiterCount == 0)
        gate.release()
    }

    @Test func theWaiterCountReportsTheQueueDepth() async {
        let gate = AsyncGate()
        #expect(gate.waiterCount == 0)
        #expect(await gate.acquire(priority: .detached))
        // The holder is not a waiter.
        #expect(gate.waiterCount == 0)

        let task = await enqueue(gate, "one", .detached, into: Order(), expecting: 1)
        #expect(gate.waiterCount == 1)
        gate.release()
        await task.value
        #expect(gate.waiterCount == 0)
    }
}
