import Foundation
import Logging

class DriftAnalyzer {
    private let contexts: [ContextAlias]
    private let namespace: String
    private let githubToken: String
    private let configPath: String
    private let logger: Logger
    
    enum DriftAnalyzerError: Error, LocalizedError {
        case configurationError(String)
        case analysisError(String)
        case noAppsFound
        
        // effectively immutable since no setter is provided
        var errorDescription: String? {
            switch self {
            case .configurationError(let message):
                return "Configuration error: \(message)"
            case .analysisError(let message):
                return "Analysis error: \(message)"
            case .noAppsFound:
                return "No applications found in any of the specified contexts and namespace"
            }
        }
    }
    
    init(contexts: [ContextAlias], namespace: String, githubToken: String, configPath: String, logLevel: Logger.Level) {
        self.contexts = contexts
        self.namespace = namespace
        self.githubToken = githubToken
        self.configPath = configPath
        
        var logger = Logger(label: "drift-detector")
        logger.logLevel = logLevel
        self.logger = logger
    }
    
    func analyze() async throws {
        logger.info("Starting drift analysis...")
        logger.info("Contexts: \(contexts.map { "\($0.context)=\($0.alias)" }.joined(separator: ", "))")
        logger.info("Namespace: \(namespace)")
        
        // Load YAML configuration file
        logger.info("Loading configuration from \(configPath)")
        let configuration: Configuration
        do {
            configuration = try ConfigurationManager.loadConfiguration(from: configPath)
        } catch {
            throw DriftAnalyzerError.configurationError(error.localizedDescription)
        }
        logger.debug("Configuration: \(configuration)")
        
        let serviceMappings = ConfigurationManager.parseServiceMappings(from: configuration)
        logger.debug("Loaded \(serviceMappings.count) service mappings")
        
        let githubClient = GitHubClient(token: githubToken, config: configuration.github, logger: logger)
        logger.debug("Initialized GitHub client with base URL: \(configuration.github.api.baseUrl)")
        
        logger.debug("Querying Kubernetes deployments concurrently...")
        var deploymentsByContext: [String: [DeploymentInfo]] = [:]
        
        let targetNamespace = namespace  // Capture as local constant
        await withTaskGroup(of: (String, [DeploymentInfo]).self) { taskGroup in
            for contextAlias in contexts {
                var logger = self.logger // make a mutable copy so we don't capture self in the closure
                logger[metadataKey: "k8s.context"] = .string(contextAlias.context) // mutable so we can add context
                taskGroup.addTask {
                    do {
                        guard let kubeConfig = try KubeConfig.fromLocalEnvironment(logger: logger) else {
                            throw DriftAnalyzerError.configurationError("No kubeconfig found")
                        }
                        guard let clientConfig = try KubernetesClientConfig.from(
                            kubeConfig: kubeConfig,
                            context: contextAlias.context, 
                            logger: logger
                        ) else {
                            throw DriftAnalyzerError.configurationError("Failed to create Kubernetes client config")
                        }

                        let deployments = try await getDeployments(
                            context: contextAlias.context,
                            namespace: targetNamespace,
                            appConfig: configuration.kubernetes,
                            clientConfig: clientConfig,
                            logger: logger
                        )
                        return (contextAlias.alias, deployments)
                    } catch {
                        // Return empty array on error, will be logged when collecting results
                        logger.error("Failed to get deployments for \(contextAlias.context): \(error.localizedDescription)")
                        return (contextAlias.alias, [])
                    }
                }
            }
            
            // Collect results from all contexts
            for await (contextAlias, deployments) in taskGroup {
                deploymentsByContext[contextAlias] = deployments
                logger.info("Found \(deployments.count) deployments in \(contextAlias)")
                
                for deployment in deployments {
                    logger.debug("\t- \(deployment.appName): \(deployment.version)")
                }
            }
        }
        
        // Get unique apps across all contexts
        let allApps = Set(deploymentsByContext.values.flatMap { deployments in
            deployments.map { $0.appName }
        })
        logger.debug("Found \(allApps.count) unique applications across all contexts")
        
        guard !allApps.isEmpty else {
            throw DriftAnalyzerError.noAppsFound
        }
        
        // Get concurrency limit from configuration
        let concurrencyLimit = configuration.github.api.concurrency
        logger.debug("Using concurrency limit of \(concurrencyLimit) for GitHub API calls")
        
        // Process GitHub API calls in batches to control concurrency
        let batches = Array(allApps).chunked(into: concurrencyLimit)
        
        logger.info("Querying GitHub releases for \(allApps.count) unique applications")
        var githubReleases: [String: [GitHubRelease]] = [:] // appName -> releases
        for batch in batches {
            await withTaskGroup(of: (String, [GitHubRelease]).self) { taskGroup in
                for appName in batch {
                    taskGroup.addTask { [githubClient, logger] in
                        let repository = serviceMappings[appName] ?? appName
                        do {
                            let releases = try await githubClient.getReleases(for: repository, config: configuration.github)
                            return (appName, releases)
                        } catch {
                            logger.warning("Failed to get releases for \(repository): \(error.localizedDescription)")
                            return (appName, [])
                        }
                    }
                }
                
                // Collect results from this batch
                for await (appName, releases) in taskGroup {
                    githubReleases[appName] = releases
                }
            }
        }
        
        logger.info("Calculating version drift...")
        let appDriftInfos = VersionLogic.calculateDrift(
            deploymentsByContext: deploymentsByContext,
            githubReleases: githubReleases,
            serviceMappings: serviceMappings,
            configuration: configuration
        )
        
        displayResults(appDriftInfos: appDriftInfos)
    }
    
