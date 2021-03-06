//
//  Queue.swift
//  
//
//  Created by Thomas Roughton on 26/10/19.
//

import SubstrateUtilities
import Atomics
import Dispatch
import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import CRT
#endif

public final class QueueRegistry {
    public static let instance = QueueRegistry()
    
    public static let maxQueues = UInt8.bitWidth
    
    #if !os(Windows)
    public let commandCompletedMutexes : UnsafeMutablePointer<pthread_mutex_t>
    public let commandCompletedCondVars : UnsafeMutablePointer<pthread_cond_t>
    #endif
    public let lastSubmittedCommands : UnsafeMutablePointer<UInt64.AtomicRepresentation>
    public let lastCompletedCommands : UnsafeMutablePointer<UInt64.AtomicRepresentation>
    public let lastSubmissionTimes : UnsafeMutablePointer<UInt64.AtomicRepresentation>
    public let lastCompletionTimes : UnsafeMutablePointer<UInt64.AtomicRepresentation>
    
    var allocatedQueues : UInt8 = 0
    var lock = SpinLock()
    
    public init() {
#if !os(Windows)
        self.commandCompletedMutexes = .allocate(capacity: Self.maxQueues)
        self.commandCompletedCondVars = .allocate(capacity: Self.maxQueues)
        for i in 0..<Self.maxQueues {
            pthread_mutex_init(self.commandCompletedMutexes.advanced(by: i), nil)
            pthread_cond_init(self.commandCompletedCondVars.advanced(by: i), nil)
        }
#endif
        self.lastSubmittedCommands = .allocate(capacity: Self.maxQueues)
        self.lastCompletedCommands = .allocate(capacity: Self.maxQueues)
        self.lastSubmissionTimes = .allocate(capacity: Self.maxQueues)
        self.lastCompletionTimes = .allocate(capacity: Self.maxQueues)
    }
    
    deinit {
        for i in 0..<Self.maxQueues {
            pthread_cond_destroy(self.commandCompletedCondVars.advanced(by: i))
            pthread_mutex_destroy(self.commandCompletedMutexes.advanced(by: i))
        }
        self.commandCompletedMutexes.deallocate()
        self.commandCompletedCondVars.deallocate()
        self.lastSubmittedCommands.deallocate()
        self.lastCompletedCommands.deallocate()
        self.lastSubmissionTimes.deallocate()
        self.lastCompletionTimes.deallocate()
    }
    
    public static var allQueues : IteratorSequence<QueueIterator> {
        return IteratorSequence(QueueIterator())
    }
    
    public func allocate() -> UInt8 {
        return self.lock.withLock {
            for i in 0..<self.allocatedQueues.bitWidth {
                if self.allocatedQueues & (1 << i) == 0 {
                    self.allocatedQueues |= (1 << i)
                    
                    UInt64.AtomicRepresentation.atomicStore(0, at: self.lastSubmittedCommands.advanced(by: i), ordering: .relaxed)
                    UInt64.AtomicRepresentation.atomicStore(0, at: self.lastCompletedCommands.advanced(by: i), ordering: .relaxed)
                    
                    UInt64.AtomicRepresentation.atomicStore(0, at: self.lastSubmissionTimes.advanced(by: i), ordering: .relaxed)
                    UInt64.AtomicRepresentation.atomicStore(0, at: self.lastCompletionTimes.advanced(by: i), ordering: .relaxed)
                    
                    return UInt8(i)
                }
            }
            
            fatalError("Only \(Self.maxQueues) queues may exist at any time.")
        }
    }
    
    public func dispose(_ queue: Queue) {
        self.lock.withLock {
            assert(self.allocatedQueues & (1 << Int(queue.index)) != 0, "Queue being disposed is not allocated.")
            self.allocatedQueues &= ~(1 << Int(queue.index))
        }
    }
    
    public struct QueueIterator : IteratorProtocol {
        var nextIndex = 0
        
        init() {
            self.nextIndex = (0..<QueueRegistry.maxQueues)
                .first(where: { QueueRegistry.instance.allocatedQueues & (1 << $0) != 0 }) ?? QueueRegistry.maxQueues
        }
        
        public mutating func next() -> Queue? {
            if self.nextIndex < QueueRegistry.maxQueues {
                let queue = Queue(index: UInt8(self.nextIndex))
                self.nextIndex = (0..<QueueRegistry.maxQueues)
                    .dropFirst(self.nextIndex + 1)
                    .first(where: { QueueRegistry.instance.allocatedQueues & (1 << $0) != 0 }) ?? QueueRegistry.maxQueues
                return queue
            }
            return nil
        }
    }
    
