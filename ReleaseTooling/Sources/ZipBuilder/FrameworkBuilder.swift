/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import Utils

/// A structure to build a .framework in a given project directory.
struct FrameworkBuilder {
  /// Platforms to be included in the built frameworks.
  private let targetPlatforms: [TargetPlatform]

  /// The directory containing the Xcode project and Pods folder.
  private let projectDir: URL

  /// Flag for building dynamic frameworks instead of static frameworks.
  private let dynamicFrameworks: Bool

  /// The Pods directory for building the framework.
  private var podsDir: URL {
    return projectDir.appendingPathComponent("Pods", isDirectory: true)
  }

  /// Default initializer.
  init(projectDir: URL, targetPlatforms: [TargetPlatform], dynamicFrameworks: Bool) {
    self.projectDir = projectDir
    self.targetPlatforms = targetPlatforms
    self.dynamicFrameworks = dynamicFrameworks
  }

  // MARK: - Public Functions

  /// Compiles the specified framework in a temporary directory and writes the build logs to file.
  /// This will compile all architectures for a single platform at a time.
  ///
  /// - Parameter framework: The name of the framework to be built.
  /// - Parameter logsOutputDir: The path to the directory to place build logs.
  /// - Parameter setCarthage: Set Carthage diagnostics flag in build.
  /// - Parameter moduleMapContents: Module map contents for all frameworks in this pod.
  /// - Returns: A path to the newly compiled frameworks, and Resources.
  func compileFrameworkAndResources(withName framework: String,
                                    logsOutputDir: URL? = nil,
                                    setCarthage: Bool,
                                    podInfo: CocoaPodUtils.PodInfo) -> ([URL], URL?) {
    let fileManager = FileManager.default
    let outputDir = fileManager.temporaryDirectory(withName: "frameworks_being_built")
    let logsDir = logsOutputDir ?? fileManager.temporaryDirectory(withName: "build_logs")
    do {
      // Remove the compiled frameworks directory, this isn't the cache we're using.
      if fileManager.directoryExists(at: outputDir) {
        try fileManager.removeItem(at: outputDir)
      }

      try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

      // Create our logs directory if it doesn't exist.
      if !fileManager.directoryExists(at: logsDir) {
        try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
      }
    } catch {
      fatalError("Failure creating temporary directory while building \(framework): \(error)")
    }

    if dynamicFrameworks {
      return (buildDynamicFrameworks(withName: framework, logsDir: logsDir, outputDir: outputDir),
              nil)
    } else {
      return buildStaticFrameworks(
        withName: framework,
        logsDir: logsDir,
        outputDir: outputDir,
        setCarthage: setCarthage,
        podInfo: podInfo
      )
    }
  }

  // MARK: - Private Helpers

  /// This runs a command and immediately returns a Shell result.
  /// NOTE: This exists in conjunction with the `Shell.execute...` due to issues with different
  ///       `.bash_profile` environment variables. This should be consolidated in the future.
  private static func syncExec(command: String,
                               args: [String] = [],
                               captureOutput: Bool = false) -> Shell
    .Result {
    let task = Process()
    task.launchPath = command
    task.arguments = args

    // If we want to output to the console, create a readabilityHandler and save each line along the
    // way. Otherwise, we can just read the pipe at the end. By disabling outputToConsole, some
    // commands (such as any xcodebuild) can run much, much faster.
    var output = ""
    if captureOutput {
      let pipe = Pipe()
      task.standardOutput = pipe
      let outHandle = pipe.fileHandleForReading

      outHandle.readabilityHandler = { pipe in
        // This will be run any time data is sent to the pipe. We want to print it and store it for
        // later. Ignore any non-valid Strings.
        guard let line = String(data: pipe.availableData, encoding: .utf8) else {
          print("Could not get data from pipe for command \(command): \(pipe.availableData)")
          return
        }
        if !line.isEmpty {
          output += line
        }
      }
      // Also set the termination handler on the task in order to stop the readabilityHandler from
      // parsing any more data from the task.
      task.terminationHandler = { t in
        guard let stdOut = t.standardOutput as? Pipe else { return }

        stdOut.fileHandleForReading.readabilityHandler = nil
      }
    } else {
      // No capturing output, just mark it as complete.
      output = "The task completed"
    }

    task.launch()
    task.waitUntilExit()

    // Normally we'd use a pipe to retrieve the output, but for whatever reason it slows things down
    // tremendously for xcodebuild.
    guard task.terminationStatus == 0 else {
      return .error(code: task.terminationStatus, output: output)
    }

    return .success(output: output)
  }

