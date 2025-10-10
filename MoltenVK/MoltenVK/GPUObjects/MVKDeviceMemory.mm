/*
 * MVKDeviceMemory.mm
 *
 * Copyright (c) 2015-2025 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKDeviceMemory.h"
#include "MVKBuffer.h"
#include "MVKImage.h"
#include "MVKQueue.h"
#include "mvk_datatypes.hpp"
#include "MVKFoundation.h"
#include <cstdlib>
#include <stdlib.h>
#include <os/lock.h>

using namespace std;


#pragma mark MVKDeviceMemory

void MVKDeviceMemory::propagateDebugName() {
	setMetalObjectLabel(_mtlHeap, _debugName);
	setMetalObjectLabel(_mtlBuffer, _debugName);
}

VkResult MVKDeviceMemory::map(const VkMemoryMapInfo* pMemoryMapInfo, void** ppData) {
	if ( !isMemoryHostAccessible() ) {
		return reportError(VK_ERROR_MEMORY_MAP_FAILED, "Private GPU-only memory cannot be mapped to host memory.");
	}

	if (isMapped()) {
		return reportError(VK_ERROR_MEMORY_MAP_FAILED, "Memory is already mapped. Call vkUnmapMemory() first.");
	}

	if ( !ensureMTLBuffer() && !ensureHostMemory() ) {
		return reportError(VK_ERROR_OUT_OF_HOST_MEMORY, "Could not allocate %llu bytes of host-accessible device memory.", _allocationSize);
	}

	_mappedRange.offset = pMemoryMapInfo->offset;
	_mappedRange.size = adjustMemorySize(pMemoryMapInfo->size, pMemoryMapInfo->offset);

	*ppData = (void*)((uintptr_t)_pMemory + pMemoryMapInfo->offset);

	// Coherent memory does not require flushing by app, so we must flush now
	// to support Metal textures that actually reside in non-coherent memory.
	if (mvkIsAnyFlagEnabled(_vkMemPropFlags, VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
		pullFromDevice(pMemoryMapInfo->offset, pMemoryMapInfo->size);
	}

	return VK_SUCCESS;
}

VkResult MVKDeviceMemory::unmap(const VkMemoryUnmapInfo* pUnmapMemoryInfo) {
	if ( !isMapped() ) {
		return reportError(VK_ERROR_MEMORY_MAP_FAILED, "Memory is not mapped. Call vkMapMemory() first.");
	}

	// Coherent memory does not require flushing by app, so we must flush now
	// to support Metal textures that actually reside in non-coherent memory.
	if (mvkIsAnyFlagEnabled(_vkMemPropFlags, VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
		flushToDevice(_mappedRange.offset, _mappedRange.size);
	}

	_mappedRange.offset = 0;
	_mappedRange.size = 0;

	return VK_SUCCESS;
}

VkResult MVKDeviceMemory::flushToDevice(VkDeviceSize offset, VkDeviceSize size) {
	VkDeviceSize memSize = adjustMemorySize(size, offset);
	if (memSize == 0 || !isMemoryHostAccessible()) { return VK_SUCCESS; }

#if MVK_MACOS
	if ( !isUnifiedMemoryGPU() && _mtlBuffer && _mtlStorageMode == MTLStorageModeManaged) {
		[_mtlBuffer didModifyRange: NSMakeRange(offset, memSize)];
	}
#endif

	// If we have an MTLHeap object, there's no need to sync memory manually between resources and the buffer.
	if ( !_mtlHeap ) {
		lock_guard<mutex> lock(_rezLock);
		for (auto& img : _imageMemoryBindings) { img->flushToDevice(offset, memSize); }
	}

	return VK_SUCCESS;
}

VkResult MVKDeviceMemory::pullFromDevice(VkDeviceSize offset,
										 VkDeviceSize size,
										 MVKMTLBlitEncoder* pBlitEnc) {
    VkDeviceSize memSize = adjustMemorySize(size, offset);
	if (memSize == 0 || !isMemoryHostAccessible()) { return VK_SUCCESS; }

#if MVK_MACOS
	if ( !isUnifiedMemoryGPU() && pBlitEnc && _mtlBuffer && _mtlStorageMode == MTLStorageModeManaged) {
		if ( !pBlitEnc->mtlCmdBuffer) { pBlitEnc->mtlCmdBuffer = _device->getAnyQueue()->getMTLCommandBuffer(kMVKCommandUseInvalidateMappedMemoryRanges); }
		if ( !pBlitEnc->mtlBlitEncoder) { pBlitEnc->mtlBlitEncoder = [pBlitEnc->mtlCmdBuffer blitCommandEncoder]; }
		[pBlitEnc->mtlBlitEncoder synchronizeResource: _mtlBuffer];
	}
#endif

	// If we have an MTLHeap object, there's no need to sync memory manually between resources and the buffer.
	if ( !_mtlHeap ) {
		lock_guard<mutex> lock(_rezLock);
        for (auto& img : _imageMemoryBindings) { img->pullFromDevice(offset, memSize); }
	}

	return VK_SUCCESS;
}

// If the size parameter is the special constant VK_WHOLE_SIZE, returns the size of memory
// between offset and the end of the buffer, otherwise simply returns size.
VkDeviceSize MVKDeviceMemory::adjustMemorySize(VkDeviceSize size, VkDeviceSize offset) {
	return (size == VK_WHOLE_SIZE) ? (_allocationSize - offset) : size;
}

VkResult MVKDeviceMemory::addBuffer(MVKBuffer* mvkBuff) {
	lock_guard<mutex> lock(_rezLock);

	// If a dedicated alloc, ensure this buffer is the one and only buffer
	// I am dedicated to.
	if (_isDedicated && (_buffers.empty() || _buffers[0] != mvkBuff) ) {
		return reportError(VK_ERROR_OUT_OF_DEVICE_MEMORY, "Could not bind VkBuffer %p to a VkDeviceMemory dedicated to resource %p. A dedicated allocation may only be used with the resource it was dedicated to.", mvkBuff, getDedicatedResource() );
	}

	if (!ensureMTLBuffer() ) {
		return reportError(VK_ERROR_OUT_OF_DEVICE_MEMORY, "Could not bind a VkBuffer to a VkDeviceMemory of size %llu bytes. The maximum memory-aligned size of a VkDeviceMemory that supports a VkBuffer is %llu bytes.", _allocationSize, getMetalFeatures().maxMTLBufferSize);
	}

	// In the dedicated case, we already saved the buffer we're going to use.
	if (!_isDedicated) { _buffers.push_back(mvkBuff); }

	return VK_SUCCESS;
}

// It's valid to destroy a device memory and a buffer/image at the same time without synchronization.
// The device memory destructor wants to reach into the buffer/image, while the buffer/image destructor wants to reach into the device memory.
// So use this global lock that won't be destructed with either of them to avoid problems.
static os_unfair_lock s_device_memory_destruction_lock = OS_UNFAIR_LOCK_INIT;

void MVKDeviceMemory::removeBuffer(MVKDeviceMemory** pMem, MVKBuffer* mvkBuff) {
	os_unfair_lock_lock(&s_device_memory_destruction_lock);
	if (MVKDeviceMemory* mem = *pMem) {
		*pMem = nullptr;
		std::lock_guard<std::mutex> lock(mem->_rezLock);
		mvkRemoveAllOccurances(mem->_buffers, mvkBuff);
	}
	os_unfair_lock_unlock(&s_device_memory_destruction_lock);
}

VkResult MVKDeviceMemory::addImageMemoryBinding(MVKImageMemoryBinding* mvkImg) {
	lock_guard<mutex> lock(_rezLock);

	// If a dedicated alloc, ensure this image is the one and only image
	// I am dedicated to. If my image is aliasable, though, allow other aliasable
	// images to bind to me.
	if (_isDedicated && (_imageMemoryBindings.empty() || !(mvkContains(_imageMemoryBindings, mvkImg) || (_imageMemoryBindings[0]->_image->getIsAliasable() && mvkImg->_image->getIsAliasable()))) ) {
		return reportError(VK_ERROR_OUT_OF_DEVICE_MEMORY, "Could not bind VkImage %p to a VkDeviceMemory dedicated to resource %p. A dedicated allocation may only be used with the resource it was dedicated to.", mvkImg, getDedicatedResource() );
	}

	if (!_isDedicated) { _imageMemoryBindings.push_back(mvkImg); }

	return VK_SUCCESS;
}

void MVKDeviceMemory::removeImageMemoryBinding(MVKDeviceMemory** pMem, MVKImageMemoryBinding* mvkImg) {
	os_unfair_lock_lock(&s_device_memory_destruction_lock);
	if (MVKDeviceMemory* mem = *pMem) {
		*pMem = nullptr;
		std::lock_guard<std::mutex> lock(mem->_rezLock);
		mvkRemoveAllOccurances(mem->_imageMemoryBindings, mvkImg);
	}
	os_unfair_lock_unlock(&s_device_memory_destruction_lock);
}

// Ensures that this instance is backed by a MTLHeap object,
// creating the MTLHeap if needed, and returns whether it was successful.
bool MVKDeviceMemory::ensureMTLHeap() {

	if (_mtlHeap) { return true; }

	// Can't create a MTLHeap on imported memory
	if (_isHostMemImported) { return true; }

	// Don't bother if we don't have placement heaps.
	if (!getMetalFeatures().placementHeaps) { return true; }

	// Can't create MTLHeaps of zero size.
	if (_allocationSize == 0) { return true; }

#if !MVK_OS_SIMULATOR
	if (getPhysicalDevice()->getMTLDeviceCapabilities().isAppleGPU) {
		// MTLHeaps on Apple silicon must use private or shared storage for now.
		if ( !(_mtlStorageMode == MTLStorageModePrivate ||
		       _mtlStorageMode == MTLStorageModeShared) ) { return true; }
	} else
#endif
	{
		// MTLHeaps with immediate-mode GPUs must use private storage for now.
		if (_mtlStorageMode != MTLStorageModePrivate) { return true; }
	}

	MTLHeapDescriptor* heapDesc = [MTLHeapDescriptor new];
	heapDesc.type = MTLHeapTypePlacement;
	heapDesc.storageMode = _mtlStorageMode;
	heapDesc.cpuCacheMode = _mtlCPUCacheMode;
	// For now, use tracked resources. Later, we should probably default
	// to untracked, since Vulkan uses explicit barriers anyway.
	heapDesc.hazardTrackingMode = MTLHazardTrackingModeTracked;
	heapDesc.size = _allocationSize;
	_mtlHeap = [getMTLDevice() newHeapWithDescriptor: heapDesc];	// retained
	[heapDesc release];
	if (!_mtlHeap) { return false; }

	propagateDebugName();

	return true;
}

// Ensures that this instance is backed by a MTLBuffer object,
// creating the MTLBuffer if needed, and returns whether it was successful.
bool MVKDeviceMemory::ensureMTLBuffer() {

	if (_mtlBuffer) { return true; }

	NSUInteger memLen = mvkAlignByteCount(_allocationSize, getMetalFeatures().mtlBufferAlignment);

	if (memLen > getMetalFeatures().maxMTLBufferSize) { return false; }

	id<MTLBuffer> buf;
	// If host memory was already allocated, it is copied into the new MTLBuffer, and then released.
	if (_mtlHeap) {
		buf = [_mtlHeap newBufferWithLength: memLen options: getMTLResourceOptions() offset: 0];	// retained
		if (_pHostMemory) {
			memcpy(buf.contents, _pHostMemory, memLen);
			freeHostMemory();
		}
		[buf makeAliasable];
	} else if (_pHostMemory) {
		auto rezOpts = getMTLResourceOptions();
		if (_isHostMemImported) {
			buf = [getMTLDevice() newBufferWithBytesNoCopy: _pHostMemory length: memLen options: rezOpts deallocator: nil];	// retained
		} else {
			buf = [getMTLDevice() newBufferWithBytes: _pHostMemory length: memLen options: rezOpts];     // retained
		}
		freeHostMemory();
	} else {
		buf = [getMTLDevice() newBufferWithLength: memLen options: getMTLResourceOptions()];     // retained
	}
	if (!buf) { return false; }
	_device->makeResident(buf);
	_device->getLiveResources().add(buf);
	_pMemory = isMemoryHostAccessible() ? buf.contents : nullptr;
	_mtlBuffer = buf;

	propagateDebugName();

	return true;
}

// Ensures that host-accessible memory is available, allocating it if necessary.
bool MVKDeviceMemory::ensureHostMemory() {

	if (_pMemory) { return true; }

	if ( !_pHostMemory) {
		size_t memAlign = getMetalFeatures().mtlBufferAlignment;
		NSUInteger memLen = mvkAlignByteCount(_allocationSize, memAlign);
		int err = posix_memalign(&_pHostMemory, memAlign, memLen);
		if (err) { return false; }
	}

	_pMemory = _pHostMemory;

	return true;
}

void MVKDeviceMemory::freeHostMemory() {
	if ( !_isHostMemImported ) { free(_pHostMemory); }
	_pHostMemory = nullptr;
}

MVKResource* MVKDeviceMemory::getDedicatedResource() {
	MVKAssert(_isDedicated, "This method should only be called on dedicated allocations!");
	return _buffers.empty() ? (MVKResource*)_imageMemoryBindings[0] : (MVKResource*)_buffers[0];
}

MVKDeviceMemory::MVKDeviceMemory(MVKDevice* device,
								 const VkMemoryAllocateInfo* pAllocateInfo,
								 const VkAllocationCallbacks* pAllocator) : MVKVulkanAPIDeviceObject(device) {
	// Set Metal memory parameters
	_vkMemAllocFlags = 0;
	_vkMemPropFlags = getDeviceMemoryProperties().memoryTypes[pAllocateInfo->memoryTypeIndex].propertyFlags;
	_mtlStorageMode = getPhysicalDevice()->getMTLStorageModeFromVkMemoryPropertyFlags(_vkMemPropFlags);
	_mtlCPUCacheMode = mvkMTLCPUCacheModeFromVkMemoryPropertyFlags(_vkMemPropFlags);

	_allocationSize = pAllocateInfo->allocationSize;

	bool willExportMTLBuffer = false;
	MVKImage* dedicatedImage = nullptr;
	VkBuffer dedicatedBuffer = VK_NULL_HANDLE;
	for (const auto* next = (const VkBaseInStructure*)pAllocateInfo->pNext; next; next = next->pNext) {
		switch (next->sType) {
			case VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO: {
				auto* pDedicatedInfo = (VkMemoryDedicatedAllocateInfo*)next;
				dedicatedImage = reinterpret_cast<MVKImage*>(pDedicatedInfo->image);
				dedicatedBuffer = pDedicatedInfo->buffer;
				_isDedicated = dedicatedImage || dedicatedBuffer;
				break;
			}
			case VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT: {
				auto* pMemHostPtrInfo = (VkImportMemoryHostPointerInfoEXT*)next;
				if (mvkIsAnyFlagEnabled(_vkMemPropFlags, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
					switch (pMemHostPtrInfo->handleType) {
						case VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT:
						case VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_MAPPED_FOREIGN_MEMORY_BIT_EXT:
							_pHostMemory = pMemHostPtrInfo->pHostPointer;
							_isHostMemImported = true;
							break;
						default:
							break;
					}
				} else {
					setConfigurationResult(reportError(VK_ERROR_INVALID_EXTERNAL_HANDLE_KHR, "vkAllocateMemory(): Imported memory must be host-visible."));
				}
				break;
			}
			case VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO: {
				auto* pExpMemInfo = (VkExportMemoryAllocateInfo*)next;
				_externalMemoryHandleType = pExpMemInfo->handleTypes;
				break;
			}
			case VK_STRUCTURE_TYPE_IMPORT_METAL_BUFFER_INFO_EXT: {
				// Setting Metal objects directly will override Vulkan settings.
				// It is responsibility of app to ensure these are consistent. Not doing so results in undefined behavior.
				const auto* pMTLBuffInfo = (VkImportMetalBufferInfoEXT*)next;
				if (_mtlBuffer)
					_device->getLiveResources().remove(_mtlBuffer);
				[_mtlBuffer release];							// guard against dups
				_device->getLiveResources().add(pMTLBuffInfo->mtlBuffer);
				_mtlBuffer = [pMTLBuffInfo->mtlBuffer retain];	// retained
				_mtlStorageMode = _mtlBuffer.storageMode;
				_mtlCPUCacheMode = _mtlBuffer.cpuCacheMode;
				_allocationSize = _mtlBuffer.length;
				break;
			}
			case VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT: {
				const auto* pExportInfo = (VkExportMetalObjectCreateInfoEXT*)next;
				willExportMTLBuffer = pExportInfo->exportObjectType == VK_EXPORT_METAL_OBJECT_TYPE_METAL_BUFFER_BIT_EXT;
			}
			case VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO: {
				auto* pMemAllocFlagsInfo = (VkMemoryAllocateFlagsInfo*)next;
				_vkMemAllocFlags = pMemAllocFlagsInfo->flags;
				break;
			}
			case VK_STRUCTURE_TYPE_IMPORT_MEMORY_METAL_HANDLE_INFO_EXT: {
				const auto* pImportInfo = (VkImportMemoryMetalHandleInfoEXT*)next;
				_externalMemoryHandleType = pImportInfo->handleType;
				// This handle type will only be exposed to the user if we actually are supporting heaps
				if (pImportInfo->handleType & VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT) {
					[_mtlHeap release];
					_mtlHeap = [((id<MTLHeap>)pImportInfo->handle) retain];
					_mtlStorageMode = _mtlHeap.storageMode;
					_mtlCPUCacheMode = _mtlHeap.cpuCacheMode;
					_allocationSize = _mtlHeap.size;
				}
				else if (pImportInfo->handleType & VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT) {
					if (_mtlBuffer)
						_device->getLiveResources().remove(_mtlBuffer);
					[_mtlBuffer release];							// guard against dups
					_device->getLiveResources().add(((id<MTLBuffer>)pImportInfo->handle));
					_mtlBuffer = [((id<MTLBuffer>)pImportInfo->handle) retain];	// retained
					_mtlStorageMode = _mtlBuffer.storageMode;
					_mtlCPUCacheMode = _mtlBuffer.cpuCacheMode;
					_allocationSize = _mtlBuffer.length;
					_pMemory = isMemoryHostAccessible() ? _mtlBuffer.contents : nullptr;
				} else if (pImportInfo->handleType & VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT) {
					[_mtlTexture release];
					_mtlTexture = [((id<MTLTexture>)pImportInfo->handle) retain];
				}
			}
			default:
				break;
		}
	}

	initExternalMemory(dedicatedImage);	// After setting _isDedicated

	// "Dedicated" means this memory can only be used for this image or buffer.
	if (dedicatedImage) {
#if MVK_MACOS
		if (isMemoryHostCoherent() ) {
			if (!isAppleGPU() && !dedicatedImage->_isLinear) {
				setConfigurationResult(reportError(VK_ERROR_OUT_OF_DEVICE_MEMORY, "vkAllocateMemory(): Host-coherent VkDeviceMemory objects cannot be associated with optimal-tiling images."));
			} else if (!ensureMTLBuffer()) {
				// Nonetheless, we need a buffer to be able to map the memory at will.
				setConfigurationResult(reportError(VK_ERROR_OUT_OF_DEVICE_MEMORY, "vkAllocateMemory(): Could not allocate a host-coherent VkDeviceMemory of size %llu bytes. The maximum memory-aligned size of a host-coherent VkDeviceMemory is %llu bytes.", _allocationSize, getMetalFeatures().maxMTLBufferSize));
			}
		}
#endif
        for (auto& memoryBinding : dedicatedImage->_memoryBindings) {
            _imageMemoryBindings.push_back(memoryBinding);
        }
		return;
	}

	if (dedicatedBuffer) {
		_buffers.push_back((MVKBuffer*)dedicatedBuffer);
	}

	// If we can, create a MTLHeap. This should happen before creating the buffer, allowing us to map its contents.
	if (!ensureMTLHeap()) {
		setConfigurationResult(reportError(VK_ERROR_OUT_OF_DEVICE_MEMORY, "vkAllocateMemory(): Could not allocate VkDeviceMemory of size %llu bytes.", _allocationSize));
		return;
	}

	// If memory needs to be coherent it must reside in a MTLBuffer, since an open-ended map() must work.
	// If memory was imported, a MTLBuffer must be created on it.
	// Or if a MTLBuffer will be exported, ensure it exists.
	if ((isMemoryHostCoherent() || _isHostMemImported || willExportMTLBuffer) && !ensureMTLBuffer() ) {
		setConfigurationResult(reportError(VK_ERROR_OUT_OF_DEVICE_MEMORY, "vkAllocateMemory(): Could not allocate a host-coherent or exportable VkDeviceMemory of size %llu bytes. The maximum memory-aligned size of a host-coherent VkDeviceMemory is %llu bytes.", _allocationSize, getMetalFeatures().maxMTLBufferSize));
	}
}

void MVKDeviceMemory::initExternalMemory(MVKImage* dedicatedImage) {
	if ( !_externalMemoryHandleType ) { return; }
	
	if ( !mvkIsOnlyAnyFlagEnabled(_externalMemoryHandleType, VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT | VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT | VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkAllocateMemory(): Only external memory handle types VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT, VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT or VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT are supported."));
	}

	bool requiresDedicated = false;
	if (mvkIsAnyFlagEnabled(_externalMemoryHandleType, VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT)) {
		auto& xmProps = getPhysicalDevice()->getExternalBufferProperties(VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT);
		requiresDedicated = requiresDedicated || mvkIsAnyFlagEnabled(xmProps.externalMemoryFeatures, VK_EXTERNAL_MEMORY_FEATURE_DEDICATED_ONLY_BIT);
		
		// Make sure allocation happens at creation time since we may need to export the memory before usage
		ensureMTLHeap();
	}
	if (mvkIsAnyFlagEnabled(_externalMemoryHandleType, VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT)) {
		auto& xmProps = getPhysicalDevice()->getExternalBufferProperties(VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT);
		requiresDedicated = requiresDedicated || mvkIsAnyFlagEnabled(xmProps.externalMemoryFeatures, VK_EXTERNAL_MEMORY_FEATURE_DEDICATED_ONLY_BIT);

		// Make sure allocation happens at creation time since we may need to export the memory before usage
		ensureMTLBuffer();
	}
	if (mvkIsAnyFlagEnabled(_externalMemoryHandleType, VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT)) {
		// Textures require a dedicated allocation according to the spec
		if (dedicatedImage == nullptr) {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkAllocateMemory(): External memory requires a dedicated VkImage when a export operation will be done."));
			return;
		}
		auto& xmProps = getPhysicalDevice()->getExternalImageProperties(dedicatedImage->getVkFormat(), VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT);
		// Not all texture formats allow to exporting. Vulkan formats that are emulated through the use of multiple MTLTextures
		// cannot be exported as a single MTLTexture, and therefore will have exporting forbidden.
		if (!(xmProps.externalMemoryFeatures & VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT)) {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkAllocateMemory(): VkImage's VkFormat does not allow exports."));
		} else {
			// Make sure allocation happens at creation time since we may need to export the memory before usage
			_mtlTexture = [dedicatedImage->getMTLTexture() retain];
		}
		requiresDedicated = true;
	}
	if (requiresDedicated && !_isDedicated) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkAllocateMemory(): External memory requires a dedicated VkBuffer or VkImage."));
	}
}

MVKDeviceMemory::~MVKDeviceMemory() {
	// Unbind any resources that are using me.
	// Manually null the binding parameter to prevent them from trying to remove themselves from the array.
	// This will leave texture buffer pointers dangling, but according to Vulkan, those are not supposed to be used again anyways.
	os_unfair_lock_lock(&s_device_memory_destruction_lock);
	for (auto& buf : _buffers)             { buf->_deviceMemory = nullptr; }
	for (auto& img : _imageMemoryBindings) { img->_deviceMemory = nullptr; }
	os_unfair_lock_unlock(&s_device_memory_destruction_lock);

	if (_externalMemoryHandleType & VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT) {
		[_mtlTexture release];
		_mtlTexture = nil;
	} else if (id<MTLBuffer> buf = _mtlBuffer) {
		_mtlBuffer = nil;
		_device->removeResidency(buf);
		_device->getLiveResources().remove(buf);
		[buf release];
	}

	[_mtlHeap release];
	_mtlHeap = nil;

	freeHostMemory();
}
