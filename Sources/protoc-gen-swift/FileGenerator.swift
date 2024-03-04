// Sources/protoc-gen-swift/FileGenerator.swift - File-level generation logic
//
// Copyright (c) 2014 - 2016 Apple Inc. and the project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See LICENSE.txt for license information:
// https://github.com/apple/swift-protobuf/blob/main/LICENSE.txt
//
// -----------------------------------------------------------------------------
///
/// This provides the logic for each file that is stored in the plugin request.
/// In particular, generateOutputFile() actually builds a Swift source file
/// to represent a single .proto input.  Note that requests typically contain
/// a number of proto files that are not to be generated.
///
// -----------------------------------------------------------------------------
import Foundation
import SwiftProtobufPluginLibrary
import SwiftProtobuf


class FileGenerator {
    private let fileDescriptor: FileDescriptor
    private let generatorOptions: GeneratorOptions
    private let namer: SwiftProtobufNamer

    func getOutputFilename(existing names: inout [String: Int]) -> String {
        let ext = ".pb.swift"
        let pathParts = splitPath(pathname: fileDescriptor.name)
        switch generatorOptions.outputNaming {
        case .fullPath:
            let name = makeName(original: pathParts.base, existing: &names)
            return pathParts.dir + name + ext
        case .pathToUnderscores:
            let dirWithUnderscores =
                pathParts.dir.replacingOccurrences(of: "/", with: "_")
            return dirWithUnderscores + pathParts.base + ext
        case .dropPath:
            let name = makeName(original: pathParts.base, existing: &names)
            return name + ext
        case .package:
            let name = makeName(original: pathParts.base, existing: &names)
            return fileDescriptor.package + "/" + name + ext
        }
    }

    private func makeName(original name: String, existing names: inout [String: Int]) -> String {
        if let count = names[name] {
            names[name] = count + 1
            return name + ".\(count)"
        }
        names[name] = 1
        return name
    }

    init(fileDescriptor: FileDescriptor,
         generatorOptions: GeneratorOptions) {
        self.fileDescriptor = fileDescriptor
        self.generatorOptions = generatorOptions
        namer = SwiftProtobufNamer(currentFile: fileDescriptor,
                                   protoFileToModuleMappings: generatorOptions.protoToModuleMappings)
    }

