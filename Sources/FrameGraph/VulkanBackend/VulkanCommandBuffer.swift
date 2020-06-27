//
//  VulkanCommandBuffer.swift
//  VkRenderer
//
//  Created by Thomas Roughton on 10/01/18.
//

#if canImport(Vulkan)
import Vulkan
import FrameGraphCExtras
import FrameGraphUtilities

// Represents all resources that are associated with a particular command buffer
// and should be freed once the command buffer has finished execution.
public final class VulkanCommandBuffer: BackendCommandBuffer {
    typealias Backend = VulkanBackend
    
    let backend: VulkanBackend
    let queue: VulkanDeviceQueue
    let commandBuffer: VkCommandBuffer
    let commandInfo: FrameCommandInfo<VulkanBackend>
    let textureUsages: [Texture: TextureUsageProperties]
    let resourceMap: FrameResourceMap<VulkanBackend>
    let compactedResourceCommands: [CompactedResourceCommand<VulkanCompactedResourceCommandType>]
    
    var buffers = [VulkanBuffer]()
    var bufferView = [VulkanBufferView]()
    var images = [VulkanImage]()
    var imageViews = [VulkanImageView]()
    var renderPasses = [VulkanRenderPass]()
    var framebuffers = [VulkanFramebuffer]()
    var descriptorSets = [VkDescriptorSet?]()
    var argumentBuffers = [VulkanArgumentBuffer]()
    
    var waitSemaphores = [ResourceSemaphore]()
    var waitSemaphoreWaitValues = ExpandingBuffer<UInt64>()
    var signalSemaphores = [VkSemaphore?]()
    var signalSemaphoreSignalValues = ExpandingBuffer<UInt64>()
    
    var presentSwapchains = [VulkanSwapChain]()
    
