import Foundation

class TableFormatter {
    private static let dateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    static func formatTable(appDriftInfos: [AppDriftInfo], contextAliases: [String]) -> String {
        guard !appDriftInfos.isEmpty else {
            return "No applications found in the specified namespace."
        }
        
        let columnWidths = calculateColumnWidths(appDriftInfos: appDriftInfos, contextAliases: contextAliases)
        
        var table = ""

        table += createHeaderRow(contextAliases: contextAliases, columnWidths: columnWidths)
        table += "\n"
        
        table += createSeparatorRow(columnWidths: columnWidths)
        table += "\n"
        
        for appInfo in appDriftInfos {
            table += createDataRow(appInfo: appInfo, contextAliases: contextAliases, columnWidths: columnWidths)
            table += "\n"
        }
        
        table += createSeparatorRow(columnWidths: columnWidths)
        
        return table
    }
    
    private static func calculateColumnWidths(appDriftInfos: [AppDriftInfo], contextAliases: [String]) -> [Int] {
        var widths = [Int]()
        
        let appNameWidth = max(
            "App Name".count,
            appDriftInfos.map { $0.appName.count }.max() ?? 0
        )
        widths.append(appNameWidth + 2) // Add padding
        
        let contextWidths = contextAliases.map { alias in
            appDriftInfos
                .compactMap { appInfo in
                    appInfo.deployments[alias].map { deployment in
                        let combinedLine = formatCombinedLine(deployment)
                        
                        // Calculate display width (excluding ANSI codes)
                        return stripANSI(combinedLine).count
                    }
                }
                .reduce(alias.count) { max($0, $1) } + 2 // Add padding
        }
        widths.append(contentsOf: contextWidths)
        
        let githubWidth = appDriftInfos
            .compactMap { appInfo in
                appInfo.latestRelease.map { latestRelease in
                    stripANSI(formatLatestRelease(latestRelease)).count
                }
            }
            .reduce("GitHub Latest Release".count) { max($0, $1) }
        widths.append(githubWidth + 2) // Add padding
        
        return widths
    }
    
    private static func createHeaderRow(contextAliases: [String], columnWidths: [Int]) -> String {
        var headers = ["App Name"]
        headers.append(contentsOf: contextAliases)
        headers.append("GitHub Latest Release")
        
        var row = "|"
        for (index, header) in headers.enumerated() {
            let width = columnWidths[index]
            let padding = width - header.count
            
            // Left-justify headers
            row += " " + header + String(repeating: " ", count: padding - 1)
            row += "|"
        }
        
        return row
    }
    
    private static func createSeparatorRow(columnWidths: [Int]) -> String {
        var row = "+"
        for width in columnWidths {
            row += String(repeating: "-", count: width)
            row += "+"
        }
        return row
    }
    
    private static func createDataRow(appInfo: AppDriftInfo, contextAliases: [String], columnWidths: [Int]) -> String {
        var row = "|"
        
        let appNameWidth = columnWidths[0]
        row += padString(appInfo.appName, width: appNameWidth)
        row += "|"
        
        for (index, alias) in contextAliases.enumerated() {
            let width = columnWidths[index + 1]
            if let deployment = appInfo.deployments[alias] {
                let combinedLine = formatCombinedLine(deployment)
                row += padStringWithANSI(combinedLine, width: width)
            } else {
                row += padString("-", width: width)
            }
            row += "|"
        }
        
        let githubWidth = columnWidths.last ?? 0
        if let latestRelease = appInfo.latestRelease {
            let releaseLine = formatLatestRelease(latestRelease)
            row += padStringWithANSI(releaseLine, width: githubWidth)
        } else {
            row += padString("No releases found", width: githubWidth)
        }
        row += "|"
        
        return row
    }
    
    private static func formatCombinedLine(_ deployment: AppDriftInfo.DeploymentVersionInfo) -> String {
        let dateString = dateFormatter.string(from: deployment.deploymentDate)
        let driftIndicator = VersionLogic.getDriftIndicator(for: deployment.releasesSinceDeployment)
        return "\(deployment.version) (\(dateString)) \(driftIndicator)"
    }
    
    private static func formatLatestRelease(_ release: GitHubRelease) -> String {
        let dateString = dateFormatter.string(from: release.createdAt)
        return "\(release.tagVersion.versionString(formattedWith: [])) (\(dateString))"
    }
    
    private static func padString(_ text: String, width: Int) -> String {
        let padding = max(0, width - text.count)
        
        // Left-justify content
        return " " + text + String(repeating: " ", count: padding - 1)
    }
    
    private static func padStringWithANSI(_ text: String, width: Int) -> String {
        let displayText = stripANSI(text)
        let padding = max(0, width - displayText.count)
        
        // Left-justify content
        return " " + text + String(repeating: " ", count: padding - 1)
    }
    
    private static func stripANSI(_ text: String) -> String {
        // Remove ANSI escape sequences - use proper escape character pattern
        let ansiPattern = "\\x1B\\[[0-9;]*[a-zA-Z]"
        let regex = try? NSRegularExpression(pattern: ansiPattern, options: [])
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex?.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "") ?? text
    }
}

extension Array where Element == AppDriftInfo {
    func formatAsTable(contextAliases: [String]) -> String {
        return TableFormatter.formatTable(appDriftInfos: self, contextAliases: contextAliases)
    }
} 