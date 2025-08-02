import Foundation
import SemVer

struct AppDriftInfo {
    let appName: String
    let deployments: [String: DeploymentVersionInfo] // Context alias -> deployment info
    let latestRelease: GitHubRelease?
    
    struct DeploymentVersionInfo {
        let version: String
        let deploymentDate: Date
        let releasesSinceDeployment: Int?
    }
}

class VersionLogic {
    
    static func calculateDrift(
        deploymentsByContext: [String: [DeploymentInfo]], // context alias -> deployments
        githubReleases: [String: [GitHubRelease]], // appName -> releases
        serviceMappings: [String: String], // appName -> repository name
        configuration: Configuration 
    ) -> [AppDriftInfo] {
        
        let allApps = Set(deploymentsByContext.values.flatMap { deployments in
            deployments.map { $0.appName }
        })
        
        let appDriftInfos: [AppDriftInfo] = allApps.compactMap { appName in
            let releases = githubReleases[appName] ?? []
            let latestRelease = releases.first
            
            let deployments: [String: AppDriftInfo.DeploymentVersionInfo] = 
                Dictionary(uniqueKeysWithValues: deploymentsByContext.compactMap { contextAlias, deployments in
                    guard let deployment = deployments.first(where: { $0.appName == appName }) else {
                        return nil
                    }
                    
                    let releasesSince = calculateReleaseDriftCount(
                        deployedVersion: deployment.version,
                        releases: releases
                    )
                    
                    return (contextAlias, AppDriftInfo.DeploymentVersionInfo(
                        version: deployment.version,
                        deploymentDate: deployment.deploymentDate,
                        releasesSinceDeployment: releasesSince
                    ))
                })
            
            // Only include apps with non-empty deployments
            guard !deployments.isEmpty else {
                return nil
            }
            
            return AppDriftInfo(
                appName: appName,
                deployments: deployments,
                latestRelease: latestRelease
            )
        }        
        // Sort by app name for consistent output
        return appDriftInfos.sorted { $0.appName < $1.appName }
    }
    
    private static func calculateReleaseDriftCount(
        deployedVersion: String,
        releases: [GitHubRelease]
    ) -> Int? {
        guard let deployedSemVer = GitHubClient.vSafeVersion(from: deployedVersion), !releases.isEmpty else {
            return nil // Invalid target version
        }
        // drop any prerelease from the deployed version before comparison
        var deployedSemVerWithoutPrerelease: SemVer.Version = deployedSemVer
        deployedSemVerWithoutPrerelease.prerelease = []

        let count: Int = releases.prefix(while: { $0.tagVersion > deployedSemVerWithoutPrerelease }).count
        if (count == releases.count && releases.last?.tagVersion != nil && 
            releases.last!.tagVersion > deployedSemVerWithoutPrerelease) {
                return Int.max
        }

        return count
    }
    
    static func getDriftColor(for releaseCount: Int?) -> ANSIColor {
        guard let count = releaseCount else {
            return .default // Unknown drift
        }
        
        switch count {
            case 0:
                return .green
            case 1...10:
                return .yellow
            case 11...20:
                return .red
            default:
                return .blinkingRed
        }
    }
    
    static func getDriftIndicator(for releaseCount: Int?, releaseCountLimit: Int = 30) -> String {
        guard let count = releaseCount else {
            return ANSIColor.default.colorize("[Unknown]")
        }
        
        let color = getDriftColor(for: count)
        let displayedCount: String = count == Int.max ? ">\(releaseCountLimit)" : String(count)
        return color.colorize("[\(displayedCount)]")
    }

    static func vSafeVersion(_ version: String) -> SemVer.Version? {
        return SemVer.Version(String(version.trimmingCharacters(in: .whitespacesAndNewlines).drop { !$0.isNumber }))
    }
}

enum ANSIColor: String {
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case red = "\u{001B}[31m"
    case blinkingRed = "\u{001B}[1;31m"
    case reset = "\u{001B}[0m"
    case `default` = ""
    
    func colorize(_ text: String) -> String {
        if self == .default {
            return text
        }
        return rawValue + text + ANSIColor.reset.rawValue
    }
} 