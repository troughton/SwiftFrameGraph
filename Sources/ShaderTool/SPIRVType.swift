//
//  SPIRVType.swift
//  
//
//  Created by Thomas Roughton on 24/11/19.
//

import SPIRV_Cross

struct SPIRVStructMember : Hashable {
    var name : String
    var type : SPIRVType
}

indirect enum SPIRVType : Hashable {
    case void
    case bool
    case int8
    case uint8
    case int16
    case uint16
    case int32
    case uint32
    case int64
    case uint64
    case half
    case float
    case double
    case atomicCounter
    
    case vector(element: SPIRVType, length: Int)
    case packedVector(element: SPIRVType, length: Int)
    case matrix(element: SPIRVType, rows: Int, columns: Int)
    case array(element: SPIRVType, length: Int)
    case `struct`(name: String, members: [SPIRVStructMember])
    
    case buffer
    case texture
    case sampler
    
    init?(baseType: spvc_basetype) {
        switch baseType {
        case SPVC_BASETYPE_VOID:
            self = .void
        case SPVC_BASETYPE_BOOLEAN:
            self = .bool
        case SPVC_BASETYPE_INT8:
            self = .int8
        case SPVC_BASETYPE_UINT8:
            self = .uint8
        case SPVC_BASETYPE_INT16:
            self = .int16
        case SPVC_BASETYPE_UINT16:
            self = .uint16
        case SPVC_BASETYPE_INT32:
            self = .int32
        case SPVC_BASETYPE_UINT32:
            self = .uint32
        case SPVC_BASETYPE_INT64:
            self = .int64
        case SPVC_BASETYPE_UINT64:
            self = .uint64
        case SPVC_BASETYPE_FP16:
            self = .half
        case SPVC_BASETYPE_FP32:
            self = .float
        case SPVC_BASETYPE_FP64:
            self = .double
        case SPVC_BASETYPE_ATOMIC_COUNTER:
            self = .atomicCounter
        case SPVC_BASETYPE_IMAGE, SPVC_BASETYPE_SAMPLED_IMAGE:
            self = .texture
        case SPVC_BASETYPE_SAMPLER:
            self = .sampler
        default:
            return nil
        }
    }
    
    var size: Int {
        switch self {
        case .void:
            return 0
        case .bool:
            return MemoryLayout<Bool>.size
        case .int8:
            return MemoryLayout<Int8>.size
        case .uint8:
            return MemoryLayout<UInt8>.size
        case .int16:
            return MemoryLayout<Int16>.size
        case .uint16:
            return MemoryLayout<UInt16>.size
        case .int32:
            return MemoryLayout<Int32>.size
        case .uint32:
            return MemoryLayout<UInt32>.size
        case .int64:
            return MemoryLayout<Int64>.size
        case .uint64:
            return MemoryLayout<UInt64>.size
        case .half:
            return MemoryLayout<UInt16>.size
        case .float:
            return MemoryLayout<Float>.size
        case .double:
            return MemoryLayout<Double>.size
        case .atomicCounter:
            return MemoryLayout<UInt32>.size
        case .packedVector(let element, let length):
            return length * element.stride
        case .vector(let element, 3):
            return 4 * element.stride
        case .vector(let element, let length):
            return length * element.stride
        case .array(let element, let length):
            return length * element.stride
        case .matrix(let element, let rows, let columns):
            return columns * SPIRVType.vector(element: element, length: rows).stride
        case .struct(_, let members):
            var size = 0
            for member in members {
                size = size.roundedUpToMultiple(of: member.type.alignment)
                size += member.type.size
            }
            return size
        default:
            fatalError()
        }
    }
    
    var alignment: Int {
        switch self {
        case .packedVector(let element, 3):
            return element.alignment
        case .vector(let element, 3):
            return SPIRVType.vector(element: element, length: 4).alignment
        case .vector(let element, let length):
            return length * element.stride
        case .array(let element, let length):
            return length * element.stride
        case .matrix(let element, let rows, _):
            return SPIRVType.vector(element: element, length: rows).alignment
        case .struct(_, let members):
            return members.lazy.map { $0.type.alignment }.max() ?? 0
        default:
            return self.size
        }
    }
    
    var stride : Int {
        return self.size.roundedUpToMultiple(of: self.alignment)
    }
}

extension SPIRVType : CustomStringConvertible {
    var name : String {
        switch self {
        case .void:
            return "Void"
        case .bool:
            return "Bool"
        case .int8:
            return "Int8"
        case .uint8:
            return "UInt8"
        case .int16:
            return "Int16"
        case .uint16:
            return "UInt16"
        case .int32:
            return "Int32"
        case .uint32:
            return "UInt32"
        case .int64:
            return "Int64"
        case .uint64:
            return "UInt64"
        case .half:
            return "Float16"
        case .float:
            return "Float"
        case .double:
            return "Double"
        case .atomicCounter:
            return "AtomicUInt32"
        case .packedVector(let element, let length):
            return "PackedVector\(length)<\(element)>"
        case .vector(.half, let length):
            return "Vector\(length)h" // FIXME: use SIMD once Float16 is a native Swift type.
        case .vector(let element, let length):
            return "SIMD\(length)<\(element)>"
        case .matrix(let element, 4, 3):
            return "AffineMatrix<\(element)>"
        case .matrix(let element, let rows, let columns):
            return "Matrix\(rows)x\(columns)<\(element)>"
        case .array(let element, let length):
            return "(\(repeatElement(element.description, count: length).joined(separator: ", ")))"
        case .struct(let name, _):
            return TypeLookup.formatName(name)
        case .buffer:
            return "Buffer"
        case .texture:
            return "Texture"
        case .sampler:
            return "SamplerDescriptor"
        }
    }
    