    private func displayResults(appDriftInfos: [AppDriftInfo]) {
        if appDriftInfos.isEmpty {
            logger.error("No application drift results found")
            return
        }
        
        let contextAliases = contexts.map { $0.alias }
        
        // Calculate table width to match the actual table
        let tableWidth = calculateTableWidth(appDriftInfos: appDriftInfos, contextAliases: contextAliases)
        
        print("\n" + "=".repeated(tableWidth))
        
        // Center the title within the table width
        let title = "DRIFT DETECTION RESULTS"
        let titlePadding = max(0, tableWidth - title.count)
        let leftPad = titlePadding / 2
        let rightPad = titlePadding - leftPad
        print(String(repeating: " ", count: leftPad) + title + String(repeating: " ", count: rightPad))
        
        print("=".repeated(tableWidth))
        
        // Format and display table
        let table = appDriftInfos.formatAsTable(contextAliases: contextAliases)
        print(table)
        
        // Display summary statistics
        displaySummaryStats(appDriftInfos: appDriftInfos, contextAliases: contextAliases)
    }
    
    private func calculateTableWidth(appDriftInfos: [AppDriftInfo], contextAliases: [String]) -> Int {
        // Calculate column widths (this mirrors the logic in TableFormatter)
        var totalWidth = 0
        
        // App Name column width
        let appNameWidth = max(
            "App Name".count,
            appDriftInfos.map { $0.appName.count }.max() ?? 0
        ) + 2 // Add padding
        totalWidth += appNameWidth
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        // Context columns widths
        for alias in contextAliases {
            var maxWidth = alias.count
            
            for appInfo in appDriftInfos {
                if let deployment = appInfo.deployments[alias] {
                    // Calculate the combined line format (similar to TableFormatter)
                    let dateString = dateFormatter.string(from: deployment.deploymentDate)
                    let driftIndicator = VersionLogic.getDriftIndicator(for: deployment.releasesSinceDeployment)
                    let combinedLine = "\(deployment.version) (\(dateString)) \(driftIndicator)"
                    
                    // Strip ANSI codes for accurate width calculation
                    let displayWidth = stripANSI(combinedLine).count
                    maxWidth = max(maxWidth, displayWidth)
                }
            }
            
            totalWidth += maxWidth + 2 // Add padding
        }
        
        var githubWidth = "GitHub Latest Release".count
        for appInfo in appDriftInfos {
            if let latestRelease = appInfo.latestRelease {
                let dateString = dateFormatter.string(from: latestRelease.createdAt)
                let releaseLine = "\(latestRelease.tagVersion.versionString(formattedWith: [])) (\(dateString))"
                githubWidth = max(githubWidth, releaseLine.count)
            }
        }
        totalWidth += githubWidth + 2 // Add padding
        
        let numberOfColumns = 2 + contextAliases.count // App Name + contexts + GitHub
        totalWidth += numberOfColumns + 1 // +1 for the final "|"
        
        return totalWidth
    }
    
    private func stripANSI(_ text: String) -> String {
        let ansiPattern = "\\x1B\\[[0-9;]*[a-zA-Z]"
        let regex = try? NSRegularExpression(pattern: ansiPattern, options: [])
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex?.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "") ?? text
    }
    
    private func displaySummaryStats(appDriftInfos: [AppDriftInfo], contextAliases: [String]) {
        print("\nSummary:")
        print("  Total applications: \(appDriftInfos.count)")
        
        for alias in contextAliases {
            let deploymentsInContext = appDriftInfos.compactMap { $0.deployments[alias] }
            let upToDate = deploymentsInContext.filter { $0.releasesSinceDeployment == 0 }.count
            let behind = deploymentsInContext.filter { ($0.releasesSinceDeployment ?? 0) > 0 }.count
            let unknown = deploymentsInContext.filter { $0.releasesSinceDeployment == nil }.count
            
            print("  \(alias): \(deploymentsInContext.count) apps " +
                  "(\(upToDate) up-to-date, \(behind) behind, \(unknown) unknown)")
        }
        
        let appsWithUnknownVersions = appDriftInfos.filter { appInfo in
            appInfo.deployments.values.contains { $0.releasesSinceDeployment == nil }
        }
        
        if !appsWithUnknownVersions.isEmpty {
            print("\nApps with unknown versions (not found in GitHub):")
            for appInfo in appsWithUnknownVersions {
                for (context, deployment) in appInfo.deployments {
                    if deployment.releasesSinceDeployment == nil {
                        print("  - \(appInfo.appName) (\(context)): \(deployment.version)")
                    }
                }
            }
        }
    }
}

extension String {
    func repeated(_ count: Int) -> String {
        return String(repeating: self, count: count)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
} 