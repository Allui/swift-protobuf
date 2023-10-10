//
//  ProvidesDeprecation.swift
//  
//
//  Created by Ivan Morozov on 10.10.2023.
//

import Foundation

///Protocol that all the Descriptors conform to provide deprecation
public protocol ProvidesDeprecation {
    /// Returns the deprecation comment to be used.
    func deprecation() -> String
}

// Protocol that a Descriptor can confirm to when only the Type controls depecation.
public protocol SimpleProvidesDeprecation: ProvidesDeprecation {
    /// If the type is deprecated.
    var isDeprecated: Bool { get }
}

public extension SimpleProvidesDeprecation {
    /// Default implementation to provide the depectation.
    func deprecation() -> String {
        guard isDeprecated else { return String() }
        return "@available(*, deprecated)\n"
    }
}

extension ProvidesDeprecation where Self: ProvidesSourceCodeLocation {
    /// Helper to get the protoSourceComments combined with any depectation comment.
    public func protoSourceCommentsWithDeprecation(
        commentPrefix: String = "///",
        leadingDetachedPrefix: String? = nil
    ) -> String {
        let protoSourceComments = protoSourceComments(
            commentPrefix: commentPrefix,
            leadingDetachedPrefix: leadingDetachedPrefix)
        let deprecation = deprecation()
        
        if deprecation.isEmpty {
            return protoSourceComments
        }
        if protoSourceComments.isEmpty {
            return deprecation
        }
        return "\(protoSourceComments)\(deprecation)"
    }
}