    var defaultInitialiser : String {
        switch self {
        case .void:
            return "()"
        case .bool:
            return "false"
        case .int8, .uint8, .int16, .uint16, .int32, .uint32, .int64, .uint64:
            return "0"
        case .half, .float, .double:
            return "0.0"
        case .vector(.half, _):
            return ".init(repeating: 0)" // FIXME: use 0.0 once Float16 is a native Swift type.
        case .vector(let element, _), .packedVector(let element, _):
            return ".init(repeating: \(element.defaultInitialiser))"
        case .array(let element, let length):
            return "(\(repeatElement(element.defaultInitialiser, count: length).joined(separator: ", ")))"
        default:
            return ".init()"
        }
    }
    
    var declaration : String {
        switch self {
        case .struct(_, let members):
            let memberDeclarations = members.map { "public var \($0.name): \($0.type.name) = \($0.type.defaultInitialiser)" }
            let memberArguments = members.map { "\($0.name): \($0.type.name)" }
            let memberAssignments = members.map { "self.\($0.name) = \($0.name)" }
            return """
            @frozen
            public struct \(self.name) : Hashable, NoArgConstructable {
                \(memberDeclarations.joined(separator: "\n    "))
            
                @inlinable
                public init() {}
            
                @inlinable
                public init(\(memberArguments.joined(separator: ", "))) {
                    \(memberAssignments.joined(separator: "\n        "))
                }
            }
            """
        default:
            return self.name
        }
    }
    
    var description : String {
        return self.declaration
    }
}

extension SPIRVType {
    init(compiler: spvc_compiler, typeId: spvc_type_id, sizeInStruct: Int? = nil) {
        let type = spvc_compiler_get_type_handle(compiler, typeId)
        let baseType = spvc_type_get_basetype(type)
        let baseTypeId = spvc_type_get_base_type_id(type)
        
        if baseType == SPVC_BASETYPE_STRUCT {
            let name = String(cString: spvc_compiler_get_name(compiler, baseTypeId)!)
            let memberTypeCount = spvc_type_get_num_member_types(type)
            
            var members = [SPIRVStructMember]()
            members.reserveCapacity(Int(memberTypeCount))
            
            for i in 0..<memberTypeCount {
                let memberTypeId = spvc_type_get_member_type(type, i)
                
                let name = String(cString: spvc_compiler_get_member_name(compiler, baseTypeId, i)!)
                
                var sizeInStruct : Int? = nil
            
                if i + 1 < memberTypeCount {
                    var offset : UInt32 = 0
                    spvc_compiler_type_struct_member_offset(compiler, type, i, &offset)
                    
                    var nextOffset : UInt32 = 0
                    spvc_compiler_type_struct_member_offset(compiler, type, i + 1, &nextOffset)
                    
                    sizeInStruct = Int(nextOffset - offset)
                }
                
                members.append(SPIRVStructMember(name: name, type: SPIRVType(compiler: compiler, typeId: memberTypeId, sizeInStruct: sizeInStruct)))
            }
            self = .struct(name: name, members: members)
        } else {
            let baseType = SPIRVType(baseType: baseType) ?? SPIRVType(compiler: compiler, typeId: typeId)
            
            let vectorSize = Int(spvc_type_get_vector_size(type))
            let columns = Int(spvc_type_get_columns(type))
            
            self = baseType
            if vectorSize > 1 {
                if columns > 1 {
                    self = .matrix(element: baseType, rows: vectorSize, columns: columns)
                } else {
                    self = .vector(element: baseType, length: vectorSize)
                    if let sizeInStruct = sizeInStruct, sizeInStruct < self.size {
                        self = .packedVector(element: baseType, length: vectorSize)
                    }
                }
            }

            let arrayDimensions = Int(spvc_type_get_num_array_dimensions(type))
            if arrayDimensions > 1 {
                self = .array(element: self, length: arrayDimensions)
            }
        }
    }
}

extension spvc_basetype {
    var swiftName : String {
        switch self {
        case SPVC_BASETYPE_VOID:
            return "Void"
        case SPVC_BASETYPE_BOOLEAN:
            return "Bool"
        case SPVC_BASETYPE_INT8:
            return "Int8"
        case SPVC_BASETYPE_UINT8:
            return "UInt8"
        case SPVC_BASETYPE_INT16:
            return "Int16"
        case SPVC_BASETYPE_UINT16:
            return "UInt16"
        case SPVC_BASETYPE_INT32:
            return "Int32"
        case SPVC_BASETYPE_UINT32:
            return "UInt32"
        case SPVC_BASETYPE_INT64:
            return "Int64"
        case SPVC_BASETYPE_UINT64:
            return "UInt64"
        case SPVC_BASETYPE_FP16:
            return "Float16"
        case SPVC_BASETYPE_FP32:
            return "Float"
        case SPVC_BASETYPE_FP64:
            return "Double"
        case SPVC_BASETYPE_STRUCT:
            return "struct"
        default:
            print("Warning: unhandled base type \(self)")
            return ""
        }
    }
}