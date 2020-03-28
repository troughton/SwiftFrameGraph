//
//  MetalFrameGraph.swift
//  MetalRenderer
//
//  Created by Thomas Roughton on 23/12/17.
//

#if canImport(Metal)

import Metal
import FrameGraphUtilities
import CAtomics

enum MetalPreFrameResourceCommands {
    
    // These commands mutate the MetalResourceRegistry and should be executed before render pass execution:
    case materialiseBuffer(Buffer)
    case materialiseTexture(Texture, usage: MetalTextureUsageProperties)
    case materialiseTextureView(Texture, usage: MetalTextureUsageProperties)
    case materialiseArgumentBuffer(_ArgumentBuffer)
    case materialiseArgumentBufferArray(_ArgumentBufferArray)
    case disposeResource(Resource)
    
    case waitForHeapAliasingFences(resource: Resource, waitDependency: FenceDependency)
    
    case waitForCommandBuffer(index: UInt64, queue: Queue)
    case updateCommandBufferWaitIndex(Resource)
    
    var isMaterialiseNonArgumentBufferResource: Bool {
        switch self {
        case .materialiseBuffer, .materialiseTexture, .materialiseTextureView:
            return true
        default:
            return false
        }
    }
    
    func execute(resourceRegistry: MetalTransientResourceRegistry, resourceMap: MetalFrameResourceMap, stateCaches: MetalStateCaches, queue: Queue, encoderDependencies: inout DependencyTable<Dependency?>, waitEventValues: inout QueueCommandIndices, signalEventValue: UInt64) {
        let queueIndex = Int(queue.index)
        
        switch self {
        case .materialiseBuffer(let buffer):
            resourceRegistry.allocateBufferIfNeeded(buffer)
            
            let waitEvent = buffer.flags.contains(.historyBuffer) ? resourceRegistry.historyBufferResourceWaitEvents[Resource(buffer)] : resourceRegistry.bufferWaitEvents[buffer]
            
            waitEventValues[queueIndex] = max(waitEvent!.waitValue, waitEventValues[queueIndex])
            buffer.applyDeferredSliceActions()
            
        case .materialiseTexture(let texture, let usage):
            resourceRegistry.allocateTextureIfNeeded(texture, usage: usage)
            if let textureWaitEvent = (texture.flags.contains(.historyBuffer) ? resourceRegistry.historyBufferResourceWaitEvents[Resource(texture)] : resourceRegistry.textureWaitEvents[texture]) {
                waitEventValues[queueIndex] = max(textureWaitEvent.waitValue, waitEventValues[queueIndex])
            } else {
                precondition(texture.flags.contains(.windowHandle))
            }
            
        case .materialiseTextureView(let texture, let usage):
            resourceRegistry.allocateTextureView(texture, properties: usage)
            
        case .materialiseArgumentBuffer(let argumentBuffer):
            let mtlBufferReference : MTLBufferReference
            if argumentBuffer.flags.contains(.persistent) {
                mtlBufferReference = resourceMap.persistentRegistry.allocateArgumentBufferIfNeeded(argumentBuffer)
            } else {
                mtlBufferReference = resourceRegistry.allocateArgumentBufferIfNeeded(argumentBuffer)
                waitEventValues[queueIndex] = max(resourceRegistry.argumentBufferWaitEvents[argumentBuffer]!.waitValue, waitEventValues[queueIndex])
            }
            argumentBuffer.setArguments(storage: mtlBufferReference, resourceMap: resourceMap, stateCaches: stateCaches)
            
            
        case .materialiseArgumentBufferArray(let argumentBuffer):
            let mtlBufferReference : MTLBufferReference
            if argumentBuffer.flags.contains(.persistent) {
                mtlBufferReference = resourceMap.persistentRegistry.allocateArgumentBufferArrayIfNeeded(argumentBuffer)
            } else {
                mtlBufferReference = resourceRegistry.allocateArgumentBufferArrayIfNeeded(argumentBuffer)
                waitEventValues[queueIndex] = max(resourceRegistry.argumentBufferArrayWaitEvents[argumentBuffer]!.waitValue, waitEventValues[queueIndex])
            }
            argumentBuffer.setArguments(storage: mtlBufferReference, resourceMap: resourceMap, stateCaches: stateCaches)
            
        case .disposeResource(let resource):
            let disposalWaitEvent = MetalContextWaitEvent(waitValue: signalEventValue)
            if let buffer = resource.buffer {
                resourceRegistry.disposeBuffer(buffer, waitEvent: disposalWaitEvent)
            } else if let texture = resource.texture {
                resourceRegistry.disposeTexture(texture, waitEvent: disposalWaitEvent)
            } else if let argumentBuffer = resource.argumentBuffer {
                resourceRegistry.disposeArgumentBuffer(argumentBuffer, waitEvent: disposalWaitEvent)
            } else {
                fatalError()
            }
            
        case .waitForCommandBuffer(let index, let waitQueue):
            waitEventValues[Int(waitQueue.index)] = max(index, waitEventValues[Int(waitQueue.index)])
            
        case .updateCommandBufferWaitIndex(let resource):
            // TODO: split out reads and writes.
            resource[waitIndexFor: queue, accessType: .read] = signalEventValue
            resource[waitIndexFor: queue, accessType: .write] = signalEventValue
            
        case .waitForHeapAliasingFences(let resource, let waitDependency):
            resourceRegistry.withHeapAliasingFencesIfPresent(for: resource.handle, perform: { fenceDependencies in
                for signalDependency in fenceDependencies {
                    let dependency = Dependency(signal: signalDependency, wait: waitDependency)
                    
                    let newDependency = encoderDependencies.dependency(from: dependency.wait.encoderIndex, on: dependency.signal.encoderIndex)?.merged(with: dependency) ?? dependency
                    encoderDependencies.setDependency(from: dependency.wait.encoderIndex, on: dependency.signal.encoderIndex, to: newDependency)
                }
            })
        }
    }
}

