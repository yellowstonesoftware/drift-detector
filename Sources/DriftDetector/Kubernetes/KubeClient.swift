import AsyncHTTPClient
import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOSSL
import SwiftkubeModel

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum KubernetesAPIError: Error {
  case invalidURL
  case connectionError(Error)
  case badResponse(statusCode: Int)
  case decodingError(Error)
}

struct DeploymentInfo {
  let appName: String
  let version: String
  let deploymentDate: Date
  let context: String
  let replicas: Int32  // UInt16 would make more sense but alas this is what we get from SwiftkubeModel
}

func getDeployments(
  context: String,
  namespace: String,
  appConfig: Configuration.KubernetesConfig,
  clientConfig: KubernetesClientConfig,
  eventLoopGroup: EventLoopGroup
) async throws -> [DeploymentInfo] {
  let logger = LoggingKit.logger()
  do {
    let labelSelectors = appConfig.service.selector.flatMap {
      $0.map { key, values in
        ListOption.labelSelector(.in([key: values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }]))
      }
    }

    logger.debug("finding Deployments in namespace: [\(namespace)] with labelSelectors: [\(labelSelectors)]")
    let deployments: SwiftkubeModel.apps.v1.DeploymentList =
      try await executeK8sRequest(
        clientConfig: clientConfig,
        path: "/apis/apps/v1/namespaces/\(namespace)/deployments",
        selectors: labelSelectors,
        eventLoopGroup: eventLoopGroup,
        logger: logger
      ) ?? SwiftkubeModel.apps.v1.DeploymentList(items: [apps.v1.Deployment]())

    let deploymentInfos = deployments.items.map { deployment in
      let version = deployment.spec?.template.metadata?.labels?.first { $0.key.caseInsensitiveCompare("version") == .orderedSame }?.value
      let deploymentDate = deployment.status?.conditions?.first { $0.type == "Progressing" && $0.lastTransitionTime != nil }?.lastUpdateTime
      let appName = deployment.metadata?.labels?
        .first { $0.key.caseInsensitiveCompare("app") == .orderedSame }?
        .value ?? deployment.metadata?.name
      let replicas = deployment.spec?.replicas ?? 0
      
      return DeploymentInfo(
        appName: appName ?? "<unknown>",
        version: version ?? "<unknown>",
        deploymentDate: deploymentDate ?? Date.distantPast,
        context: context,
        replicas: replicas
      )
    }.grouped(by: { $0.appName })

    let rolloutDeploymentInfos = if appConfig.argoIsEnabled() {
      try await fetchRollouts(
        context: context,
        namespace: namespace,
        appConfig: appConfig,
        clientConfig: clientConfig,
        eventLoopGroup: eventLoopGroup,
        logger: logger
      )
    } else {
      [String : [DeploymentInfo]]()
    }
    
    logger.debug("found \(deploymentInfos.count) deployments and \(rolloutDeploymentInfos.count) rollouts")

    return deploymentInfos.merging(rolloutDeploymentInfos) { left, right in
      let leftAndRight = left + right
      return [
        leftAndRight
          .filter { $0.replicas > 0 }
          .sorted { $0.deploymentDate > $1.deploymentDate }
          .first ?? leftAndRight.sorted { $0.deploymentDate > $1.deploymentDate }.first!
      ]
    }.values.flatMap { $0 }
  } catch {
    throw error
  }
}

