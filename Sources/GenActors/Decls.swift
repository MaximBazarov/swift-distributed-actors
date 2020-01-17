//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Files
import SwiftSyntax

struct ActorableTypeDecl {
    enum DeclType {
        case `protocol`
        case `class`
        case `struct`
        case `enum`
        case `extension`
    }

    /// File where the actorable was defined
    var sourceFile: File

    var imports: [String] = []

    var access: String = ""
    var type: DeclType

    /// Contains type names within which this type is declared, e.g. `[Actorables.May.Be.Nested].MyActorable`.
    /// Empty for top level declarations.
    var declaredWithin: [String] = []

    var name: String
    var nameFirstLowercased: String {
        var res: String = self.name.first!.lowercased()
        res.append(contentsOf: self.name.dropFirst())
        return res
    }

    var fullName: String {
        if self.declaredWithin.isEmpty {
            return self.name
        } else {
            return "\(self.declaredWithin.joined(separator: ".")).\(self.name)"
        }
    }

    var generateCodableConformance: Bool

    var messageFullyQualifiedName: String {
        switch self.type {
        case .protocol:
            return "GeneratedActor.Messages.\(self.name)"
        default:
            return "\(self.fullName).Message"
        }
    }

    var boxFuncName: String {
        // TODO: "$box\(self.name)" would be nicer, but it is reserved
        // (error: cannot declare entity named '$boxParking'; the '$' prefix is reserved for implicitly-synthesized declarations)
        "_box\(self.name)"
    }

    /// If this decl implements other actorable protocols, those should be included here
    /// Available only after post processing phase
    var actorableProtocols: Set<ActorableTypeDecl> = []

    /// Cleared and Actorable protocols are moved to actorableProtocols in post processing
    var inheritedTypes: Set<String> = []

    /// Those functions need to be made into message protocol and generate stuff for them
    var funcs: [ActorFuncDecl] = []

    /// Only expected in case of a `protocol` for
    var boxingFunc: ActorFuncDecl?

    /// Stores if the `receiveTerminated` implementation is `throws` or not
    /// The default is true since the protocols signature is such, however if users implement it without throws
    /// we must not invoke it with `try` prefixed.
    var receiveTerminatedIsThrowing = true

    /// Stores if the `receiveSignal` implementation is `throws` or not
    /// The default is true since the protocols signature is such, however if users implement it without throws
    /// we must not invoke it with `try` prefixed.
    var receiveSignalIsThrowing = true
}

// TODO: Identity should include module name
extension ActorableTypeDecl: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
    }

    public static func == (lhs: ActorableTypeDecl, rhs: ActorableTypeDecl) -> Bool {
        if lhs.name != rhs.name {
            return false
        }
        return true
    }
}

struct ActorFuncDecl {
    let message: ActorableMessageDecl
}

extension ActorFuncDecl: Equatable {
    public static func == (lhs: ActorFuncDecl, rhs: ActorFuncDecl) -> Bool {
        lhs.message == rhs.message
    }
}

struct ActorableMessageDecl {
    let actorableName: String
    var actorableNameFirstLowercased: String { // TODO: more DRY
        var res: String = self.actorableName.first!.lowercased()
        res.append(contentsOf: self.actorableName.dropFirst())
        return res
    }

    let access: String?
    var outerType: String?
    let name: String

    typealias Name = String
    typealias TypeName = String
    let params: [(Name?, Name, TypeName)]

    var isMutating: Bool

    /// Similar to `params` but with potential `replyTo` parameter appended
    var effectiveParams: [(Name?, Name, TypeName)] {
        var res = self.params

        switch self.returnType {
        case .void, .behavior:
            () // no "reply"

        case .type(let valueType) where !self.throwing:
            res.append((nil, "_replyTo", "ActorRef<\(valueType)>"))

        case .type(let valueType) /* self.throwing */:
            res.append((nil, "_replyTo", "ActorRef<Result<\(valueType), Error>>"))
        case .result(let valueType, let errorType):
            res.append((nil, "_replyTo", "ActorRef<Result<\(valueType), \(errorType)>>"))
        case .nioEventLoopFuture(let valueType):
            res.append((nil, "_replyTo", "ActorRef<Result<\(valueType), Error>>"))
        }

        return res
    }

    let throwing: Bool

    let returnType: ReturnType

    enum ReturnType {
        case void
        case result(String, errorType: String)
        case nioEventLoopFuture(of: String)
        case behavior(String)
        case type(String)

        static func fromType(_ type: TypeSyntax?) -> ReturnType {
            guard let t = type else {
                return .void
            }

            if "\(t)".starts(with: "Behavior<") {
                return .behavior("\(t)")
            } else if "\(t)".starts(with: "Result<") {
                // TODO: instead analyse the type syntax?
                let trimmed = String("\(t)"
                    .trim(character: " ")
                    .replacingOccurrences(of: " ", with: "")
                )

                // FIXME: this will break with nexting...
                let valueType = String(trimmed[trimmed.index(after: trimmed.firstIndex(of: "<")!) ..< trimmed.firstIndex(of: ",")!])
                let errorType = String(trimmed[trimmed.index(after: trimmed.firstIndex(of: ",")!) ..< trimmed.lastIndex(of: ">")!])

                return .result(valueType, errorType: errorType)
            } else if "\(t)".starts(with: "EventLoopFuture<") {
                let valueTypeString = String("\(t)"
                    .trim(character: " ")
                    .replacingOccurrences(of: "EventLoopFuture<", with: "")
                    .dropLast(1)
                )
                return .nioEventLoopFuture(of: valueTypeString)
            } else {
                return .type("\(t)".trim(character: " "))
            }
        }
    }
}

extension ActorableMessageDecl: Hashable {
    public func hash(into hasher: inout Hasher) {
//        hasher.combine(access) // FIXME? rules are a bit more complex in reality here, since enclosing scope etc
        hasher.combine(self.name) // FIXME: take into account enclosing scope
        hasher.combine(self.throwing)
    }

    public static func == (lhs: ActorableMessageDecl, rhs: ActorableMessageDecl) -> Bool {
//        if lhs.access != rhs.access { // FIXME? rules are a bit more complex in reality here, since enclosing scope etc
//            return false
//        }
        if lhs.name != rhs.name {
            return false
        }
        if lhs.throwing != rhs.throwing {
            return false
        }
        return true
    }
}