enum MetalFrameResourceCommands {
    // These commands need to be executed during render pass execution and do not modify the MetalResourceRegistry.
    case useResource(Resource, usage: MTLResourceUsage, stages: MTLRenderStages)
    case memoryBarrier(Resource, afterStages: MTLRenderStages, beforeStages: MTLRenderStages)
    case updateFence(MetalFenceHandle, afterStages: MTLRenderStages)
    case waitForFence(MetalFenceHandle, beforeStages: MTLRenderStages)
}

enum MetalCompactedFrameResourceCommands {
    // These commands need to be executed during render pass execution and do not modify the MetalResourceRegistry.
    case useResources(UnsafeMutableBufferPointer<MTLResource>, usage: MTLResourceUsage, stages: MTLRenderStages)
    case memoryBarrier(scope: MTLBarrierScope, afterStages: MTLRenderStages, beforeStages: MTLRenderStages)
    case updateFence(Unmanaged<MTLFence>, afterStages: MTLRenderStages)
    case waitForFence(Unmanaged<MTLFence>, beforeStages: MTLRenderStages)
}

struct MetalPreFrameResourceCommand : Comparable {
    var command : MetalPreFrameResourceCommands
    var passIndex : Int
    var index : Int
    var order : PerformOrder
    
    public static func ==(lhs: MetalPreFrameResourceCommand, rhs: MetalPreFrameResourceCommand) -> Bool {
        return lhs.index == rhs.index &&
            lhs.order == rhs.order &&
            lhs.command.isMaterialiseNonArgumentBufferResource == rhs.command.isMaterialiseNonArgumentBufferResource
    }
    
    public static func <(lhs: MetalPreFrameResourceCommand, rhs: MetalPreFrameResourceCommand) -> Bool {
        if lhs.index < rhs.index { return true }
        if lhs.index == rhs.index, lhs.order < rhs.order {
            return true
        }
        // Materialising argument buffers always needs to happen last, after materialising all resources within it.
        if lhs.index == rhs.index, lhs.order == rhs.order, lhs.command.isMaterialiseNonArgumentBufferResource && !rhs.command.isMaterialiseNonArgumentBufferResource {
            return true
        }
        return false
    }
}

struct MetalFrameResourceCommand : Comparable {
    var command : MetalFrameResourceCommands
    var index : Int
    var order : PerformOrder
    
    public static func ==(lhs: MetalFrameResourceCommand, rhs: MetalFrameResourceCommand) -> Bool {
        return lhs.index == rhs.index && lhs.order == rhs.order
    }
    
    public static func <(lhs: MetalFrameResourceCommand, rhs: MetalFrameResourceCommand) -> Bool {
        if lhs.index < rhs.index { return true }
        if lhs.index == rhs.index, lhs.order < rhs.order {
            return true
        }
        return false
    }
}

struct MetalTextureUsageProperties {
    var usage : MTLTextureUsage
    #if os(iOS)
    var canBeMemoryless : Bool
    #endif
    
    init(usage: MTLTextureUsage, canBeMemoryless: Bool = false) {
        self.usage = usage
        #if os(iOS)
        self.canBeMemoryless = canBeMemoryless
        #endif
    }
    
    init(_ usage: TextureUsage) {
        self.init(usage: MTLTextureUsage(usage), canBeMemoryless: false)
    }
}

final class MetalFrameGraphContext : _FrameGraphContext {
    public var accessSemaphore: Semaphore
    
    let backend : MetalBackend
    let resourceRegistry : MetalTransientResourceRegistry
    
    var queueCommandBufferIndex : UInt64 = 0
    let syncEvent : MTLEvent
    
    let commandQueue : MTLCommandQueue
    let captureScope : MTLCaptureScope
    
    public let transientRegistryIndex: Int
    var frameGraphQueue : Queue
    
    var currentRenderTargetDescriptor : RenderTargetDescriptor? = nil
    