    /// Generate, if `errorString` gets filled in, then report error instead of using
    /// what written into `printer`.
    func generateOutputFile(printer p: inout CodePrinter, errorString: inout String?) {
        guard fileDescriptor.fileOptions.swiftPrefix.isEmpty ||
            isValidSwiftIdentifier(fileDescriptor.fileOptions.swiftPrefix,
                                   allowQuoted: false) else {
          errorString = "\(fileDescriptor.name) has an 'swift_prefix' that isn't a valid Swift identifier (\(fileDescriptor.fileOptions.swiftPrefix))."
          return
        }
        p.print(
            "// DO NOT EDIT.\n",
            "// swift-format-ignore-file\n",
            "//\n",
            "// Generated by the Swift generator plugin for the protocol buffer compiler.\n",
            "// Source: \(fileDescriptor.name)\n",
            "//\n",
            "// For information on using the generated types, please see the documentation:\n",
            "//   https://github.com/apple/swift-protobuf/\n",
            "\n")

        // Attempt to bring over the comments at the top of the .proto file as
        // they likely contain copyrights/preamble/etc.
        //
        // The C++ FileDescriptor::GetSourceLocation(), says the location for
        // the file is an empty path. That never seems to have comments on it.
        // https://github.com/protocolbuffers/protobuf/issues/2249 opened to
        // figure out the right way to do this since the syntax entry is
        // optional.
        let syntaxPath = IndexPath(index: Google_Protobuf_FileDescriptorProto.FieldNumbers.syntax)
        if let syntaxLocation = fileDescriptor.sourceCodeInfoLocation(path: syntaxPath) {
          let comments = syntaxLocation.asSourceComment(commentPrefix: "///",
                                                        leadingDetachedPrefix: "//")
          if !comments.isEmpty {
              p.print(comments)
              // If the was a leading or tailing comment it won't have a blank
              // line, after it, so ensure there is one.
              if !comments.hasSuffix("\n\n") {
                  p.print("\n")
              }
          }
        }

        p.print("import Foundation\n")
        p.print("import GRPCNetwork\n")

        if self.generatorOptions.implementationOnlyImports,
           self.generatorOptions.visibility == .public {
            errorString = """
                Cannot use @_implementationOnly imports when the proto visibility is public.
                Either change the visibility to internal, or disable @_implementationOnly imports.
            """
            return
        }

        // Import all other imports as @_implementationOnly if the visiblity is
        // internal and the option is set, to avoid exposing internal types to users.
        let visibilityAnnotation: String = {
            if self.generatorOptions.implementationOnlyImports,
               self.generatorOptions.visibility == .internal {
                return "@_implementationOnly "
            } else {
                return ""
            }
        }()
        
        if let neededImports = generatorOptions.protoToModuleMappings.neededModules(forFile: fileDescriptor) {
            p.print("\n")
            for i in neededImports {
                p.print("\(visibilityAnnotation)import \(i)\n")
            }
        }

//        p.print("\n")
//        generateVersionCheck(printer: &p)

        let extensionSet =
            ExtensionSetGenerator(fileDescriptor: fileDescriptor,
                                  generatorOptions: generatorOptions,
                                  namer: namer)

        extensionSet.add(extensionFields: fileDescriptor.extensions)

        let enums = fileDescriptor.enums.map {
            return EnumGenerator(descriptor: $0, generatorOptions: generatorOptions, namer: namer)
        }

        let messages = fileDescriptor.messages.map {
          return MessageGenerator(descriptor: $0,
                                  generatorOptions: generatorOptions,
                                  namer: namer,
                                  extensionSet: extensionSet)
        }

        for e in enums {
            e.generateMainEnum(printer: &p)
            e.generateCaseIterable(printer: &p)
        }

        for m in messages {
            m.generateMainStruct(printer: &p, parent: nil, errorString: &errorString)

            var caseIterablePrinter = CodePrinter()
            m.generateEnumCaseIterable(printer: &caseIterablePrinter)
            if !caseIterablePrinter.isEmpty {
              p.print("\n#if swift(>=4.2)\n")
              p.print(caseIterablePrinter.content)
              p.print("\n#endif  // swift(>=4.2)\n")
            }
        }

//        var sendablePrinter = CodePrinter()
//        for e in enums {
//            e.generateSendable(printer: &sendablePrinter)
//        }
//
//        for m in messages {
//            m.generateSendable(printer: &sendablePrinter)
//        }

        if !extensionSet.isEmpty {
            let pathParts = splitPath(pathname: fileDescriptor.name)
            let filename = pathParts.base + pathParts.suffix
            p.print(
                "\n",
                "// MARK: - Extension support defined in \(filename).\n")

            // Generate the Swift Extensions on the Messages that provide the api
            // for using the protobuf extension.
            extensionSet.generateMessageSwiftExtensions(printer: &p)

            // Generate a registry for the file.
            extensionSet.generateFileProtobufExtensionRegistry(printer: &p)

            // Generate the Extension's declarations (used by the two above things).
            //
            // This is done after the other two as the only time developers will need
            // these symbols is if they are manually building their own ExtensionMap;
            // so the others are assumed more interesting.
            extensionSet.generateProtobufExtensionDeclarations(printer: &p)
        }

        let protoPackage = fileDescriptor.package
        let needsProtoPackage: Bool = !protoPackage.isEmpty && !messages.isEmpty
        if needsProtoPackage || !enums.isEmpty || !messages.isEmpty {
            p.print(
                "\n",
                "// MARK: - Code below here is support for the SwiftProtobuf runtime.\n")
            if needsProtoPackage {
                p.print(
                    "\n",
                    "fileprivate let _protobuf_package = \"\(protoPackage)\"\n")
            }
            for e in enums {
                e.generateRuntimeSupport(printer: &p)
            }
            for m in messages {
                m.generateRuntimeSupport(printer: &p, file: self, parent: nil)
            }
        }
    }

    private func generateVersionCheck(printer p: inout CodePrinter) {
        let v = Version.compatibilityVersion
        p.print(
            "// If the compiler emits an error on this type, it is because this file\n",
            "// was generated by a version of the `protoc` Swift plug-in that is\n",
            "// incompatible with the version of SwiftProtobuf to which you are linking.\n",
            "// Please ensure that you are building against the same version of the API\n",
            "// that was used to generate this file.\n",
            "fileprivate struct _GeneratedWithProtocGenSwiftVersion: \(namer.swiftProtobufModuleName).ProtobufAPIVersionCheck {\n")
        p.indent()
        p.print(
            "struct _\(v): \(namer.swiftProtobufModuleName).ProtobufAPIVersion_\(v) {}\n",
            "typealias Version = _\(v)\n")
        p.outdent()
        p.print("}\n")
    }
}