  /// Build all thin slices for an open source pod.
  /// - Parameter framework: The name of the framework to be built.
  /// - Parameter logsDir: The path to the directory to place build logs.
  /// - Parameter setCarthage: Set Carthage flag in GoogleUtilities for metrics.
  /// - Returns: A dictionary of URLs to the built thin libraries keyed by platform.
  private func buildFrameworksForAllPlatforms(withName framework: String,
                                              logsDir: URL,
                                              setCarthage: Bool) -> [TargetPlatform: URL] {
    // Build every architecture and save the locations in an array to be assembled.
    var slicedFrameworks = [TargetPlatform: URL]()
    for targetPlatform in targetPlatforms {
      let buildDir = projectDir.appendingPathComponent(targetPlatform.buildName)
      let sliced = buildSlicedFramework(withName: framework,
                                        targetPlatform: targetPlatform,
                                        buildDir: buildDir,
                                        logRoot: logsDir,
                                        setCarthage: setCarthage)
      slicedFrameworks[targetPlatform] = sliced
    }
    return slicedFrameworks
  }

  /// Uses `xcodebuild` to build a framework for a specific target platform.
  ///
  /// - Parameters:
  ///   - framework: Name of the framework being built.
  ///   - targetPlatform: The target platform to target for the build.
  ///   - buildDir: Location where the project should be built.
  ///   - logRoot: Root directory where all logs should be written.
  ///   - setCarthage: Set Carthage flag in GoogleUtilities for metrics.
  /// - Returns: A URL to the framework that was built.
  private func buildSlicedFramework(withName framework: String,
                                    targetPlatform: TargetPlatform,
                                    buildDir: URL,
                                    logRoot: URL,
                                    setCarthage: Bool = false) -> URL {
    let isMacCatalyst = targetPlatform == .catalyst
    let isMacCatalystString = isMacCatalyst ? "YES" : "NO"
    let workspacePath = projectDir.appendingPathComponent("FrameworkMaker.xcworkspace").path
    let distributionFlag = setCarthage ? "-DFIREBASE_BUILD_CARTHAGE" :
      "-DFIREBASE_BUILD_ZIP_FILE"
    let cFlags = "OTHER_CFLAGS=$(value) \(distributionFlag)"

    var archs = targetPlatform.archs.map { $0.rawValue }.joined(separator: " ")
    // The 32 bit archs do not build for iOS 11.
    if framework == "FirebaseAppCheck" || framework.hasSuffix("Swift") {
      if targetPlatform == .iOSDevice {
        archs = "arm64"
      } else if targetPlatform == .iOSSimulator {
        archs = "x86_64 arm64"
      }
    }

    var args = ["build",
                "-configuration", "release",
                "-workspace", workspacePath,
                "-scheme", framework,
                "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
                "ARCHS=\(archs)",
                "VALID_ARCHS=\(archs)",
                "ONLY_ACTIVE_ARCH=NO",
                // BUILD_LIBRARY_FOR_DISTRIBUTION=YES is necessary for Swift libraries.
                // See https://forums.developer.apple.com/thread/125646.
                // Unlike the comment there, the option here is sufficient to cause .swiftinterface
                // files to be generated in the .swiftmodule directory. The .swiftinterface files
                // are required for xcodebuild to successfully generate an xcframework.
                "BUILD_LIBRARY_FOR_DISTRIBUTION=YES",
                // Remove the -fembed-bitcode-marker compiling flag.
                "ENABLE_BITCODE=NO",
                "SUPPORTS_MACCATALYST=\(isMacCatalystString)",
                "BUILD_DIR=\(buildDir.path)",
                "-sdk", targetPlatform.sdkName,
                cFlags]

    // Code signing isn't needed for libraries. Disabling signing is required for
    // Catalyst libs with resources. See
    // https://github.com/CocoaPods/CocoaPods/issues/8891#issuecomment-573301570
    if isMacCatalyst {
      args.append("CODE_SIGN_IDENTITY=-")
    }
    print("""
    Compiling \(framework) for \(targetPlatform.buildName) (\(archs)) with command:
    /usr/bin/xcodebuild \(args.joined(separator: " "))
    """)

    // Regardless if it succeeds or not, we want to write the log to file in case we need to inspect
    // things further.
    let logFileName = "\(framework)-\(targetPlatform.buildName).txt"
    let logFile = logRoot.appendingPathComponent(logFileName)

    let result = FrameworkBuilder.syncExec(command: "/usr/bin/xcodebuild",
                                           args: args,
                                           captureOutput: true)
    switch result {
    case let .error(code, output):
      // Write output to disk and print the location of it. Force unwrapping here since it's going
      // to crash anyways, and at this point the root log directory exists, we know it's UTF8, so it
      // should pass every time. Revisit if that's not the case.
      try! output.write(to: logFile, atomically: true, encoding: .utf8)
      fatalError("Error building \(framework) for \(targetPlatform.buildName). Code: \(code). See " +
        "the build log at \(logFile)")

    case let .success(output):
      // Try to write the output to the log file but if it fails it's not a huge deal since it was
      // a successful build.
      try? output.write(to: logFile, atomically: true, encoding: .utf8)
      print("""
      Successfully built \(framework) for \(targetPlatform.buildName). Build log is at \(logFile).
      """)

      // Use the Xcode-generated path to return the path to the compiled library.
      // The framework name may be different from the pod name if the module is reset in the
      // podspec - like Release-iphonesimulator/BoringSSL-GRPC/openssl_grpc.framework.
      print("buildDir: \(buildDir)")
      let frameworkPath = buildDir.appendingPathComponents([targetPlatform.buildDirName, framework])
      var actualFramework: String
      do {
        let files = try FileManager.default.contentsOfDirectory(at: frameworkPath,
                                                                includingPropertiesForKeys: nil)
          .compactMap { $0.path }
        let frameworkDir = files.filter { $0.contains(".framework") }
        actualFramework = URL(fileURLWithPath: frameworkDir[0]).lastPathComponent
      } catch {
        fatalError("Error while enumerating files \(frameworkPath): \(error.localizedDescription)")
      }
      let libPath = frameworkPath.appendingPathComponent(actualFramework)
      print("buildSliced returns \(libPath)")
      return libPath
    }
  }