    public init(backend: MetalBackend, inflightFrameCount: Int, transientRegistryIndex: Int) {
        self.backend = backend
        self.commandQueue = backend.device.makeCommandQueue()!
        self.frameGraphQueue = Queue()
        self.transientRegistryIndex = transientRegistryIndex
        self.resourceRegistry = MetalTransientResourceRegistry(device: backend.device, inflightFrameCount: inflightFrameCount, transientRegistryIndex: transientRegistryIndex, persistentRegistry: backend.resourceRegistry)
        self.accessSemaphore = Semaphore(value: Int32(inflightFrameCount))
        
        self.captureScope = MTLCaptureManager.shared().makeCaptureScope(device: backend.device)
        self.captureScope.label = "FrameGraph Execution"
        self.syncEvent = backend.device.makeEvent()!
        
        backend.queueSyncEvents[Int(self.frameGraphQueue.index)] = self.syncEvent
    }
    
    deinit {
        backend.queueSyncEvents[Int(self.frameGraphQueue.index)] = nil
        self.frameGraphQueue.dispose()
    }
    
    public func beginFrameResourceAccess() {
        self.backend.setActiveContext(self)
    }
    
    var resourceMap : MetalFrameResourceMap {
        return MetalFrameResourceMap(persistentRegistry: self.backend.resourceRegistry, transientRegistry: self.resourceRegistry)
    }
    
    var resourceRegistryPreFrameCommands = [MetalPreFrameResourceCommand]()
    
    var resourceCommands = [MetalFrameResourceCommand]()
    var renderTargetTextureProperties = [Texture : MetalTextureUsageProperties]()
    var commandEncoderDependencies = DependencyTable<Dependency?>(capacity: 1, defaultValue: nil)
    
    /// - param storedTextures: textures that are stored as part of a render target (and therefore can't be memoryless on iOS)
    func generateResourceCommands(passes: [RenderPassRecord], resourceUsages: ResourceUsages, frameCommandInfo: inout MetalFrameCommandInfo) {
        
        if passes.isEmpty {
            return
        }
        
        self.commandEncoderDependencies.resizeAndClear(capacity: frameCommandInfo.commandEncoders.count, clearValue: nil)
        
        resourceLoop: for resource in resourceUsages.allResources {
            let resourceType = resource.type
            
            let usages = resource.usages
            
            if usages.isEmpty { continue }
            
            do {
                // Track resource residency.
                
                var commandIndex = Int.max
                var previousPass : RenderPassRecord? = nil
                var resourceUsage : MTLResourceUsage = []
                var resourceStages : MTLRenderStages = []
                
                for usage in usages
                    where usage.renderPassRecord.isActive &&
                        usage.renderPassRecord.pass.passType != .external &&
                        /* usage.inArgumentBuffer && */
                        usage.stages != .cpuBeforeRender &&
                        !usage.type.isRenderTarget {
                            
                            defer { previousPass = usage.renderPassRecord }
                            
                            if let previousPassUnwrapped = previousPass, frameCommandInfo.encoderIndex(for: previousPassUnwrapped) != frameCommandInfo.encoderIndex(for: usage.renderPassRecord) {
                                self.resourceCommands.append(MetalFrameResourceCommand(command: .useResource(resource, usage: resourceUsage, stages: resourceStages), index: commandIndex, order: .before))
                                previousPass = nil
                            }
                            
                            if previousPass == nil {
                                resourceUsage = []
                                resourceStages = []
                                commandIndex = usage.commandRange.lowerBound
                            } else {
                                commandIndex = min(commandIndex, usage.commandRange.lowerBound)
                            }
                            
                            if resourceType == .texture, usage.type == .read {
                                resourceUsage.formUnion(.sample)
                            }
                            if usage.isRead {
                                resourceUsage.formUnion(.read)
                            }
                            if usage.isWrite {
                                resourceUsage.formUnion(.write)
                            }
                            
                            resourceStages.formUnion(MTLRenderStages(usage.stages))
                }
                
                if previousPass != nil {
                    self.resourceCommands.append(MetalFrameResourceCommand(command: .useResource(resource, usage: resourceUsage, stages: resourceStages), index: commandIndex, order: .before))
                }
            }
            
            var usageIterator = usages.makeIterator()
            
            // Find the first used render pass.
            var previousUsage : ResourceUsage
            repeat {
                guard let usage = usageIterator.next() else {
                    continue resourceLoop // no active usages for this resource.
                }
                previousUsage = usage
            } while !previousUsage.renderPassRecord.isActive || previousUsage.stages == .cpuBeforeRender
            
            
            var firstUsage = previousUsage
            
            if !firstUsage.isWrite {
                
                // Scan forward from the 'first usage' until we find the _actual_ first usage - that is, the usage whose command range comes first.
                // The 'first usage' might only not actually be the first if the first usages are all reads.
                
                var firstUsageIterator = usageIterator // Since the usageIterator is a struct, this will copy the iterator.
                while let nextUsage = firstUsageIterator.next(), !nextUsage.isWrite {
                    if nextUsage.renderPassRecord.isActive, nextUsage.type != .unusedRenderTarget, nextUsage.commandRange.lowerBound < firstUsage.commandRange.lowerBound {
                        firstUsage = nextUsage
                    }
                }
            }
            
            var readsSinceLastWrite = (firstUsage.isRead && !firstUsage.isWrite) ? [firstUsage] : []
            var previousWrite = firstUsage.isWrite ? firstUsage : nil
            
            if resourceRegistry.isAliasedHeapResource(resource: resource) {
                assert(firstUsage.isWrite || firstUsage.type == .unusedRenderTarget, "Heap resource \(resource) is read from without ever being written to.")
                let fenceDependency = FenceDependency(encoderIndex: frameCommandInfo.encoderIndex(for: firstUsage.renderPassRecord), index: firstUsage.commandRange.lowerBound, stages: firstUsage.stages)
                self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .waitForHeapAliasingFences(resource: resource, waitDependency: fenceDependency), passIndex: firstUsage.renderPassRecord.passIndex, index: firstUsage.commandRange.lowerBound, order: .before))
                
            }
            
