import Foundation
import SemVer
import Logging

struct GitHubRelease: Sendable {
    let tagVersion: SemVer.Version
    let createdAt: Date
    let isPrerelease: Bool
}

struct GitHubTag: Sendable {
    let tagVersion: SemVer.Version
    let date: Date
}


final class GitHubClient: Sendable {
    private let token: String
    private let config: Configuration.GitHubConfig
    private let session: URLSession
    private let logger: Logger
    
    enum GitHubError: Error, LocalizedError {
        case invalidURL(String)
        case authenticationFailed
        case repositoryNotFound(String)
        case apiError(Int, String)
        case networkError(Error)
        case parsingError(String)
        case rateLimitExceeded
        case noReleasesFound(String)
        
        // var errorDescription: String? {
        //     switch self {
        //     case .invalidURL(let url):
        //         return "Invalid GitHub URL: \(url)"
        //     case .authenticationFailed:
        //         return "GitHub authentication failed. Please check your token."
        //     case .repositoryNotFound(let repo):
        //         return "GitHub repository not found: \(repo)"
        //     case .apiError(let code, let message):
        //         return "GitHub API error (\(code)): \(message)"
        //     case .networkError(let error):
        //         return "Network error: \(error.localizedDescription)"
        //     case .parsingError(let message):
        //         return "Error parsing GitHub response: \(message)"
        //     case .rateLimitExceeded:
        //         return "GitHub API rate limit exceeded. Please wait before making more requests."
        //     case .noReleasesFound(let repo):
        //         return "No valid releases found for repository: \(repo)"
        //     }
        // }
    }
    
    init(token: String, config: Configuration.GitHubConfig, logger: Logger) {
        self.token = token
        self.config = config
        self.session = URLSession.shared
        self.logger = logger
    }
    
    func getReleases(for repository: String, config: Configuration.GitHubConfig) async throws -> [GitHubRelease] {
        logger.debug("Querying releases for \(repository)")
        let releases = try await getRepositoryReleases(config: config, repository: repository)
        if !releases.isEmpty && releases.count >= config.historyCount {
            logger.debug("Found \(releases.count) releases for \(repository)")
            return releases
        }

        // should cater to both lightweight and annotated tags
        let tags = try await getRecentTagsQL(config: config, repository: repository)
        if !tags.isEmpty {
            logger.debug("Found \(tags.count) tags for \(repository)")
            return tags.map { GitHubRelease(tagVersion: $0.tagVersion, createdAt: $0.date, isPrerelease: false) }
        }

        return []
    }

    private func getRepositoryReleases(config: Configuration.GitHubConfig, repository: String) async throws -> [GitHubRelease] {
        let url = "\(config.api.sanitizedBaseUrl)/repos/\(config.api.organization)/\(repository)/releases"
        guard let requestURL = URL(string: url) else {
            throw GitHubError.invalidURL(url)
        }
        
        let request = URLRequest(url: requestURL)
        let releases: [GitHubReleaseResponse] = try await executeGitHubRequest(request: request)
        print("releases: \(releases.count) \(repository)")
        
        return releases.map { release in
            GitHubRelease(
                tagVersion: Self.vSafeVersion(from: release.tagName) ?? SemVer.Version(major: 0, minor: 0, patch: 0),
                createdAt: parseISO8601Date(release.createdAt) ?? Date.distantFuture,
                isPrerelease: release.prerelease
            )
        }
        .sorted { $0.createdAt > $1.createdAt } // newest first
    }