  // TODO: Automatically get the right name.
  /// The module name is different from the pod name when the module_name
  /// specifier is used in the podspec.
  ///
  /// - Parameter framework: The name of the pod to be built.
  /// - Returns: The corresponding framework/module name.
  private static func frameworkBuildName(_ framework: String) -> String {
    switch framework {
    case "PromisesObjC":
      return "FBLPromises"
    case "Protobuf":
      return "protobuf"
    default:
      return framework
    }
  }

  /// Compiles the specified framework in a temporary directory and writes the build logs to file.
  /// This will compile all architectures and use the -create-xcframework command to create a modern
  /// "fat" framework.
  ///
  /// - Parameter framework: The name of the framework to be built.
  /// - Parameter logsDir: The path to the directory to place build logs.
  /// - Returns: A path to the newly compiled frameworks (with any included Resources embedded).
  private func buildDynamicFrameworks(withName framework: String,
                                      logsDir: URL,
                                      outputDir: URL) -> [URL] {
    // xcframework doesn't lipo things together but accepts fat frameworks for one target.
    // We group architectures here to deal with this fact.
    var thinFrameworks = [URL]()
    for targetPlatform in TargetPlatform.allCases {
      let buildDir = projectDir.appendingPathComponent(targetPlatform.buildName)
      let slicedFramework = buildSlicedFramework(
        withName: FrameworkBuilder.frameworkBuildName(framework),
        targetPlatform: targetPlatform,
        buildDir: buildDir,
        logRoot: logsDir
      )
      thinFrameworks.append(slicedFramework)
    }
    return thinFrameworks
  }