    init(backend: VulkanBackend,
         queue: VulkanDeviceQueue,
         commandInfo: FrameCommandInfo<VulkanBackend>,
         textureUsages: [Texture: TextureUsageProperties],
         resourceMap: FrameResourceMap<VulkanBackend>,
         compactedResourceCommands: [CompactedResourceCommand<VulkanCompactedResourceCommandType>]) {
        self.backend = backend
        self.queue = queue
        self.commandBuffer = queue.allocateCommandBuffer()
        self.commandInfo = commandInfo
        self.textureUsages = textureUsages
        self.resourceMap = resourceMap
        self.compactedResourceCommands = compactedResourceCommands
        
        var beginInfo = VkCommandBufferBeginInfo()
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        beginInfo.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT)
        vkBeginCommandBuffer(self.commandBuffer, &beginInfo)
    }
    
    var gpuStartTime: Double {
        return 0.0
    }
    
    var gpuEndTime: Double {
        return 0.0
    }
    
    func encodeCommands(encoderIndex: Int) {
        let encoderInfo = self.commandInfo.commandEncoders[encoderIndex]
        
        switch encoderInfo.type {
        case .draw:
            guard let renderEncoder = VulkanRenderCommandEncoder(device: backend.device, renderTarget: encoderInfo.renderTargetDescriptor!, commandBufferResources: self, shaderLibrary: backend.shaderLibrary, caches: backend.stateCaches, resourceMap: self.resourceMap) else {
                if _isDebugAssertConfiguration() {
                    print("Warning: skipping passes for encoder \(encoderIndex) since the drawable for the render target could not be retrieved.")
                }
                return
            }
            
            for passRecord in self.commandInfo.passes[encoderInfo.passRange] {
                renderEncoder.executePass(passRecord, resourceCommands: self.compactedResourceCommands, passRenderTarget: (passRecord.pass as! DrawRenderPass).renderTargetDescriptor)
            }
            
            renderEncoder.endEncoding()
            
        case .compute:
            let computeEncoder = VulkanComputeCommandEncoder(device: backend.device, commandBuffer: self, shaderLibrary: backend.shaderLibrary, caches: backend.stateCaches, resourceMap: resourceMap)
            
            for passRecord in self.commandInfo.passes[encoderInfo.passRange] {
                computeEncoder.executePass(passRecord, resourceCommands: self.compactedResourceCommands)
            }
            
            computeEncoder.endEncoding()
            
        case .blit:
            let blitEncoder = VulkanBlitCommandEncoder(device: backend.device, commandBuffer: self, resourceMap: resourceMap)
            
            for passRecord in self.commandInfo.passes[encoderInfo.passRange] {
                blitEncoder.executePass(passRecord, resourceCommands: self.compactedResourceCommands)
            }
            
            blitEncoder.endEncoding()
            
        case .external, .cpu:
            break
        }
    }
    
    func waitForEvent(_ event: VkSemaphore, value: UInt64) {
        // TODO: wait for more fine-grained pipeline stages.
        self.waitSemaphores.append(ResourceSemaphore(vkSemaphore: event, stages: VK_PIPELINE_STAGE_ALL_COMMANDS_BIT))
        self.waitSemaphoreWaitValues.append(value)
    }
    
    func signalEvent(_ event: VkSemaphore, value: UInt64) {
        self.signalSemaphores.append(event)
        self.signalSemaphoreSignalValues.append(value)
    }
    
    func presentSwapchains(resourceRegistry: VulkanTransientResourceRegistry) {
        // Only contains drawables applicable to the render passes in the command buffer...
        self.presentSwapchains.append(contentsOf: resourceRegistry.frameSwapChains)
        // because we reset the list after each command buffer submission.
        resourceRegistry.clearSwapChains()
    }
    
    func commit(onCompletion: @escaping (VulkanCommandBuffer) -> Void) {
        vkEndCommandBuffer(self.commandBuffer)
        
        var submitInfo = VkSubmitInfo()
        submitInfo.commandBufferCount = 1
        
        let waitSemaphores = self.waitSemaphores.map { $0.vkSemaphore as VkSemaphore? }
        let waitDstStageMasks = self.waitSemaphores.map { VkPipelineStageFlags($0.stages) }
        
        // Add a binary semaphore to signal for each presentation swapchain.
        self.signalSemaphores.append(contentsOf: self.presentSwapchains.map { $0.presentationSemaphore })
        self.signalSemaphoreSignalValues.append(repeating: 0, count: self.presentSwapchains.count)
        
        var timelineInfo = VkTimelineSemaphoreSubmitInfo()
        timelineInfo.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
        timelineInfo.pNext = nil
        timelineInfo.waitSemaphoreValueCount = UInt32(self.waitSemaphores.count)
        timelineInfo.pWaitSemaphoreValues = UnsafePointer(self.waitSemaphoreWaitValues.buffer)
        timelineInfo.signalSemaphoreValueCount = UInt32(self.signalSemaphores.count)
        timelineInfo.pSignalSemaphoreValues = UnsafePointer(self.signalSemaphoreSignalValues.buffer)
        
        withUnsafePointer(to: self.commandBuffer as VkCommandBuffer?) { commandBufferPtr in
            submitInfo.pCommandBuffers = commandBufferPtr
            submitInfo.waitSemaphoreCount = UInt32(self.waitSemaphores.count)
            submitInfo.signalSemaphoreCount = UInt32(self.signalSemaphores.count)
            
            waitSemaphores.withUnsafeBufferPointer { waitSemaphores in
                submitInfo.pWaitSemaphores = waitSemaphores.baseAddress
                waitDstStageMasks.withUnsafeBufferPointer { waitDstStageMasks in
                    submitInfo.pWaitDstStageMask = waitDstStageMasks.baseAddress
                    
                    self.signalSemaphores.withUnsafeBufferPointer { signalSemaphores in
                        submitInfo.pSignalSemaphores = signalSemaphores.baseAddress
                        
                        withUnsafePointer(to: timelineInfo) { timelineInfo in
                            submitInfo.pNext = UnsafeRawPointer(timelineInfo)
                            
                            vkQueueSubmit(self.queue.vkQueue, 1, &submitInfo, nil)
                            
                            fatalError("Need to call onCompletion somehow – maybe have a dedicated callback thread? On the other hand, we're just signalling a semaphore anyway, so maybe a callback isn't the right approach.")
                        }
                    }
                }
            }
        }
        
        
        if !self.presentSwapchains.isEmpty {
            for drawable in self.presentSwapchains {
                drawable.submit()
            }
        }
    }
    
    var error: Error? {
        return nil
    }
}


#endif // canImport(Vulkan)
