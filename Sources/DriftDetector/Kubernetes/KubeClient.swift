import Foundation
#if canImport(FoundationNetworking)   
import FoundationNetworking 
#endif
import Logging
import SwiftkubeModel  
import NIO
import NIOHTTP1
import AsyncHTTPClient
import NIOSSL

enum KubernetesAPIError: Error {
    case invalidURL
    case badResponse(statusCode: Int)
    case decodingError(Error)
}

struct DeploymentInfo {
    let appName: String
    let version: String
    let deploymentDate: Date
    let context: String
}

func getDeployments(
    context: String, 
    namespace: String, 
    appConfig: Configuration.KubernetesConfig,
    clientConfig: KubernetesClientConfig,
    logger: Logger,
    eventLoopGroup: EventLoopGroup
) async throws -> [DeploymentInfo] {
   do {
      let labelSelectors = appConfig.service.selector.flatMap { 
          $0.map { key, values in
              ListOption.labelSelector(.in([key: values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }]))
          }
      }

      logger.debug("find Deployments in namespace: [\(namespace)] with labelSelectors: [\(labelSelectors)]")
      let deployments = try await listDeployments(
        clientConfig: clientConfig,
        namespace: namespace,
        selectors: labelSelectors,
        eventLoopGroup: eventLoopGroup
      )

      let deploymentInfos = deployments.items.map { deployment in
          let version = deployment.spec?.template.metadata?.labels?.first { $0.key.caseInsensitiveCompare("version") == .orderedSame }?.value
          let deploymentDate = deployment.status?.conditions?.first { $0.type == "Progressing" && $0.lastTransitionTime != nil }?.lastUpdateTime
          let appName = deployment.metadata?.labels?.first { $0.key.caseInsensitiveCompare("app") == .orderedSame }?.value ?? deployment.metadata?.name 
          return  DeploymentInfo(
              appName: appName ?? "<unknown>",
              version: version ?? "<unknown>",
              deploymentDate: deploymentDate ?? Date.distantPast,
              context: context
          )
      }
      
      return deploymentInfos
  } catch {
    throw error
  }
}

internal func listDeployments(
    clientConfig: KubernetesClientConfig,
    namespace: String,
    selectors: [ListOption],
    eventLoopGroup: EventLoopGroup
) async throws -> SwiftkubeModel.apps.v1.DeploymentList {
    var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
    tlsConfiguration.certificateVerification = clientConfig.insecureSkipTLSVerify ? .none : .fullVerification

    let client = HTTPClient(
        eventLoopGroupProvider: .shared(eventLoopGroup),
        configuration: HTTPClient.Configuration(
            tlsConfiguration: tlsConfiguration,
            redirectConfiguration: .follow(max: 5, allowCycles: false)  
        )
    )
    
    let path = "/apis/apps/v1/namespaces/\(namespace)/deployments"
    let queryItemsForSelectors = selectors
        .map { s in [s.name: s.value] }
        .flatMap { dict in dict.map { URLQueryItem(name: $0.key, value: $0.value) } }
        
    guard var urlComponents = URLComponents(url: clientConfig.masterURL, resolvingAgainstBaseURL: false) else {
        throw KubernetesAPIError.invalidURL
    }
    urlComponents.path = path.starts(with: "/") ? path : "/\(path)"
    urlComponents.queryItems = queryItemsForSelectors
    
    guard let url = urlComponents.url else {
        throw KubernetesAPIError.invalidURL
    }
    
    // Create the request immutably
    var request = HTTPClientRequest(url: url.absoluteString)
    request.method = .GET
    request.headers.add(name: "User-Agent", value: "SwiftAsyncHTTPClient/1.0")
    clientConfig.authentication.authorizationHeaderValue().map { request.headers.add(name: "Authorization", value: $0) }
    request.headers.add(name: "Accept", value: "application/json")
    
    let response = try await client.execute(request, timeout: .seconds(30))
    
    // Check the response status
    guard response.status == .ok else {
        throw URLError(.badServerResponse)
    }
    
    // Collect the response body as a string
    var body = [UInt8]()
    for try await buffer in response.body {
        body.append(contentsOf: buffer.readableBytesView)
    }    
    // Decode the response
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601  // Kubernetes uses ISO 8601 for dates
    
    do {
        let deploymentList = try decoder.decode(SwiftkubeModel.apps.v1.DeploymentList.self, from: Data(body))
        try await client.shutdown().get()
        return deploymentList
    } catch {
        throw KubernetesAPIError.decodingError(error)
    }
}