  /// Compiles the specified framework in a temporary directory and writes the build logs to file.
  /// This will compile all architectures and use the -create-xcframework command to create a modern
  /// "fat" framework.
  ///
  /// - Parameter framework: The name of the framework to be built.
  /// - Parameter logsDir: The path to the directory to place build logs.
  /// - Parameter moduleMapContents: Module map contents for all frameworks in this pod.
  /// - Returns: A path to the newly compiled framework, and the Resource URL.
  private func buildStaticFrameworks(withName framework: String,
                                     logsDir: URL,
                                     outputDir: URL,
                                     setCarthage: Bool,
                                     podInfo: CocoaPodUtils.PodInfo) -> ([URL], URL) {
    // Build every architecture and save the locations in an array to be assembled.
    let slicedFrameworks = buildFrameworksForAllPlatforms(withName: framework, logsDir: logsDir,
                                                          setCarthage: setCarthage)

    // Create the framework directory in the filesystem for the thin archives to go.
    let fileManager = FileManager.default
    let frameworkName = FrameworkBuilder.frameworkBuildName(framework)
    let frameworkDir = outputDir.appendingPathComponent("\(frameworkName).framework")
    do {
      try fileManager.createDirectory(at: frameworkDir, withIntermediateDirectories: true)
    } catch {
      fatalError("Could not create framework directory while building framework \(frameworkName). " +
        "\(error)")
    }

    guard let anyPlatform = targetPlatforms.first,
          let archivePath = slicedFrameworks[anyPlatform] else {
      fatalError("Could not get a path to an archive to fetch headers in \(frameworkName).")
    }

    // Find CocoaPods generated umbrella header.
    var umbrellaHeader = ""
    // TODO(ncooke3): Evaluate if `TensorFlowLiteObjC` is needed?
    if framework == "gRPC-Core" || framework == "TensorFlowLiteObjC" {
      // TODO: Proper handling of podspec-specified module.modulemap files with customized umbrella
      // headers. This is good enough for Firebase since it doesn't need these modules.
      // TODO(ncooke3): Is this needed for gRPC-Core?
      umbrellaHeader = "\(framework)-umbrella.h"
    } else {
      var umbrellaHeaderURL: URL
      // Get the framework Headers directory. On macOS, it's a symbolic link.
      let headersDir = archivePath.appendingPathComponent("Headers").resolvingSymlinksInPath()
      do {
        let files = try fileManager.contentsOfDirectory(at: headersDir,
                                                        includingPropertiesForKeys: nil)
          .compactMap { $0.path }
        let umbrellas = files.filter { $0.hasSuffix("umbrella.h") }
        if umbrellas.count != 1 {
          fatalError("Did not find exactly one umbrella header in \(headersDir).")
        }
        guard let firstUmbrella = umbrellas.first else {
          fatalError("Failed to get umbrella header in \(headersDir).")
        }
        umbrellaHeaderURL = URL(fileURLWithPath: firstUmbrella)
      } catch {
        fatalError("Error while enumerating files \(headersDir): \(error.localizedDescription)")
      }
      umbrellaHeader = umbrellaHeaderURL.lastPathComponent
    }

    // TODO: copy PrivateHeaders directory as well if it exists. SDWebImage is an example pod.

    // Move all the Resources into .bundle directories in the destination Resources dir. The
    // Resources live are contained within the folder structure:
    // `projectDir/arch/Release-platform/FrameworkName`.
    // The Resources are stored at the top-level of the .framework or .xcframework directory.
    // For Firebase distributions, they are propagated one level higher in the final distribution.
    let resourceContents = projectDir.appendingPathComponents([anyPlatform.buildName,
                                                               anyPlatform.buildDirName,
                                                               framework])

    guard let moduleMapContentsTemplate = podInfo.moduleMapContents else {
      fatalError("Module map contents missing for framework \(frameworkName)")
    }
    let moduleMapContents = moduleMapContentsTemplate.get(umbrellaHeader: umbrellaHeader)
    let frameworks = groupFrameworks(withName: frameworkName,
                                     isCarthage: setCarthage,
                                     fromFolder: frameworkDir,
                                     slicedFrameworks: slicedFrameworks,
                                     moduleMapContents: moduleMapContents)

    // Remove the temporary thin archives.
    for slicedFramework in slicedFrameworks.values {
      do {
        try fileManager.removeItem(at: slicedFramework)
      } catch {
        // Just log a warning instead of failing, since this doesn't actually affect the build
        // itself. This should only be shown to help users clean up their disk afterwards.
        print("""
        WARNING: Failed to remove temporary sliced framework at \(slicedFramework.path). This should
        be removed from your system to save disk space. \(error). You should be able to remove the
        archive from Terminal with:
        rm \(slicedFramework.path)
        """)
      }
    }
    return (frameworks, resourceContents)
  }