    public static var lastSubmittedCommands: QueueCommandIndices {
        var commands = QueueCommandIndices(repeating: 0)
        for (i, queue) in self.allQueues.enumerated() {
            commands[i] = queue.lastSubmittedCommand
        }
        return commands
    }
    
    public static var lastCompletedCommands: QueueCommandIndices {
        var commands = QueueCommandIndices(repeating: 0)
        for (i, queue) in self.allQueues.enumerated() {
            commands[i] = queue.lastCompletedCommand
        }
        return commands
    }
}

public struct Queue : Equatable {
    public let index : UInt8
    
    fileprivate init(index: UInt8) {
        self.index = index
    }
    
    init() {
        self.index = QueueRegistry.instance.allocate()
    }
    
    func dispose() {
        QueueRegistry.instance.dispose(self)
    }
    
    public internal(set) var lastSubmittedCommand : UInt64 {
        get {
            return UInt64.AtomicRepresentation.atomicLoad(at: QueueRegistry.instance.lastSubmittedCommands.advanced(by: Int(self.index)), ordering: .relaxed)
        }
        nonmutating set {
            assert(self.lastSubmittedCommand < newValue)
            UInt64.AtomicRepresentation.atomicStore(newValue, at: QueueRegistry.instance.lastSubmittedCommands.advanced(by: Int(self.index)), ordering: .relaxed)
        }
    }
    
    /// The time at which the last command was submitted.
    public internal(set) var lastSubmissionTime : DispatchTime {
        get {
            let time = UInt64.AtomicRepresentation.atomicLoad(at: QueueRegistry.instance.lastSubmissionTimes.advanced(by: Int(self.index)), ordering: .relaxed)
            return DispatchTime(uptimeNanoseconds: time)
        }
        nonmutating set {
            assert(self.lastSubmissionTime < newValue)
            UInt64.AtomicRepresentation.atomicStore(newValue.uptimeNanoseconds, at: QueueRegistry.instance.lastSubmissionTimes.advanced(by: Int(self.index)), ordering: .relaxed)
        }
    }
    
    public internal(set) var lastCompletedCommand : UInt64 {
        get {
            return UInt64.AtomicRepresentation.atomicLoad(at: QueueRegistry.instance.lastCompletedCommands.advanced(by: Int(self.index)), ordering: .relaxed)
        }
        nonmutating set {
            assert(self.lastCompletedCommand < newValue)
            #if !os(Windows)
            // Broadcast that a command has been completed for any waiting threads.
            pthread_cond_broadcast(QueueRegistry.instance.commandCompletedCondVars.advanced(by: Int(self.index)))
            #endif
            UInt64.AtomicRepresentation.atomicStore(newValue, at: QueueRegistry.instance.lastCompletedCommands.advanced(by: Int(self.index)), ordering: .relaxed)
        }
    }
    
    /// The time at which the last command was completed.
    public internal(set) var lastCompletionTime : DispatchTime {
        get {
            let time = UInt64.AtomicRepresentation.atomicLoad(at: QueueRegistry.instance.lastCompletionTimes.advanced(by: Int(self.index)), ordering: .relaxed)
            return DispatchTime(uptimeNanoseconds: time)
        }
        nonmutating set {
            assert(self.lastCompletionTime < newValue)
            UInt64.AtomicRepresentation.atomicStore(newValue.uptimeNanoseconds, at: QueueRegistry.instance.lastCompletionTimes.advanced(by: Int(self.index)), ordering: .relaxed)
        }
    }
    
    @available(*, deprecated, renamed: "waitForCommandCompletion")
    public func waitForCommand(_ index: UInt64) {
        self.waitForCommandCompletion(index)
    }
    
    public func waitForCommandCompletion(_ index: UInt64) {
        while self.lastCompletedCommand < index {
            #if os(Windows)
            _sleep(0)
            #else
            pthread_mutex_lock(QueueRegistry.instance.commandCompletedMutexes.advanced(by: Int(self.index)))
            pthread_cond_wait(QueueRegistry.instance.commandCompletedCondVars.advanced(by: Int(self.index)), QueueRegistry.instance.commandCompletedMutexes.advanced(by: Int(self.index)))
            pthread_mutex_unlock(QueueRegistry.instance.commandCompletedMutexes.advanced(by: Int(self.index)))
            #endif
        }
    }
}

public typealias QueueCommandIndices = SIMD8<UInt64>
