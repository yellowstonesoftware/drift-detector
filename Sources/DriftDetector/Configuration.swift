import Foundation
import Yams
import Logging

struct Configuration: Codable {
  let github: GitHubConfig
  let kubernetes: KubernetesConfig

  struct GitHubConfig: Codable {
    let historyCount: Int
    let api: ApiConfig
    let services: [String]?

    struct ApiConfig: Codable {
      let baseUrl: String
      let organization: String
      let concurrency: Int

      enum CodingKeys: String, CodingKey {
        case baseUrl = "base_url"
        case organization
        case concurrency
      }
    }
    enum CodingKeys: String, CodingKey {
      case historyCount = "history_count"
      case api
      case services
    }
  }

  struct KubernetesConfig: Codable {
    let service: ServiceConfig
    let argo: ArgoConfig?

    struct ServiceConfig: Codable {
      let selector: [[String: [String]]]
      let filter: Set<String>?
    }
    
    struct ArgoConfig: Codable {
      let selector: [[String: [String]]]?
    }
    
    func argoIsEnabled() -> Bool {
      return argo != nil
    }
  }
}

extension Configuration.GitHubConfig.ApiConfig {
  var sanitizedBaseUrl: String {
    return baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
  var graphQLUrl: String {
    return sanitizedBaseUrl + "/graphql"
  }
}

public enum ConfigurationManager {
  private static let logger = LoggingKit.logger()

  enum ConfigurationError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidYAML(String)
    case missingApiConfig
    case missingBaseUrl
    case missingOrganization
    case parsingError(String)

    var errorDescription: String? {
      switch self {
      case .fileNotFound(let path):
        return "Configuration file not found at path: \(path)"
      case .invalidYAML(let message):
        return "Invalid YAML format: \(message)"
      case .missingApiConfig:
        return "Missing required 'api' section under 'github' in configuration"
      case .missingBaseUrl:
        return "Missing required 'base_url' field in github.api configuration"
      case .missingOrganization:
        return "Missing required 'organization' field in github.api configuration"
      case .parsingError(let message):
        return "Error parsing configuration: \(message)"
      }
    }
  }

  static func loadConfiguration(from path: String?) throws -> Configuration {
    let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { "\($0)/drift-detector/config.yaml" }
    let macConfig = ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.config/drift-detector/config.yaml" }
    guard let configPath: String = path ?? xdgConfig ?? macConfig else {
      throw ConfigurationError.fileNotFound(path ?? "~/.config/drift-detector/config.yaml")
    }
    guard FileManager.default.fileExists(atPath: configPath) else {
      throw ConfigurationError.fileNotFound(configPath)
    }

    Self.logger.info("Loading configuration from \(configPath)")
    let fileURL = URL(fileURLWithPath: configPath)
    do {
      let yamlContent = try String(contentsOf: fileURL, encoding: .utf8)
      let configuration = try YAMLDecoder().decode(Configuration.self, from: yamlContent)

      if configuration.github.api.baseUrl.isEmpty {
        throw ConfigurationError.missingBaseUrl
      }

      if configuration.github.api.organization.isEmpty {
        throw ConfigurationError.missingOrganization
      }

      return configuration
    } catch let yamlError as YamlError {
      throw ConfigurationError.invalidYAML(yamlError.localizedDescription)
    } catch let decodingError as DecodingError {
      throw ConfigurationError.parsingError(decodingError.localizedDescription)
    } catch {
      throw ConfigurationError.parsingError(error.localizedDescription)
    }
  }

  static func parseServiceMappings(from configuration: Configuration) -> [String: String] {  // app name -> repo name
    var mappings: [String: String] = [:]

    if let services = configuration.github.services {
      for service in services {
        let components = service.split(separator: "=", maxSplits: 1)
        if components.count == 2 {
          let appName = String(components[0]).trimmingCharacters(in: .whitespaces)
          let repoName = String(components[1]).trimmingCharacters(in: .whitespaces)
          mappings[appName] = repoName
        }
      }
    }

    return mappings
  }

  private static func getRepositoryBaseUrl(from apiBaseUrl: String) -> String {
    let cleanUrl = apiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    // Convert API URL to repository URL
    // https://api.github.com → https://github.com
    // https://api.github.enterprise.com → https://github.enterprise.com
    if cleanUrl.contains("api.github.com") {
      return cleanUrl.replacingOccurrences(of: "api.github.com", with: "github.com")
    } else if cleanUrl.contains("api.github.") {
      return cleanUrl.replacingOccurrences(of: "api.github.", with: "github.")
    } else {
      if cleanUrl.hasSuffix("/api") {
        return String(cleanUrl.dropLast(4))
      }
      return cleanUrl
    }
  }
}