  /// Parses CocoaPods config files or uses the passed in `moduleMapContents` to write the
  /// appropriate `moduleMap` to the `destination`.
  /// Returns true to fail if building for Carthage and there are Swift modules.
  @discardableResult
  private func packageModuleMaps(inFrameworks frameworks: [URL],
                                 frameworkName: String,
                                 moduleMapContents: String,
                                 destination: URL,
                                 buildingCarthage: Bool = false) -> Bool {
    // CocoaPods does not put dependent frameworks and libraries into the module maps it generates.
    // Instead it use build options to specify them. For the zip build, we need the module maps to
    // include the dependent frameworks and libraries. Therefore we reconstruct them by parsing
    // the CocoaPods config files and add them here.
    // In the case of a mixed language framework, not only are the Swift module
    // files copied, but a `module.modulemap` is created by combining the given
    // module map contents and a synthesized submodule that modularizes the
    // generated Swift header.
    if makeSwiftModuleMap(thinFrameworks: frameworks,
                          frameworkName: frameworkName,
                          destination: destination,
                          moduleMapContents: moduleMapContents,
                          buildingCarthage: buildingCarthage) {
      return buildingCarthage
    }
    // Copy the module map to the destination.
    let moduleDir = destination.appendingPathComponent("Modules")
    do {
      try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
    } catch {
      let frameworkName: String = frameworks.first?.lastPathComponent ?? "<UNKNOWN"
      fatalError("Could not create Modules directory for framework: \(frameworkName). \(error)")
    }
    let modulemap = moduleDir.appendingPathComponent("module.modulemap")
    do {
      try moduleMapContents.write(to: modulemap, atomically: true, encoding: .utf8)
    } catch {
      let frameworkName: String = frameworks.first?.lastPathComponent ?? "<UNKNOWN"
      fatalError("Could not write modulemap to disk for \(frameworkName): \(error)")
    }
    return false
  }