internal func fetchRollouts(
  context: String,
  namespace: String,
  appConfig: Configuration.KubernetesConfig,
  clientConfig: KubernetesClientConfig,
  eventLoopGroup: EventLoopGroup,
  logger: Logger
) async throws -> [String: [DeploymentInfo]] {

  let labelSelectors = appConfig.argo?.selector?.flatMap {
    $0.map { key, values in
      ListOption.labelSelector(.in([key: values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }]))
    }
  } ?? [ListOption]()

  logger.debug("finding Rollouts in namespace: (\(namespace)) with labelSelectors: \(labelSelectors)")
  let rollouts: argoproj.v1alpha1.RolloutList =
  try await executeK8sRequest(
    clientConfig: clientConfig,
    path: "/apis/argoproj.io/v1alpha1/namespaces/\(namespace)/rollouts",
    selectors: [],
    eventLoopGroup: eventLoopGroup,
    logger: logger
  ) ?? argoproj.v1alpha1.RolloutList(items: [])
  
  return rollouts.items.map { rollout in
    let version = rollout.spec?.template.metadata?.labels?.first { $0.key.caseInsensitiveCompare("version") == .orderedSame }?.value
    let deploymentDate = rollout.status?.conditions?.first { $0.type == "Progressing" && $0.lastTransitionTime != nil }?.lastUpdateTime
    let appName = rollout.metadata?.labels?
      .first { $0.key.caseInsensitiveCompare("app") == .orderedSame }?
      .value ?? rollout.metadata?.name
    let replicas = rollout.spec?.replicas ?? 0
    
    return DeploymentInfo(
      appName: appName ?? "<unknown>",
      version: version ?? "<unknown>",
      deploymentDate: deploymentDate ?? Date.distantPast,
      context: context,
      replicas: replicas
    )
  }.grouped(by: { $0.appName })
}

internal func executeK8sRequest<T: Decodable & KubernetesResourceList>(
  clientConfig: KubernetesClientConfig,
  path: String,
  selectors: [ListOption],
  eventLoopGroup: EventLoopGroup,
  logger: Logger
) async throws -> T? {
  func decodeResponseBody(_ body: HTTPClientResponse.Body, logger: Logger) async throws -> T? {
    var bodyA = [UInt8]()
    for try await buffer in body {
      bodyA.append(contentsOf: buffer.readableBytesView)
    }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601  // Kubernetes uses ISO 8601 for dates

      let resources = try decoder.decode(T.self, from: Data(bodyA))
      return resources
    } catch {
      throw KubernetesAPIError.decodingError(error)
    }
  }

  let queryItemsForSelectors =
   selectors
    .map { s in [s.name: s.value] }
    .flatMap { dict in dict.map { URLQueryItem(name: $0.key, value: $0.value) } }

  guard var urlComponents = URLComponents(url: clientConfig.apiURL, resolvingAgainstBaseURL: false) else {
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
  request.headers.add(name: "User-Agent", value: "DriftDetector/1.0")
  clientConfig.authentication.authorizationHeaderValue().map {
    request.headers.add(name: "Authorization", value: $0)
  }
  request.headers.add(name: "Accept", value: "application/json")

  var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
  clientConfig.trustRoots.map { tlsConfiguration.trustRoots = $0 }
  tlsConfiguration.certificateVerification =
    clientConfig.insecureSkipTLSVerify ? .none : .fullVerification
  logger.debug("tlsConfiguration: \(tlsConfiguration)")

  let client = HTTPClient(
    eventLoopGroupProvider: .shared(eventLoopGroup),
    configuration: HTTPClient.Configuration(
      tlsConfiguration: tlsConfiguration,
      redirectConfiguration: .follow(max: 5, allowCycles: false)
    )
  )

  do {
    let response = try await client.execute(request, timeout: .seconds(30))
    switch response.status {
    case .ok:
      logger.debug("found resources at path [\(path)] with selectors [\(selectors)]")
      let resources = try await decodeResponseBody(response.body, logger: logger)
      try await client.shutdown().get()
      return resources

    case .notFound:
      logger.warning("found no resources at path [\(path)] with selectors [\(selectors)]")
      try await client.shutdown().get()
      return nil

    default:
      try await client.shutdown().get()
      throw URLError(.badServerResponse)
    }
  } catch {
    logger.error("Error listing deployments: \(error)")
    try await client.shutdown().get()
    throw KubernetesAPIError.connectionError(error)
  }
}
