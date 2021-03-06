// azul
// Copyright © 2016-2017 Ken Arroyo Ohori
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

import Metal
import MetalKit

extension float4x4 {
    static let identity = matrix_identity_float4x4
}

extension CGSize {
  var aspectRatio : CGFloat {
    return width / height
  }
}

struct Vertex {
  let position: float3
}

struct GPUEdgeBuffer {
    let colour: float4
    let buffer: MTLBuffer

    init(ref : UnsafePointer<EdgeBufferRef>, device: MTLDevice) {
        colour = ref.pointee.colour
        buffer = device.makeBuffer(ref: ref)
    }
}

struct GPUTriangleBuffer {
    let colour: float4
    let type : String
    let buffer: MTLBuffer

    init(ref : UnsafePointer<TriangleBufferRef>, device: MTLDevice) {
        colour = ref.pointee.colour
        type = String(cString: ref.pointee.type)
        buffer = device.makeBuffer(ref: ref)
    }
}

extension float4 {

  var xyz: float3 {
    @inline(__always)
    get {
      return .init(x: x, y: y, z: z)
    }
  }
}


@objc class MetalView: MTKView {
  
  var controller: Controller?
  var dataManager: DataManager?
  
  let commandQueue: MTLCommandQueue
  let litRenderPipelineState: MTLRenderPipelineState
  let unlitRenderPipelineState: MTLRenderPipelineState
  let depthStencilState: MTLDepthStencilState
  
    var triangleBuffers: [GPUTriangleBuffer] = []
    var edgeBuffers: [GPUEdgeBuffer] = []
  var boundingBoxBuffer: MTLBuffer?
  
  var viewEdges: Bool = false
  var viewBoundingBox: Bool = false
  
  @objc var multipleSelection: Bool = false
  
  var constants = Constants()
  
  var eye = float3(0.0, 0.0, 0.0)
  var centre = float3(0.0, 0.0, -1.0)
  var fieldOfView: Float = 1.047197551196598
  
  @objc var scaling = matrix_identity_float4x4
  @objc var rotation = matrix_identity_float4x4
  @objc var translation = matrix_identity_float4x4

  @objc var modelMatrix = matrix_identity_float4x4
  @objc var viewMatrix = matrix_identity_float4x4
  @objc var projectionMatrix = matrix_identity_float4x4
  
  override init(frame frameRect: CGRect, device: MTLDevice?) {
    Swift.print("MetalView.init(CGRect, MTLDevice)")
    // Command queue
    commandQueue = device!.makeCommandQueue()!

    // Render pipeline
    let library = device!.makeDefaultLibrary()!
    let litVertexFunction = library.makeFunction(name: "vertexLit")
    let unlitVertexFunction = library.makeFunction(name: "vertexUnlit")
    let fragmentFunction = library.makeFunction(name: "fragmentLit")
    let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
    renderPipelineDescriptor.vertexFunction = litVertexFunction
    renderPipelineDescriptor.fragmentFunction = fragmentFunction
    renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
    renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    renderPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
    renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    renderPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    renderPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
    do {
        litRenderPipelineState = try device!.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
    } catch {
        fatalError("Unable to compile lit render pipeline state")
    }
    renderPipelineDescriptor.vertexFunction = unlitVertexFunction
    renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
    do {
        unlitRenderPipelineState = try device!.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
    } catch {
        fatalError("Unable to compile unlit render pipeline state")
    }

    // Depth stencil
    let depthSencilDescriptor = MTLDepthStencilDescriptor()
    depthSencilDescriptor.depthCompareFunction = .less
    depthSencilDescriptor.isDepthWriteEnabled = true
    depthStencilState = device!.makeDepthStencilState(descriptor: depthSencilDescriptor)!

    // Matrices
    translation = .init(translation: centre)
    // translation rotation scaling
    modelMatrix = (translation * rotation) * scaling
    viewMatrix = .init(eye: eye, center: centre)
    constants.modelMatrix = modelMatrix
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    constants.modelMatrixInverseTransposed = matrix_upper_left_3x3(matrix: modelMatrix).inverse.transpose
    constants.viewMatrixInverse = viewMatrix.inverse

    super.init(frame: frameRect, device: device)
    
    // View
    clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0)
    colorPixelFormat = .bgra8Unorm
    depthStencilPixelFormat = .depth32Float
    
    projectionMatrix = .init(fov: fieldOfView, size: bounds.size)