  /// URLs pointing to the frameworks containing architecture specific code.
  /// Returns true if there are Swift modules.
  private func makeSwiftModuleMap(thinFrameworks: [URL],
                                  frameworkName: String,
                                  destination: URL,
                                  moduleMapContents: String,
                                  buildingCarthage: Bool = false) -> Bool {
    let fileManager = FileManager.default

    for thinFramework in thinFrameworks {
      // Get the Modules directory. The Catalyst one is a symbolic link.
      let moduleDir = thinFramework.appendingPathComponent("Modules").resolvingSymlinksInPath()
      do {
        let files = try fileManager.contentsOfDirectory(at: moduleDir,
                                                        includingPropertiesForKeys: nil)
          .compactMap { $0.path }
        let swiftModules = files.filter { $0.hasSuffix(".swiftmodule") }
        if swiftModules.isEmpty {
          return false
        } else if buildingCarthage {
          return true
        }
        guard let first = swiftModules.first,
              let swiftModule = URL(string: first) else {
          fatalError("Failed to get swiftmodule in \(moduleDir).")
        }
        let destModuleDir = destination.appendingPathComponent("Modules")
        if !fileManager.directoryExists(at: destModuleDir) {
          do {
            try fileManager.copyItem(at: moduleDir, to: destModuleDir)
          } catch {
            fatalError("Could not copy Modules from \(moduleDir) to " +
              "\(destModuleDir): \(error)")
          }
        } else {
          // If the Modules directory is already there, only copy in the architecture specific files
          // from the *.swiftmodule subdirectory.
          do {
            let files = try fileManager.contentsOfDirectory(at: swiftModule,
                                                            includingPropertiesForKeys: nil)
              .compactMap { $0.path }
            let destSwiftModuleDir = destModuleDir
              .appendingPathComponent(swiftModule.lastPathComponent)
            for file in files {
              let fileURL = URL(fileURLWithPath: file)
              let projectDir = swiftModule.appendingPathComponent("Project")
              if fileURL.lastPathComponent == "Project",
                 fileManager.directoryExists(at: projectDir) {
                // The Project directory (introduced with Xcode 11.4) already exists, only copy in
                // new contents.
                let projectFiles = try fileManager.contentsOfDirectory(at: projectDir,
                                                                       includingPropertiesForKeys: nil)
                  .compactMap { $0.path }
                let destProjectDir = destSwiftModuleDir.appendingPathComponent("Project")
                for projectFile in projectFiles {
                  let projectFileURL = URL(fileURLWithPath: projectFile)
                  do {
                    try fileManager.copyItem(at: projectFileURL, to:
                      destProjectDir.appendingPathComponent(projectFileURL.lastPathComponent))
                  } catch {
                    fatalError("Could not copy Project file from \(projectFileURL) to " +
                      "\(destProjectDir): \(error)")
                  }
                }
              } else {
                do {
                  try fileManager.copyItem(at: fileURL, to:
                    destSwiftModuleDir
                      .appendingPathComponent(fileURL.lastPathComponent))
                } catch {
                  fatalError("Could not copy Swift module file from \(fileURL) to " +
                    "\(destSwiftModuleDir): \(error)")
                }
              }
            }
          } catch {
            fatalError("Failed to get Modules directory contents - \(moduleDir):" +
              "\(error.localizedDescription)")
          }
        }
        do {
          // If this point is reached, the framework contains a Swift module,
          // so it's built from either Swift sources or Swift & C Family
          // Language sources. Frameworks built from only Swift sources will
          // contain only two headers: the CocoaPods-generated umbrella header
          // and the Swift-generated Swift header. If the framework's `Headers`
          // directory contains more than two resources, then it is assumed
          // that the framework was built from mixed language sources because
          // those additional headers are public headers for the C Family
          // Language sources.
          let headersDir = destination.appendingPathComponent("Headers")
          let headers = try fileManager.contentsOfDirectory(
            at: headersDir,
            includingPropertiesForKeys: nil
          )
          if headers.count > 2 {
            // It is assumed that the framework will always contain a
            // `module.modulemap` (either CocoaPods generates it or a custom
            // one was set in the podspec corresponding to the framework being
            // processed) within the framework's `Modules` directory. The main
            // module declaration within this `module.modulemap` should be
            // replaced with the given module map contents that was computed to
            // include frameworks and libraries that the framework slice
            // depends on.
            let newModuleMapContents = moduleMapContents + """
            module \(frameworkName).Swift {
              header "\(frameworkName)-Swift.h"
              requires objc
            }
            """
            let modulemapURL = destination.appendingPathComponents(["Modules", "module.modulemap"])
            try newModuleMapContents.write(to: modulemapURL, atomically: true, encoding: .utf8)
          }
        } catch {
          fatalError(
            "Error while synthesizing a mixed language framework's module map: \(error.localizedDescription)"
          )
        }
      } catch {
        fatalError("Error while enumerating files \(moduleDir): \(error.localizedDescription)")
      }
    }
    return true
  }

