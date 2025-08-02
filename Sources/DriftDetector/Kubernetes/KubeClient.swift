import AsyncHTTPClient
import Foundation
import Logging
import SwiftkubeModel  
import NIOHTTP1

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
    logger: Logger
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
        selectors: labelSelectors
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
    selectors: [ListOption]
) async throws -> SwiftkubeModel.apps.v1.DeploymentList {
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
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(clientConfig.authentication.authorizationHeaderValue(), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    
    // Perform the network request
    let session = clientConfig.insecureSkipTLSVerify ?  
        URLSession(
            configuration: .default,
            delegate: InsecureURLSessionDelegate(),
            delegateQueue: nil
        ) : .shared

    let (data, response) = try await session.data(for: request)
    
    // Validate the response
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw KubernetesAPIError.badResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
    
    // Decode the response
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601  // Kubernetes uses ISO 8601 for dates
    
    do {
        let deploymentList = try decoder.decode(SwiftkubeModel.apps.v1.DeploymentList.self, from: data)
        return deploymentList
    } catch {
        throw KubernetesAPIError.decodingError(error)
    }
}

private final class InsecureURLSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Check if the challenge is for server trust (TLS)
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            // Fall back to default handling for other challenges
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Blindly trust the server certificate (insecure)
        let credential = URLCredential(trust: serverTrust)
        completionHandler(.useCredential, credential)
    }
}