            while let usage = usageIterator.next()  {
                if !usage.affectsGPUBarriers {
                    continue
                }
                
                if usage.isWrite {
                    assert(!resource.flags.contains(.immutableOnceInitialised) || !resource.stateFlags.contains(.initialised), "A resource with the flag .immutableOnceInitialised is being written to in \(usage) when it has already been initialised.")
                    
                    for previousRead in readsSinceLastWrite where frameCommandInfo.encoderIndex(for: previousRead.renderPassRecord) != frameCommandInfo.encoderIndex(for: usage.renderPassRecord) {
                        let fromEncoder = frameCommandInfo.encoderIndex(for: usage.renderPassRecord)
                        let onEncoder = frameCommandInfo.encoderIndex(for: previousRead.renderPassRecord)
                        let dependency = Dependency(dependentUsage: usage, dependentEncoder: onEncoder, passUsage: previousRead, passEncoder: fromEncoder)
                        
                        commandEncoderDependencies.setDependency(from: fromEncoder,
                                                                 on: onEncoder,
                                                                 to: commandEncoderDependencies.dependency(from: fromEncoder, on: onEncoder)?.merged(with: dependency) ?? dependency)
                    }
                }
                
                // Only insert a barrier for the first usage following a write.
                if usage.isRead, previousUsage.isWrite,
                    frameCommandInfo.encoderIndex(for: previousUsage.renderPassRecord) == frameCommandInfo.encoderIndex(for: usage.renderPassRecord)  {
                    if !(previousUsage.type.isRenderTarget && (usage.type == .writeOnlyRenderTarget || usage.type == .readWriteRenderTarget)) {
                        assert(!usage.stages.isEmpty || usage.renderPassRecord.pass.passType != .draw)
                        assert(!previousUsage.stages.isEmpty || previousUsage.renderPassRecord.pass.passType != .draw)
                        self.resourceCommands.append(MetalFrameResourceCommand(command: .memoryBarrier(Resource(resource), afterStages: MTLRenderStages(previousUsage.stages.last), beforeStages: MTLRenderStages(usage.stages.first)), index: usage.commandRange.lowerBound, order: .before))
                            
                    }
                }
                
                if (usage.isRead || usage.isWrite), let previousWrite = previousWrite, frameCommandInfo.encoderIndex(for: previousWrite.renderPassRecord) != frameCommandInfo.encoderIndex(for: usage.renderPassRecord) {
                    let fromEncoder = frameCommandInfo.encoderIndex(for: usage.renderPassRecord)
                    let onEncoder = frameCommandInfo.encoderIndex(for: previousWrite.renderPassRecord)
                    let dependency = Dependency(dependentUsage: usage, dependentEncoder: onEncoder, passUsage: previousWrite, passEncoder: fromEncoder)
                    
                    commandEncoderDependencies.setDependency(from: fromEncoder,
                                                             on: onEncoder,
                                                             to: commandEncoderDependencies.dependency(from: fromEncoder, on: onEncoder)?.merged(with: dependency) ?? dependency)
                }
                
                if usage.isWrite {
                    readsSinceLastWrite.removeAll(keepingCapacity: true)
                    previousWrite = usage
                }
                if usage.isRead, !usage.isWrite {
                    readsSinceLastWrite.append(usage)
                }
                
                if usage.commandRange.endIndex > previousUsage.commandRange.endIndex { // FIXME: this is only necessary because resource commands are executed sequentially; this will only be false if both usage and previousUsage are reads, and so it doesn't matter which order they happen in.
                    // A better solution would be to effectively compile all resource commands ahead of time - doing so will also enable multithreading and out-of-order execution of render passes.
                    previousUsage = usage
                }
            }
            
