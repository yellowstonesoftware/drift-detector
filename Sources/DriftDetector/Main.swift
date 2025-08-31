import ArgumentParser
import Foundation
import Logging
import NIO
import SemVer

@main
struct DriftDetector: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "drift_detector",
    abstract: "A tool to detect version drift between Kubernetes deployments and GitHub releases",
    version: "__version__"
  )

  @Option(
    name: .long,
    help:
      "Kubernetes contexts with aliases in format 'context=alias'. Can be specified multiple times."
  )
  var context: [String] = []

  @Option(
    name: .long,
    help: "Kubernetes namespace to inspect"
  )
  var namespace: String

  @Option(
    name: .long,
    help:
      "GitHub Personal Access Token for API authentication (if not provided, will use GITHUB_TOKEN)"
  )
  var githubToken: String?

  @Option(
    name: .long,
    help: "Path to drift_detector YAML configuration file (default: config.yaml)"
  )
  var config: String = "config.yaml"

  @Option(
    name: .long,
    help: "Logging level (default: info)"
  )
  var logLevel: String = "info"

  func setLogLevel(from string: String) -> Logger.Level {
    return Logger.Level(rawValue: string.lowercased()) ?? .info
  }

  // ParsableArguments protocol.validate()
  func validate() throws {
    guard !context.isEmpty else {
      throw ValidationError("At least one context must be specified with --context")
    }

    guard !namespace.isEmpty else {
      throw ValidationError("Namespace must be specified with --namespace")
    }

    // Validate context format for each context
    for contextString in context {
      let components =
        contextString
        .split(separator: "=", maxSplits: 1)
        .map { $0.trimmingCharacters(in: .whitespaces) }

      guard components.count == 2 else {
        throw ValidationError("Context format must be 'context=alias', got: \(contextString)")
      }

      let contextName = components[0]
      let alias = components[1]

      guard !contextName.isEmpty && !alias.isEmpty else {
        throw ValidationError("Both context and alias must be non-empty in: \(contextString)")
      }
    }

    // Check GitHub token from parameter or environment
    guard let token = githubToken ?? ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
      !token.isEmpty
    else {
      throw ValidationError(
        "GitHub token must be provided via --github_token or GITHUB_TOKEN environment variable")
    }
  }

  mutating func run() async throws {
    let contextAliases = context.map { contextString in
      let components = contextString.split(separator: "=", maxSplits: 1)
      let contextName = components[0].trimmingCharacters(in: .whitespaces)
      let alias = components[1].trimmingCharacters(in: .whitespaces)
      return ContextAlias(context: contextName, alias: alias)
    }

    // Get GitHub token from parameter or environment (validated above)
    let githubToken = self.githubToken ?? ProcessInfo.processInfo.environment["GITHUB_TOKEN"]!

    do {
      let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
      let driftAnalyzer = DriftAnalyzer(
        contexts: contextAliases,
        namespace: namespace,
        githubToken: githubToken,
        configPath: config,
        logLevel: setLogLevel(from: logLevel),
        eventLoopGroup: eventLoopGroup
      )

      try await driftAnalyzer.analyze()
      try await eventLoopGroup.shutdownGracefully()
    } catch {
      print("Error: \(error.localizedDescription)")
      throw ExitCode.failure
    }
  }
}

struct ContextAlias {
  let context: String
  let alias: String

  init(context: String, alias: String) {
    self.context = context
    self.alias = alias
  }
}

struct ValidationError: Error, LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? {
    return message
  }
}

struct RuntimeError: Error, LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? {
    return message
  }
}