    public func getRecentTagsQL(
        config: Configuration.GitHubConfig,
        repository: String,
        count: Int = 30
    ) async throws -> [GitHubTag] {
        let query = """
        query GetTags($owner: String!, $repo: String!) {
            repository(owner: $owner, name: $repo) {
                refs(refPrefix: "refs/tags/", first: \(count), orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
                    nodes {
                        name
                        target {
                            ... on Commit {
                                committedDate
                            }
                            ... on Tag {
                                tagger {
                                    date
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        
        let variables: [String: String] = [
            "owner": config.api.organization,
            "repo": repository
        ]
        
        let body: [String: Any] = [
            "query": query,
            "variables": variables
        ]
        
        let jsonBody = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: config.api.graphQLUrl)!)
        request.httpMethod = "POST"
        request.httpBody = jsonBody

        let graphQLResponse: GraphQLResponse = try await executeGitHubRequest(request: request) //try decoder.decode(GraphQLResponse.self, from: data)
        
        let tags: [GitHubTag] = 
            graphQLResponse.data.repository.refs.nodes
                .compactMap { ref in
                    let date: Date
                    if let commitDate = ref.target.committedDate {
                        date = commitDate
                    } else if let taggerDate = ref.target.tagger?.date {
                        date = taggerDate
                    } else {
                        date = Date.distantPast // we'd rather include an obviously old date than skip it
                    }
                    return Self.vSafeVersion(from: ref.name).map { GitHubTag(tagVersion: $0, date: date) }
                } 
                .sorted { $0.date > $1.date }
                
        let tagsDeduped = tags.reduce(into: [GitHubTag]()) { z, t in
            if !z.contains(where: { $0.tagVersion == t.tagVersion }) { 
                z.append(t)
            }

        }

        return tagsDeduped
    }  

    private func executeGitHubRequest<T: Decodable>(request: URLRequest) async throws -> T {
        var request = request // shadow and make a mutable copy
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("DriftDetector/1.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitHubError.networkError(URLError(.badServerResponse))
            }
            
            switch httpResponse.statusCode {
                case 200:
                    break
                case 401:
                    throw GitHubError.authenticationFailed
                case 403:
                    if httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                        throw GitHubError.rateLimitExceeded
                    }
                    throw GitHubError.authenticationFailed
                case 404:
                    throw GitHubError.repositoryNotFound(request.url?.absoluteString ?? "unknown")
                default:
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw GitHubError.apiError(httpResponse.statusCode, errorMessage)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withTimeZone]
            let remaining = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") ?? "9999"
            let rateLimitReset = Date(timeIntervalSince1970: TimeInterval(Int(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "0") ?? 0))
            logger.debug("\(remaining) remaining requests from GitHub GraphQL API, rate limit resets at \(formatter.string(from: rateLimitReset))")
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            return try decoder.decode(T.self, from: data)
            
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.networkError(error)
        }
    }

    /// Parse ISO8601 date string
    private func parseISO8601Date(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        // Fallback without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }

    public static func vSafeVersion(from version: String) -> SemVer.Version? {
        return SemVer.Version(String(version.trimmingCharacters(in: .whitespacesAndNewlines).drop { !$0.isNumber }))
    }
}

struct GitHubReleaseResponse: Codable {
    let tagName: String
    let createdAt: String
    let publishedAt: String
    let draft: Bool
    let prerelease: Bool
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case draft
        case prerelease
    }
}

struct GitHubTagResponse: Codable {
    let name: String
    let commit: GitHubTagCommit
}

struct GitHubTagCommit: Codable {
    let sha: String
}

struct GitHubCommitResponse: Codable {
    let commit: GitHubCommitData
}

struct GitHubCommitData: Codable {
    let author: GitHubCommitAuthor
}

struct GitHubCommitAuthor: Codable {
    let date: String
} 

struct GraphQLResponse: Decodable {
    let data: RepositoryData
}

struct RepositoryData: Decodable {
    let repository: Repository
}

struct Repository: Decodable {
    let refs: Refs
}

struct Refs: Decodable {
    let nodes: [Ref]
}

struct Ref: Decodable {
    let name: String
    let target: Target
}

struct Target: Decodable {
    let committedDate: Date?
    let tagger: Tagger?
    
    struct Tagger: Decodable {
        let date: Date
    }
    
    // Custom init to handle union types
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        committedDate = try container.decodeIfPresent(Date.self, forKey: .committedDate)
        tagger = try container.decodeIfPresent(Tagger.self, forKey: .tagger)
    }
    
    enum CodingKeys: String, CodingKey {
        case committedDate
        case tagger
    }
}  