            let lastUsage = previousUsage
            
            defer {
                if previousWrite != nil, resource.flags.intersection([.historyBuffer, .persistent]) != [] {
                    resource.markAsInitialised()
                }
            }
            
            let historyBufferUseFrame = resource.flags.contains(.historyBuffer) && resource.stateFlags.contains(.initialised)
            
            #if os(iOS)
            var canBeMemoryless = false
            #else
            let canBeMemoryless = false
            #endif
            
            // Insert commands to materialise and dispose of the resource.
            if let argumentBuffer = resource.argumentBuffer {
                // Unlike textures and buffers, we materialise persistent argument buffers at first use rather than immediately.
                if !historyBufferUseFrame {
                    self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .materialiseArgumentBuffer(argumentBuffer), passIndex: firstUsage.renderPassRecord.passIndex, index: firstUsage.commandRange.lowerBound, order: .before))
                }
                
                if !resource.flags.contains(.persistent), !resource.flags.contains(.historyBuffer) || resource.stateFlags.contains(.initialised) {
                    if historyBufferUseFrame {
                        self.resourceRegistry.registerInitialisedHistoryBufferForDisposal(resource: resource)
                    } else {
                        self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .disposeResource(resource), passIndex: lastUsage.renderPassRecord.passIndex, index: lastUsage.commandRange.last!, order: .after))
                    }
                } else if resource.flags.contains(.persistent), (!resource.stateFlags.contains(.initialised) || !resource.flags.contains(.immutableOnceInitialised)) {
                    for queue in QueueRegistry.allQueues {
                        // TODO: separate out the wait index for the first read from the first write.
                        let waitIndex = resource[waitIndexFor: queue, accessType: previousWrite != nil ? .readWrite : .read]
                        self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .waitForCommandBuffer(index: waitIndex, queue: queue), passIndex: firstUsage.renderPassRecord.passIndex, index: firstUsage.commandRange.last!, order: .before))
                    }
                    self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .updateCommandBufferWaitIndex(resource), passIndex: lastUsage.renderPassRecord.passIndex, index: lastUsage.commandRange.last!, order: .after))
                }
                
            } else if !resource.flags.contains(.persistent) || resource.flags.contains(.windowHandle) {
                if let buffer = resource.buffer {
                    if !historyBufferUseFrame {
                        self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .materialiseBuffer(buffer), passIndex: firstUsage.renderPassRecord.passIndex, index: firstUsage.commandRange.lowerBound, order: .before))
                    }
                    
                    if !resource.flags.contains(.historyBuffer) || resource.stateFlags.contains(.initialised) {
                        if historyBufferUseFrame {
                            self.resourceRegistry.registerInitialisedHistoryBufferForDisposal(resource: resource)
                        } else {
                            self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .disposeResource(resource), passIndex: lastUsage.renderPassRecord.passIndex, index: lastUsage.commandRange.last!, order: .after))
                        }
                    }
                    
                } else if let texture = resource.texture {
                    var textureUsage : MTLTextureUsage = []
                    
                    for usage in usages {
                        switch usage.type {
                        case .read:
                            textureUsage.formUnion(.shaderRead)
                        case .write:
                            textureUsage.formUnion(.shaderWrite)
                        case .readWrite:
                            textureUsage.formUnion([.shaderRead, .shaderWrite])
                        case .readWriteRenderTarget, .writeOnlyRenderTarget, .inputAttachmentRenderTarget, .unusedRenderTarget:
                            textureUsage.formUnion(.renderTarget)
                        default:
                            break
                        }
                    }
                    
                    if texture.descriptor.usageHint.contains(.pixelFormatView) {
                        textureUsage.formUnion(.pixelFormatView)
                    }
                    
                    #if os(iOS) || os(tvOS) || os(watchOS)
                    canBeMemoryless = (texture.flags.intersection([.persistent, .historyBuffer]) == [] || (texture.flags.contains(.persistent) && texture.descriptor.usageHint == .renderTarget))
                        && textureUsage == .renderTarget
                        && !frameCommandInfo.storedTextures.contains(texture)
                    let properties = MetalTextureUsageProperties(usage: textureUsage, canBeMemoryless: canBeMemoryless)
                    #else
                    let properties = MetalTextureUsageProperties(usage: textureUsage)
                    #endif
                    
                    assert(properties.usage != .unknown)
                    
                    if textureUsage.contains(.renderTarget) {
                        self.renderTargetTextureProperties[texture] = properties
                    }
                    
                    if !historyBufferUseFrame {
                        if texture.isTextureView {
                            self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .materialiseTextureView(texture, usage: properties), passIndex: firstUsage.renderPassRecord.passIndex, index: firstUsage.commandRange.lowerBound, order: .before))
                        } else {
                            self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .materialiseTexture(texture, usage: properties), passIndex: firstUsage.renderPassRecord.passIndex, index: firstUsage.commandRange.lowerBound, order: .before))
                        }
                    }
                    
                    if !resource.flags.contains(.historyBuffer) || resource.stateFlags.contains(.initialised) {
                        if historyBufferUseFrame {
                            self.resourceRegistry.registerInitialisedHistoryBufferForDisposal(resource: Resource(texture))
                        } else {
                            self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .disposeResource(resource), passIndex: lastUsage.renderPassRecord.passIndex, index: lastUsage.commandRange.last!, order: .after))
                        }
                        
                    }
                }
            } else if resource.flags.contains(.persistent), (!resource.stateFlags.contains(.initialised) || !resource.flags.contains(.immutableOnceInitialised)) {
                for queue in QueueRegistry.allQueues {
                    // TODO: separate out the wait index for the first read from the first write.
                    let waitIndex = resource[waitIndexFor: queue, accessType: previousWrite != nil ? .readWrite : .read]
                    self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .waitForCommandBuffer(index: waitIndex, queue: queue), passIndex: firstUsage.renderPassRecord.passIndex, index: firstUsage.commandRange.last!, order: .before))
                }
                self.resourceRegistryPreFrameCommands.append(MetalPreFrameResourceCommand(command: .updateCommandBufferWaitIndex(resource), passIndex: lastUsage.renderPassRecord.passIndex, index: lastUsage.commandRange.last!, order: .after))
            }
            
            if resourceRegistry.isAliasedHeapResource(resource: resource), !canBeMemoryless {
                // Reads need to wait for all previous writes to complete.
                // Writes need to wait for all previous reads and writes to complete.
                
                var storeFences : [FenceDependency] = []
                
                // We only need to wait for the write to complete if there have been no reads since the write; otherwise, we wait on the reads
                // which in turn have a transitive dependency on the write.
                if readsSinceLastWrite.isEmpty, let previousWrite = previousWrite, previousWrite.renderPassRecord.pass.passType != .external {
                    storeFences = [FenceDependency(encoderIndex: frameCommandInfo.encoderIndex(for: previousWrite.renderPassRecord), index: previousWrite.commandRange.last!, stages: previousWrite.stages)]
                }
                
                for read in readsSinceLastWrite where read.renderPassRecord.pass.passType != .external {
                    storeFences.append(FenceDependency(encoderIndex: frameCommandInfo.encoderIndex(for: read.renderPassRecord), index: read.commandRange.last!, stages: read.stages))
                }
                
                // setDisposalFences retains its fences.
                self.resourceRegistry.setDisposalFences(on: resource, to: storeFences)
            }
            
        }
        
        self.resourceRegistryPreFrameCommands.sort()
        
        // MARK: - Execute the pre-frame resource commands.
        
        for command in self.resourceRegistryPreFrameCommands {
            let encoderIndex = frameCommandInfo.encoderIndex(for: command.passIndex)
            let commandBufferIndex = frameCommandInfo.commandEncoders[encoderIndex].commandBufferIndex
            command.command.execute(resourceRegistry: self.resourceRegistry, resourceMap: self.resourceMap, stateCaches: backend.stateCaches, queue: self.frameGraphQueue,
                                    encoderDependencies: &self.commandEncoderDependencies,
                                    waitEventValues: &frameCommandInfo.commandEncoders[encoderIndex].queueCommandWaitIndices, signalEventValue: frameCommandInfo.signalValue(commandBufferIndex: commandBufferIndex))
        }
        
        self.resourceRegistryPreFrameCommands.removeAll(keepingCapacity: true)
        
        // MARK: - Generate the fences
        
        // Process the dependencies, joining duplicates.
        do {
            
            // Floyd-Warshall algorithm for finding the shortest path.
            // https://en.wikipedia.org/wiki/Floyd–Warshall_algorithm
            let commandEncoderCount = frameCommandInfo.commandEncoders.count
            let maxDistance = commandEncoderCount + 1
            
            var distanceMatrix = DependencyTable<Int>(capacity: commandEncoderCount, defaultValue: maxDistance)
            for sourceIndex in 0..<commandEncoderCount {
                for dependentIndex in min(sourceIndex + 1, commandEncoderCount)..<commandEncoderCount {
                    if self.commandEncoderDependencies.dependency(from: dependentIndex, on: sourceIndex) != nil {
                        distanceMatrix.setDependency(from: dependentIndex, on: sourceIndex, to: 1)
                    }
                }
            }
            
            for k in 0..<commandEncoderCount {
                for i in min(k + 1, commandEncoderCount)..<commandEncoderCount {
                    for j in min(i + 1, commandEncoderCount)..<commandEncoderCount {
                        let candidateDistance = distanceMatrix.dependency(from: i, on: k) + distanceMatrix.dependency(from: j, on: i)
                        if distanceMatrix.dependency(from: j, on: k) > candidateDistance {
                            distanceMatrix.setDependency(from: j, on: k, to: candidateDistance)
                        }
                    }
                }
            }
            
            // Transitive reduction:
            // https://stackoverflow.com/questions/1690953/transitive-reduction-algorithm-pseudocode
            var reductionMatrix = DependencyTable<Bool>(capacity: commandEncoderCount, defaultValue: false)
            for sourceIndex in 0..<commandEncoderCount {
                for dependentIndex in min(sourceIndex + 1, commandEncoderCount)..<commandEncoderCount {
                    if distanceMatrix.dependency(from: dependentIndex, on: sourceIndex) < maxDistance {
                        reductionMatrix.setDependency(from: dependentIndex, on: sourceIndex, to: true)
                    }
                }
            }
            

            for i in 0..<commandEncoderCount {
                for j in 0..<i {
                    if reductionMatrix.dependency(from: i, on: j) {
                        for k in 0..<j {
                            if reductionMatrix.dependency(from: j, on: k) {
                                reductionMatrix.setDependency(from: i, on: k, to: false)
                            }
                        }
                    }
                }
            }
            
            // Process the dependencies, joining duplicates.
            for sourceIndex in (0..<commandEncoderCount) { // sourceIndex always points to the producing pass.
                for dependentIndex in min(sourceIndex + 1, commandEncoderCount)..<commandEncoderCount {
                    if reductionMatrix.dependency(from: dependentIndex, on: sourceIndex) {
                        let dependency = self.commandEncoderDependencies.dependency(from: dependentIndex, on: sourceIndex)!
                        let label = "(Encoder \(sourceIndex) to Encoder \(dependentIndex))"
                        let commandBufferSignalIndex = frameCommandInfo.signalValue(commandBufferIndex: frameCommandInfo.commandEncoders[dependency.wait.encoderIndex].commandBufferIndex)
                        
                        let fence = MetalFenceHandle(label: label, queue: self.frameGraphQueue, commandBufferIndex: commandBufferSignalIndex)
                        self.resourceCommands.append(MetalFrameResourceCommand(command: .updateFence(fence, afterStages: MTLRenderStages(dependency.signal.stages)), index: dependency.signal.index, order: .after))
                        self.resourceCommands.append(MetalFrameResourceCommand(command: .waitForFence(fence, beforeStages: MTLRenderStages(dependency.wait.stages)), index: dependency.wait.index, order: .before))
                    }
                }
            }
        }
        
        self.resourceCommands.sort()
    }
    
    public func executeFrameGraph(passes: [RenderPassRecord], dependencyTable: DependencyTable<SwiftFrameGraph.DependencyType>, resourceUsages: ResourceUsages, completion: @escaping () -> Void) {
        self.resourceRegistry.prepareFrame()
        
        defer {
            self.resourceRegistry.cycleFrames()

            self.resourceCommands.removeAll(keepingCapacity: true)
            self.renderTargetTextureProperties.removeAll(keepingCapacity: true)
            
            assert(self.backend.activeContext === self)
            self.backend.activeContext = nil
        }
        
        if passes.isEmpty {
            completion()
            self.accessSemaphore.signal()
            return
        }
        
        var frameCommandInfo = MetalFrameCommandInfo(passes: passes, resourceUsages: resourceUsages, initialCommandBufferSignalValue: self.queueCommandBufferIndex + 1)
        
        self.generateResourceCommands(passes: passes, resourceUsages: resourceUsages, frameCommandInfo: &frameCommandInfo)
        
        func executePass(_ passRecord: RenderPassRecord, i: Int, encoderInfo: MetalFrameCommandInfo.CommandEncoderInfo, encoderManager: MetalEncoderManager) {
            switch passRecord.pass.passType {
            case .blit:
                let commandEncoder = encoderManager.blitCommandEncoder()
                if commandEncoder.encoder.label == nil {
                    commandEncoder.encoder.label = encoderInfo.name
                }
                
                commandEncoder.executePass(passRecord, resourceCommands: resourceCommands, resourceMap: self.resourceMap, stateCaches: backend.stateCaches)
                
            case .draw:
                guard let commandEncoder = encoderManager.renderCommandEncoder(descriptor: encoderInfo.renderTargetDescriptor!, textureUsages: self.renderTargetTextureProperties, resourceCommands: resourceCommands, resourceMap: self.resourceMap, stateCaches: backend.stateCaches) else {
                    if _isDebugAssertConfiguration() {
                        print("Warning: skipping pass \(passRecord.pass.name) since the drawable for the render target could not be retrieved.")
                    }
                    
                    return
                }
                if commandEncoder.label == nil {
                    commandEncoder.label = encoderInfo.name
                }
                
                commandEncoder.executePass(passRecord, resourceCommands: resourceCommands, renderTarget: encoderInfo.renderTargetDescriptor!.descriptor, passRenderTarget: (passRecord.pass as! DrawRenderPass).renderTargetDescriptor, resourceMap: self.resourceMap, stateCaches: backend.stateCaches)
            case .compute:
                let commandEncoder = encoderManager.computeCommandEncoder()
                if commandEncoder.encoder.label == nil {
                    commandEncoder.encoder.label = encoderInfo.name
                }
                
                commandEncoder.executePass(passRecord, resourceCommands: resourceCommands, resourceMap: self.resourceMap, stateCaches: backend.stateCaches)
                
            case .external:
                let commandEncoder = encoderManager.externalCommandEncoder()
                commandEncoder.executePass(passRecord, resourceCommands: resourceCommands, resourceMap: self.resourceMap, stateCaches: backend.stateCaches)
                
            case .cpu:
                break
            }
        }
        
        self.captureScope.begin()
        defer { self.captureScope.end() }
        
        // Use separate command buffers for onscreen and offscreen work (Delivering Optimised Metal Apps and Games, WWDC 2019)
        
        let lastCommandBufferIndex = frameCommandInfo.commandBufferCount - 1
        
        var commandBuffer : MTLCommandBuffer? = nil
        var encoderManager : MetalEncoderManager? = nil
        
        var committedCommandBufferCount = 0
        var previousCommandEncoderIndex = -1

        func processCommandBuffer() {
            encoderManager?.endEncoding()
            
            if let commandBuffer = commandBuffer {
                // Only contains drawables applicable to the render passes in the command buffer...
                for drawable in self.resourceRegistry.frameDrawables {
                    #if os(iOS)
                    commandBuffer.present(drawable, afterMinimumDuration: 1.0 / 60.0)
                    #else
                    commandBuffer.present(drawable)
                    #endif
                }
                // because we reset the list after each command buffer submission.
                self.resourceRegistry.clearDrawables()
                
                // Make sure that the sync event value is what we expect, so we don't update it past
                // the signal for another buffer before that buffer has completed.
                // We only need to do this if we haven't already waited in this command buffer for it.
                // if commandEncoderWaitEventValues[commandEncoderIndex] != self.queueCommandBufferIndex {
                //     commandBuffer.encodeWaitForEvent(self.syncEvent, value: self.queueCommandBufferIndex)
                // }
                // Then, signal our own completion.
                self.queueCommandBufferIndex += 1
                commandBuffer.encodeSignalEvent(self.syncEvent, value: self.queueCommandBufferIndex)

                let cbIndex = committedCommandBufferCount
                let queueCBIndex = self.queueCommandBufferIndex

                commandBuffer.addCompletedHandler { (commandBuffer) in
                    if let error = commandBuffer.error {
                        print("Error executing command buffer \(queueCBIndex): \(error)")
                    }
                    self.frameGraphQueue.lastCompletedCommand = queueCBIndex
                    if cbIndex == lastCommandBufferIndex { // Only call completion for the last command buffer.
                        completion()
                        self.accessSemaphore.signal()
                    }
                }
                
                self.frameGraphQueue.lastSubmittedCommand = queueCBIndex
                commandBuffer.commit()
                committedCommandBufferCount += 1
                
            }
            commandBuffer = nil
            encoderManager = nil
        }
        
        var waitedEvents = QueueCommandIndices(repeating: 0)
        
        for (i, passRecord) in passes.enumerated() {
            let passCommandEncoderIndex = frameCommandInfo.encoderIndex(for: passRecord)
            let passEncoderInfo = frameCommandInfo.commandEncoders[passCommandEncoderIndex]
            let commandBufferIndex = passEncoderInfo.commandBufferIndex
            if commandBufferIndex != committedCommandBufferCount {
                processCommandBuffer()
            }
            
            if commandBuffer == nil {
                commandBuffer = self.commandQueue.makeCommandBuffer()!
                encoderManager = MetalEncoderManager(commandBuffer: commandBuffer!, resourceMap: self.resourceMap)
            }
            
            if previousCommandEncoderIndex != passCommandEncoderIndex {
                previousCommandEncoderIndex = passCommandEncoderIndex
                encoderManager?.endEncoding()
                
                let waitEventValues = passEncoderInfo.queueCommandWaitIndices
                for queue in QueueRegistry.allQueues {
                    if waitedEvents[Int(queue.index)] < waitEventValues[Int(queue.index)],
                        waitEventValues[Int(queue.index)] > queue.lastCompletedCommand {
                        if let event = backend.queueSyncEvents[Int(queue.index)] {
                            commandBuffer!.encodeWaitForEvent(event, value: waitEventValues[Int(queue.index)])
                        } else {
                            // It's not a Metal queue, so the best we can do is sleep and wait until the queue is completd.
                            while queue.lastCompletedCommand < waitEventValues[Int(queue.index)] {
                                sleep(0)
                            }
                        }
                    }
                }
                waitedEvents = pointwiseMax(waitEventValues, waitedEvents)
            }
            
            executePass(passRecord, i: i, encoderInfo: passEncoderInfo, encoderManager: encoderManager!)
        }
        
        processCommandBuffer()
    }
}

#endif // canImport(Metal)