    // Allow dragging
    registerForDraggedTypes([.fileURL])
    
    self.isPaused = true
    self.enableSetNeedsDisplay = true
  }
  
  required init(coder: NSCoder) {
    Swift.print("MetalView.init(NSCoder)")
//    super.init(coder: coder)
    fatalError()
  }
  
  override var acceptsFirstResponder: Bool {
    return true
  }

    var objectToCamera : float4x4 {
        return viewMatrix * modelMatrix
    }
  
  override func draw(_ dirtyRect: NSRect) {
//    Swift.print("MetalView.draw(NSRect)")
    
    if dirtyRect.width == 0 {
      return
    }
    
    let commandBuffer = commandQueue.makeCommandBuffer()!
    let renderPassDescriptor = currentRenderPassDescriptor!
    let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
    
    renderEncoder.setFrontFacing(.counterClockwise)
    renderEncoder.setDepthStencilState(depthStencilState)
    renderEncoder.setRenderPipelineState(litRenderPipelineState)

    for triangleBuffer in triangleBuffers {
      if triangleBuffer.colour.w == 1.0 {
        renderEncoder.setVertexBuffer(triangleBuffer.buffer, offset:0, index:0)
        constants.colour = triangleBuffer.colour
        renderEncoder.setVertexBytes(&constants, length: MemoryLayout<Constants>.size, index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangleBuffer.buffer.length/MemoryLayout<VertexWithNormal>.size)
      }
    }

    
    for triangleBuffer in triangleBuffers {
      if triangleBuffer.colour.w != 1.0 {
        renderEncoder.setVertexBuffer(triangleBuffer.buffer, offset:0, index:0)
        constants.colour = triangleBuffer.colour
        renderEncoder.setVertexBytes(&constants, length: MemoryLayout<Constants>.size, index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangleBuffer.buffer.length/MemoryLayout<VertexWithNormal>.size)
      }
    }
    
    renderEncoder.setRenderPipelineState(unlitRenderPipelineState)
    
    if viewEdges {
      for edgeBuffer in edgeBuffers {
        renderEncoder.setVertexBuffer(edgeBuffer.buffer, offset:0, index:0)
        constants.colour = edgeBuffer.colour
        renderEncoder.setVertexBytes(&constants, length: MemoryLayout<Constants>.size, index: 1)
        renderEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeBuffer.buffer.length/MemoryLayout<Vertex>.size)
      }
    }
    
    if viewBoundingBox && boundingBoxBuffer != nil {
      renderEncoder.setVertexBuffer(boundingBoxBuffer, offset:0, index:0)
      constants.colour = float4(0.0, 0.0, 0.0, 1.0)
      renderEncoder.setVertexBytes(&constants, length: MemoryLayout<Constants>.size, index: 1)
      renderEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: boundingBoxBuffer!.length/MemoryLayout<Vertex>.size)
    }
   
    renderEncoder.endEncoding()
    let drawable = currentDrawable!
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
  
  override func setFrameSize(_ newSize: NSSize) {
//    Swift.print("MetalView.setFrameSize(NSSize)")
    super.setFrameSize(newSize)
    projectionMatrix = .init(fov: fieldOfView, size: bounds.size)
    
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    needsDisplay = true
    controller!.progressIndicator!.setFrameSize(NSSize(width: self.frame.width/4, height: 12))
    controller!.statusTextField!.setFrameOrigin(NSPoint(x: self.frame.width/4, y: 0))
    controller!.statusTextField!.setFrameSize(NSSize(width: 3*self.frame.width/4, height: 16))
  }

    @objc func depthAtCentre() -> Float {
        return dataManager!.depthAtCentre(viewMatrix: viewMatrix,
                                          modelMatrix: modelMatrix)
    }

  override func scrollWheel(with event: NSEvent) {
    //    Swift.print("MetalView.scrollWheel()")
    //    Swift.print("Scrolled X: \(event.scrollingDeltaX) Y: \(event.scrollingDeltaY)")

    // Motion according to trackpad
    let scrollingSensitivity: Float = 0.003*(fieldOfView/(3.141519/4.0))
    let motionInCameraCoordinates = float3(Float(event.scrollingDeltaX),
                                           -Float(event.scrollingDeltaY),
                                           0.0) * scrollingSensitivity

    var cameraToObject = matrix_upper_left_3x3(matrix: viewMatrix * modelMatrix).inverse
    let motionInObjectCoordinates = (cameraToObject * motionInCameraCoordinates)
    scaling = scaling + motionInObjectCoordinates
    modelMatrix = (translation * rotation) * scaling

    // Correct motion so that the point of rotation remains at the same depth as the data
    cameraToObject = matrix_upper_left_3x3(matrix: viewMatrix * modelMatrix).inverse
    let depthOffset = 1.0+depthAtCentre()
    //    Swift.print("Depth offset: \(depthOffset)")
    let depthOffsetInCameraCoordinates = float3(0.0, 0.0, -depthOffset)
    let depthOffsetInObjectCoordinates = cameraToObject * depthOffsetInCameraCoordinates
    scaling = scaling + depthOffsetInObjectCoordinates
    modelMatrix = (translation * rotation) * scaling

    // Put model matrix in arrays and render
    constants.modelMatrix = modelMatrix
    
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    constants.modelMatrixInverseTransposed = matrix_upper_left_3x3(matrix: modelMatrix).inverse.transpose
    constants.viewMatrixInverse = viewMatrix.inverse
    needsDisplay = true
  }
  
  override func magnify(with event: NSEvent) {
    //    Swift.print("MetalView.magnify()")
    //    Swift.print("Pinched: \(event.magnification)")
    let magnification: Float = 1.0+Float(event.magnification)
    fieldOfView = 2.0*atanf(tanf(0.5*fieldOfView)/magnification)
    //    Swift.print("Field of view: \(fieldOfView)")
    projectionMatrix = .init(fov: fieldOfView, size: bounds.size)
    
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    needsDisplay = true
  }
  
  override func rotate(with event: NSEvent) {
    //    Swift.print("MetalView.rotate()")
    //    Swift.print("Rotation angle: \(event.rotation)")
    
    let axisInCameraCoordinates = float3(0.0, 0.0, 1.0)
    let cameraToObject = matrix_upper_left_3x3(matrix: viewMatrix * modelMatrix).inverse
    let axisInObjectCoordinates = cameraToObject * axisInCameraCoordinates
    rotation = rotation.rotate(around: axisInObjectCoordinates,
                                                     angle: 3.14159*event.rotation/180.0)

    modelMatrix = (translation * rotation) * scaling
    
    constants.modelMatrix = modelMatrix
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    constants.modelMatrixInverseTransposed = matrix_upper_left_3x3(matrix: modelMatrix).inverse.transpose
    constants.viewMatrixInverse = viewMatrix.inverse
    needsDisplay = true
  }
  
  override func mouseDragged(with event: NSEvent) {
    let point = window!.mouseLocationOutsideOfEventStream
    //    Swift.print("mouseDragged()")
    let viewFrameInWindowCoordinates = convert(bounds, to: nil)
    
    // Compute the current and last mouse positions and their depth on a sphere
    let currentX: Float = Float(-1.0 + 2.0*(point.x-viewFrameInWindowCoordinates.origin.x) / bounds.size.width)
    let currentY: Float = Float(-1.0 + 2.0*(point.y-viewFrameInWindowCoordinates.origin.y) / bounds.size.height)
    let currentZ: Float = sqrt(1.0 - (currentX*currentX+currentY*currentY))
    let currentPosition = normalize(float3(currentX, currentY, currentZ))
    //    Swift.print("Current position \(currentPosition)")
    let lastX: Float = Float(-1.0 + 2.0*((point.x-viewFrameInWindowCoordinates.origin.x)-event.deltaX) / bounds.size.width)
    let lastY: Float = Float(-1.0 + 2.0*((point.y-viewFrameInWindowCoordinates.origin.y)+event.deltaY) / bounds.size.height)
    let lastZ: Float = sqrt(1.0 - (lastX*lastX+lastY*lastY))
    let lastPosition = normalize(float3(lastX, lastY, lastZ))
    //    Swift.print("Last position \(lastPosition)")
    if currentPosition == lastPosition {
      return
    }
    
    // Compute the angle between the two and use it to move in camera space
    let angle = acos(dot(lastPosition, currentPosition))
    if !angle.isNaN && angle > 0.0 {
      let axisInCameraCoordinates = cross(lastPosition, currentPosition)
      let cameraToObject = matrix_upper_left_3x3(matrix: viewMatrix * modelMatrix).inverse
      let axisInObjectCoordinates = cameraToObject * axisInCameraCoordinates
        rotation = rotation.rotate(around: axisInObjectCoordinates,
                                                         angle: angle)

      modelMatrix = (translation * rotation) * scaling
      
      constants.modelMatrix = modelMatrix
      constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
      constants.modelMatrixInverseTransposed = matrix_upper_left_3x3(matrix: modelMatrix).inverse.transpose
      constants.viewMatrixInverse = viewMatrix.inverse
      needsDisplay = true
    } else {
      //      Swift.print("NaN!")
    }
  }
  
  override func rightMouseDragged(with event: NSEvent) {
    //    Swift.print("MetalView.rightMouseDragged()")
    //    Swift.print("Delta: (\(event.deltaX), \(event.deltaY))")
    
    let zoomSensitivity: Float = 0.005
    let magnification: Float = 1.0+zoomSensitivity*Float(event.deltaY)
    fieldOfView = 2.0*atanf(tanf(0.5*fieldOfView)/magnification)
    //    Swift.print("Field of view: \(fieldOfView)")
    projectionMatrix = .init(fov: fieldOfView, size: bounds.size)
    
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    needsDisplay = true
  }
  
  override func mouseUp(with event: NSEvent) {
    //    Swift.print("MetalView.mouseUp()")
    switch event.clickCount {
    case 1:
      click(with: event)
      break
    case 2:
      doubleClick(with: event)
    default:
      break
    }
  }
  
  func click(with event: NSEvent) {
    Swift.print("MetalView.click()")
    let startTime = CACurrentMediaTime()
    dataManager!.click()
    Swift.print("Click computed in \(CACurrentMediaTime()-startTime) seconds.")
  }
  
  func doubleClick(with event: NSEvent) {
        Swift.print("MetalView.doubleClick()")
    let point = window!.mouseLocationOutsideOfEventStream


    let b = convert(event.locationInWindow, to: nil)

    //    Swift.print("Mouse location X: \(window!.mouseLocationOutsideOfEventStream.x), Y: \(window!.mouseLocationOutsideOfEventStream.y)")
    let viewFrameInWindowCoordinates = convert(bounds, to: nil)

    //    Swift.print("View X: \(viewFrameInWindowCoordinates.origin.x), Y: \(viewFrameInWindowCoordinates.origin.y)")
    let translated = b - viewFrameInWindowCoordinates.origin
    Swift.print(viewFrameInWindowCoordinates, b, translated)
    // Compute the current mouse position
    let currentX: Float = Float(-1.0 + 2.0*(point.x-viewFrameInWindowCoordinates.origin.x) / bounds.size.width)
    let currentY: Float = Float(-1.0 + 2.0*(point.y-viewFrameInWindowCoordinates.origin.y) / bounds.size.height)
        Swift.print("currentX: \(currentX), currentY: \(currentY)")

    // Compute two points on the ray represented by the mouse position at the near and far planes
    let mvpInverse = (projectionMatrix * (viewMatrix * modelMatrix)).inverse
    let pointOnNearPlaneInProjectionCoordinates = float4(currentX, currentY, -1.0, 1.0)
    let pointOnNearPlaneInObjectCoordinates = (mvpInverse * pointOnNearPlaneInProjectionCoordinates)
    let pointOnFarPlaneInProjectionCoordinates = float4(currentX, currentY, 1.0, 1.0)
    let pointOnFarPlaneInObjectCoordinates = (mvpInverse * pointOnFarPlaneInProjectionCoordinates)
    
    // Interpolate the points to obtain the intersection with the data plane z = 0
    let alpha: Float = -(pointOnFarPlaneInObjectCoordinates.z/pointOnFarPlaneInObjectCoordinates.w)/((pointOnNearPlaneInObjectCoordinates.z/pointOnNearPlaneInObjectCoordinates.w)-(pointOnFarPlaneInObjectCoordinates.z/pointOnFarPlaneInObjectCoordinates.w))
    let clickedPointInObjectCoordinates = float4(alpha*(pointOnNearPlaneInObjectCoordinates.x/pointOnNearPlaneInObjectCoordinates.w)+(1.0-alpha)*(pointOnFarPlaneInObjectCoordinates.x/pointOnFarPlaneInObjectCoordinates.w),
                                                 alpha*(pointOnNearPlaneInObjectCoordinates.y/pointOnNearPlaneInObjectCoordinates.w)+(1.0-alpha)*(pointOnFarPlaneInObjectCoordinates.y/pointOnFarPlaneInObjectCoordinates.w),
                                                 0.0, 1.0)
    
    // Use the intersection to compute the shift in the view space
    let objectToCamera = viewMatrix * modelMatrix
    let clickedPointInCameraCoordinates = objectToCamera * clickedPointInObjectCoordinates
    
    // Compute shift in object space
    let shiftInCameraCoordinates = float3(-clickedPointInCameraCoordinates.x, -clickedPointInCameraCoordinates.y, 0.0)
    var cameraToObject = matrix_upper_left_3x3(matrix: objectToCamera).inverse
    let shiftInObjectCoordinates = cameraToObject * shiftInCameraCoordinates
    scaling = scaling + shiftInObjectCoordinates
    modelMatrix = (translation * rotation) * scaling
    
    // Correct shift so that the point of rotation remains at the same depth as the data
    cameraToObject = matrix_upper_left_3x3(matrix: (viewMatrix * modelMatrix)).inverse
    let depthOffset = 1.0+depthAtCentre()
    let depthOffsetInCameraCoordinates = float3(0.0, 0.0, -depthOffset)
    let depthOffsetInObjectCoordinates = cameraToObject * depthOffsetInCameraCoordinates
    scaling = scaling + depthOffsetInObjectCoordinates
    modelMatrix = (translation * rotation) * scaling
    
    // Put model matrix in arrays and render
    constants.modelMatrix = modelMatrix
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    constants.modelMatrixInverseTransposed = matrix_upper_left_3x3(matrix: modelMatrix).inverse.transpose
    needsDisplay = true
  }
  
  func goHome() {
    
    fieldOfView = 1.047197551196598
    
    scaling = .identity
    rotation = .identity
    translation = .init(translation: centre)
    modelMatrix = (translation * rotation) * scaling
    viewMatrix = .init(eye: eye, center: centre)
    projectionMatrix = .init(fov: fieldOfView, size: bounds.size)

    constants.modelMatrix = modelMatrix
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    constants.modelMatrixInverseTransposed = matrix_upper_left_3x3(matrix: modelMatrix).inverse.transpose
    constants.viewMatrixInverse = viewMatrix.inverse
    needsDisplay = true
  }
  
  func new() {
    
    triangleBuffers.removeAll()
    edgeBuffers.removeAll()
    
    fieldOfView = 1.047197551196598
    
    scaling = .identity
    rotation = .identity
    translation = .init(translation: centre)
    modelMatrix = (translation * rotation) * scaling
    viewMatrix = .init(eye: eye, center: centre)
    projectionMatrix = .init(fov: fieldOfView, size: bounds.size)
    
    constants.modelMatrix = modelMatrix
    constants.modelViewProjectionMatrix = projectionMatrix * (viewMatrix * modelMatrix)
    constants.modelMatrixInverseTransposed = matrix_upper_left_3x3(matrix: modelMatrix).inverse.transpose
    constants.viewMatrixInverse = viewMatrix.inverse
    
    needsDisplay = true
  }
  
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptedFileTypes: Set = ["gml", "xml", "json", "obj", "off", "poly"]
        if let urls = sender.urls() {
            for url in urls {
                if acceptedFileTypes.contains(url.pathExtension) {
                    return .copy
                }
            }
        }
        return []
    }
  
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let urls = sender.urls() {
      controller!.loadData(from: urls)
    }
    return true
  }
  
  override func keyDown(with event: NSEvent) {
    //    Swift.print(event.charactersIgnoringModifiers![(event.charactersIgnoringModifiers?.startIndex)!])
    
    switch event.charactersIgnoringModifiers![(event.charactersIgnoringModifiers?.startIndex)!] {
    case "b":
      controller!.toggleViewBoundingBox(controller!.toggleViewBoundingBoxMenuItem)
    case "c":
      controller!.copyObjectId(controller!.copyObjectIdMenuItem)
    case "e":
      controller!.toggleViewEdges(controller!.toggleViewEdgesMenuItem)
    case "f":
      controller!.focusOnSearchBar(controller!.findMenuItem)
    case "l":
      controller!.loadViewParameters(controller!.loadViewParametersMenuItem)
    case "h":
      controller!.goHome(controller!.goHomeMenuItem)
    case "n":
      controller!.new(controller!.newFileMenuItem)
    case "o":
      controller!.openFile(controller!.openFileMenuItem)
    case "s":
      controller!.saveViewParameters(controller!.saveViewParametersMenuItem)
    default:
      break
    }
  }
  
  override func flagsChanged(with event: NSEvent) {
    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
      multipleSelection = true
    } else {
      multipleSelection = false
    }
  }
}