  /// Groups slices for each platform into a minimal set of frameworks.
  /// - Parameter withName: The framework name.
  /// - Parameter isCarthage: Name the temp directory differently for Carthage.
  /// - Parameter fromFolder: The almost complete framework folder. Includes
  /// Headers, and Resources.
  /// - Parameter slicedFrameworks: All the frameworks sliced by platform.
  /// - Parameter moduleMapContents: Module map contents for all frameworks in this pod.
  private func groupFrameworks(withName framework: String,
                               isCarthage: Bool,
                               fromFolder: URL,
                               slicedFrameworks: [TargetPlatform: URL],
                               moduleMapContents: String) -> ([URL]) {
    let fileManager = FileManager.default

    // Create a `.framework` for each of the thinArchives using the `fromFolder` as the base.
    let platformFrameworksDir = fileManager.temporaryDirectory(
      withName: isCarthage ? "carthage_frameworks" : "platform_frameworks"
    )
    if !fileManager.directoryExists(at: platformFrameworksDir) {
      do {
        try fileManager.createDirectory(at: platformFrameworksDir,
                                        withIntermediateDirectories: true)
      } catch {
        fatalError("Could not create a temp directory to store all thin frameworks: \(error)")
      }
    }

    // Group the thin frameworks into three groups: device, simulator, and Catalyst (all represented
    // by the `TargetPlatform` enum. The slices need to be packaged that way with lipo before
    // creating a .framework that works for similar grouped architectures. If built separately,
    // `-create-xcframework` will return an error and fail:
    // `Both ios-arm64 and ios-armv7 represent two equivalent library definitions`
    var frameworksBuilt: [URL] = []
    for (platform, frameworkPath) in slicedFrameworks {
      // Create the following structure in the platform frameworks directory:
      // - platform_frameworks
      //   └── $(PLATFORM)
      //       └── $(FRAMEWORK).framework
      let platformFrameworkDir = platformFrameworksDir
        .appendingPathComponent(platform.buildName)
        .appendingPathComponent(fromFolder.lastPathComponent)
      do {
        try fileManager.createDirectory(at: platformFrameworkDir, withIntermediateDirectories: true)
      } catch {
        fatalError("Could not create directory for architecture slices on \(platform) for " +
          "\(framework): \(error)")
      }

      // Move any privacy manifest-containing resource bundles into the
      // platform framework.
      try? fileManager.contentsOfDirectory(
        at: frameworkPath.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "bundle" }
      // TODO(ncooke3): Once the zip is built with Xcode 15, the following
      // `filter` can be removed. The following block exists to preserve
      // how resources (e.g. like FIAM's) are packaged for use in Xcode 14.
      .filter { bundleURL in
        let dirEnum = fileManager.enumerator(atPath: bundleURL.path)
        var containsPrivacyManifest = false
        while let relativeFilePath = dirEnum?.nextObject() as? String {
          if relativeFilePath.hasSuffix("PrivacyInfo.xcprivacy") {
            containsPrivacyManifest = true
            break
          }
        }
        return containsPrivacyManifest
      }
      // Bundles are moved rather than copied to prevent them from being
      // packaged in a `Resources` directory at the root of the xcframework.
      .forEach { try! fileManager.moveItem(
        at: $0,
        to: platformFrameworkDir.appendingPathComponent($0.lastPathComponent)
      ) }

      // Headers from slice
      do {
        let headersSrc: URL = frameworkPath.appendingPathComponent("Headers")
          .resolvingSymlinksInPath()
        // The macOS slice's `Headers` directory may have a `Headers` file in
        // it that symbolically links to nowhere. For example, in the 8.0.0
        // zip distribution, see the `Headers` directory in the macOS slice
        // of the `PromisesObjC.xcframework`. Delete it here to avoid putting
        // it in the zip or crashing the Carthage hash generation. Because
        // this will throw an error for cases where the file does not exist,
        // the error is ignored.
        try? fileManager.removeItem(at: headersSrc.appendingPathComponent("Headers"))

        try fileManager.copyItem(
          at: headersSrc,
          to: platformFrameworkDir.appendingPathComponent("Headers")
        )
      } catch {
        fatalError("Could not create framework directory needed to build \(framework): \(error)")
      }

      // Copy the binary to the right location.
      let binaryName = frameworkPath.lastPathComponent.replacingOccurrences(of: ".framework",
                                                                            with: "")
      let fatBinary = frameworkPath.appendingPathComponent(binaryName).resolvingSymlinksInPath()
      let fatBinaryDestination = platformFrameworkDir.appendingPathComponent(framework)
      do {
        try fileManager.copyItem(at: fatBinary, to: fatBinaryDestination)
      } catch {
        fatalError("Could not copy fat binary to framework directory for \(framework): \(error)")
      }

      // Use the appropriate moduleMaps
      packageModuleMaps(inFrameworks: [frameworkPath],
                        frameworkName: framework,
                        moduleMapContents: moduleMapContents,
                        destination: platformFrameworkDir)

      frameworksBuilt.append(platformFrameworkDir)
    }
    return frameworksBuilt
  }

