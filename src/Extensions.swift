//
//  Extensions.swift
//  azul
//
//  Created by Adam Nemecek on 10/15/17.
//  Copyright © 2017 Ken Arroyo Ohori. All rights reserved.
//

import MetalKit

extension float2 {
    init(cgPoint : CGPoint) {
        self.init(x: Float(cgPoint.x), y: Float(cgPoint.y))
    }
}

extension NSPoint {
    static func -(lhs: NSPoint, rhs: NSPoint) -> NSPoint {
        return .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
}


//extension MTKView {
//    func location(for event : NSEvent) -> float2 {
//        let point = convert(event.locationInWindow, to: nil)
//        let m = window!.mouseLocationOutsideOfEventStream
//        assert(point == m)
//
//        return .init(cgPoint: point)
//    }
//
//    func mouseLocation() -> float2 {
//        let point = window!.mouseLocationOutsideOfEventStream
//
//    }
//}