  /// Package the built frameworks into an XCFramework.
  /// - Parameter withName: The framework name.
  /// - Parameter frameworks: The grouped frameworks.
  /// - Parameter xcframeworksDir: Location at which to build the xcframework.
  /// - Parameter resourceContents: Location of the resources for this xcframework.
  static func makeXCFramework(withName name: String,
                              frameworks: [URL],
                              xcframeworksDir: URL,
                              resourceContents: URL?) -> URL {
    let xcframework = xcframeworksDir
      .appendingPathComponent(frameworkBuildName(name) + ".xcframework")

    // The arguments for the frameworks need to be separated.
    var frameworkArgs: [String] = []
    for frameworkBuilt in frameworks {
      frameworkArgs.append("-framework")
      frameworkArgs.append(frameworkBuilt.path)
    }

    let outputArgs = ["-output", xcframework.path]
    let args = ["-create-xcframework"] + frameworkArgs + outputArgs
    print("""
    Building \(xcframework) with command:
    /usr/bin/xcodebuild \(args.joined(separator: " "))
    """)
    let result = syncExec(command: "/usr/bin/xcodebuild", args: args, captureOutput: true)
    switch result {
    case let .error(code, output):
      fatalError("Could not build xcframework for \(name) exit code \(code): \(output)")

    case .success:
      print("XCFramework for \(name) built successfully at \(xcframework).")
    }
    // xcframework resources are packaged at top of xcframework.
    if let resourceContents = resourceContents {
      let resourceDir = xcframework.appendingPathComponent("Resources")
      do {
        try ResourcesManager.moveAllBundles(inDirectory: resourceContents, to: resourceDir)
      } catch {
        fatalError("Could not move bundles into Resources directory while building \(name): " +
          "\(error)")
      }
    }
    return xcframework
  }
}
