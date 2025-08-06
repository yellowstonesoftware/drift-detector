//
// Copyright 2020 Swiftkube Project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

// Copyright 2025 Yellowstone Software LLC 

import AsyncHTTPClient
import Foundation
import Logging
import NIOSSL
import Yams

// MARK: - KubernetesClientAuthentication

/// Supported client authentication schemes.
public enum KubernetesClientAuthentication: Sendable {
	/// Basic Authentincation via username/password.
	case basicAuth(username: String, password: String)
	/// Bearer token authentication scheme via a valid API token.
	case bearer(token: String)
	/// Certificate-based authenticaiton scheme with valid client certificate-key pair.
	case x509(clientCertificate: NIOSSLCertificate, clientKey: NIOSSLPrivateKey)

	internal func authorizationHeaderValue() -> String? {
		switch self {
		case let .basicAuth(username: username, password: password):
			return HTTPClient.Authorization.basic(username: username, password: password).headerValue
		case let .bearer(token: token):
			return HTTPClient.Authorization.bearer(tokens: token).headerValue
		default:
			return nil
		}
	}
}



// MARK: - KubernetesClientConfig

/// Configuration object for the ``KubernetesClient``
public struct KubernetesClientConfig: Sendable {

	/// The URL for the kuberentes API server.
	public let apiURL: URL
	/// The namespace for the current client context.
	public let namespace: String
	/// The ``KubernetesClientAuthentication`` scheme.
	public let authentication: KubernetesClientAuthentication
	/// NIOSSL trust store sources fot the client.
	public let trustRoots: NIOSSLTrustRoots?
	/// Skips TLS verification for all API requests.
	public let insecureSkipTLSVerify: Bool
	/// The default timeout configuration for the underlying `HTTPClient`.
	public let timeout: HTTPClient.Configuration.Timeout
	/// The default redirect configuration for the underlying `HTTPCLient`.
	public let redirectConfiguration:
		HTTPClient.Configuration.RedirectConfiguration
	/// URL to the proxy to be used for all requests made by this client.
	public let proxyURL: URL?
	/// Whether to request and decode gzipped responses from the API server.
	public let gzip: Bool

	public init(
		apiURL: URL,
		namespace: String,
		authentication: KubernetesClientAuthentication,
		trustRoots: NIOSSLTrustRoots?,
		insecureSkipTLSVerify: Bool,
		timeout: HTTPClient.Configuration.Timeout,
		redirectConfiguration: HTTPClient.Configuration.RedirectConfiguration,
		proxyURL: URL? = nil,
		gzip: Bool = false
	) {
		self.apiURL = apiURL
		self.namespace = namespace
		self.authentication = authentication
		self.trustRoots = trustRoots
		self.insecureSkipTLSVerify = insecureSkipTLSVerify
		self.timeout = timeout
		self.redirectConfiguration = redirectConfiguration
		self.proxyURL = proxyURL
		self.gzip = gzip
	}
}

extension KubernetesClientConfig {

	public static func from(
		kubeConfig: KubeConfig,
		context: String,
		timeout: HTTPClient.Configuration.Timeout? = nil,
		redirectConfiguration: HTTPClient.Configuration.RedirectConfiguration? = nil,
		logger: Logger?
	) throws -> KubernetesClientConfig? {
		let timeout = timeout ?? .init()
		let redirectConfiguration =
			redirectConfiguration ?? .follow(max: 5, allowCycles: false)

		return try forContext(
			kubeConfig: kubeConfig,
			context: context,
			logger: logger,
			timeout: timeout,
			redirectConfiguration: redirectConfiguration
		)
	}

	internal static func forContext(
		kubeConfig: KubeConfig,
		context: String,
		logger: Logger?,
		timeout: HTTPClient.Configuration.Timeout,
		redirectConfiguration: HTTPClient.Configuration.RedirectConfiguration
	) throws -> KubernetesClientConfig? {
		kubeToClientConfig(
			contextSelector: contextSelector(context: context),
			logger: logger,
			timeout: timeout,
			redirectConfiguration: redirectConfiguration
		)(kubeConfig)
	}

	internal static func contextSelector(context: String) -> (NamedContext, KubeConfig)
		-> Bool
	{
		{ namedContext, _ in
			namedContext.name == context
		}
	}

	internal static func kubeToClientConfig(
		contextSelector: @escaping (NamedContext, KubeConfig) -> Bool,
		logger: Logger?,
		timeout: HTTPClient.Configuration.Timeout,
		redirectConfiguration: HTTPClient.Configuration.RedirectConfiguration,
	) -> (KubeConfig) -> KubernetesClientConfig? {
		{ kubeConfig in
			guard
				let context = kubeConfig.contexts?.filter({
					contextSelector($0, kubeConfig)
				}).map(\.context).first
			else {
				return nil
			}

			guard
				let cluster = kubeConfig.clusters?.filter({
					$0.name == context.cluster
				}).map(\.cluster).first
			else {
				return nil
			}

			guard let apiURL = URL(string: cluster.server) else {
				return nil
			}

			guard
				let authInfo = kubeConfig.users?.filter({
					$0.name == context.user
				}).map(\.authInfo).first
			else {
				return nil
			}

			guard let authentication = authInfo.authentication(logger: logger)
			else {
				return nil
			}

			return KubernetesClientConfig(
				apiURL: apiURL,
				namespace: context.namespace ?? "default",
				authentication: authentication,
				trustRoots: cluster.trustRoots(logger: logger),
				insecureSkipTLSVerify: cluster.insecureSkipTLSVerify ?? false,
				timeout: timeout,
				redirectConfiguration: redirectConfiguration,
				proxyURL: cluster.proxyURL.flatMap { URL(string: $0) }
			)
		}
	}
}

private extension Cluster {

	func trustRoots(logger: Logger?) -> NIOSSLTrustRoots? {
		do {
			if let caFile = certificateAuthority {
				let certificates = try NIOSSLCertificate.fromPEMFile(caFile)
				return NIOSSLTrustRoots.certificates(certificates)
			}

			if let caData = certificateAuthorityData {
				let certificates = try NIOSSLCertificate.fromPEMBytes(
					[UInt8](caData)
				)
				return NIOSSLTrustRoots.certificates(certificates)
			}
		} catch {
			logger?.warning(
				"Error loading certificate authority for cluster \(server): \(error)"
			)
		}
		return nil
	}
}

public extension AuthInfo {

	func authentication(logger: Logger?)
		-> KubernetesClientAuthentication?
	{
		if let username = username, let password = password {
			return .basicAuth(username: username, password: password)
		}

		if let token = token {
			return .bearer(token: token)
		}

		do {
			if let tokenFile = tokenFile {
				let fileURL = URL(fileURLWithPath: tokenFile)
				let token = try String(contentsOf: fileURL, encoding: .utf8)
				return .bearer(token: token)
			}
		} catch {
			logger?.warning(
				"Error initializing authentication from token file \(String(describing: tokenFile)): \(error)"
			)
		}

		do {
			if let clientCertificateFile = clientCertificate,
			   let clientKeyFile = clientKey
			{
				let clientCertificate = try NIOSSLCertificate.fromPEMFile(clientCertificateFile)
				let clientKey = try NIOSSLPrivateKey(
					file: clientKeyFile,
					format: .pem
				)
				return .x509(
					clientCertificate: clientCertificate.first!, // fail fast is ok for our application
					clientKey: clientKey
				)
			}

			if let clientCertificateData = clientCertificateData,
			   let clientKeyData = clientKeyData
			{
				let clientCertificate = try NIOSSLCertificate(
					bytes: [UInt8](clientCertificateData),
					format: .pem
				)
				let clientKey = try NIOSSLPrivateKey(
					bytes: [UInt8](clientKeyData),
					format: .pem
				)
				return .x509(
					clientCertificate: clientCertificate,
					clientKey: clientKey
				)
			}
		} catch {
			logger?.warning(
				"Error initializing authentication from client certificate: \(error)"
			)
		}

		#if os(Linux) || os(macOS)
			do {
				if let exec {
					let outputData = try run(
						command: exec.command,
						arguments: exec.args
					)

					let decoder = JSONDecoder()
					decoder.dateDecodingStrategy = .iso8601
					let credential = try decoder.decode(
						ExecCredential.self,
						from: outputData
					)

					return .bearer(token: credential.status.token)
				}
			} catch {
				logger?.warning(
					"Error initializing authentication from exec \(error)"
				)
			}
		#endif
		return nil
	}
}

// MARK: - ExecCredential

// It seems that AWS doesn't implement properly the model for client.authentication.k8s.io/v1beta1
// Acordingly with the doc https://kubernetes.io/docs/reference/config-api/client-authentication.v1beta1/
// ExecCredential.Spec.interactive is required as long as the ones in the Status object.
public struct ExecCredential: Codable {
	let apiVersion: String
	let kind: String
	let spec: Spec
	let status: Status
}

public extension ExecCredential {
	struct Spec: Codable {
		let cluster: Cluster?
		let interactive: Bool?
	}

	struct Status: Codable {
		let expirationTimestamp: Date
		let token: String
		let clientCertificateData: String?
		let clientKeyData: String?
	}
}

#if os(Linux) || os(macOS)
	internal func run(command: String, arguments: [String]? = nil) throws
		-> Data
	{
		func run(_ command: String, _ arguments: [String]?) throws -> Data {
			let task = Process()
			task.executableURL = URL(fileURLWithPath: command)
			arguments.flatMap { task.arguments = $0 }

			let pipe = Pipe()
			task.standardOutput = pipe

			try task.run()

			return pipe.fileHandleForReading.availableData
		}

		func resolve(command: String) throws -> String {
			try String(
				decoding:
				run("/usr/bin/which", ["\(command)"]),
				as: UTF8.self
			).trimmingCharacters(in: .whitespacesAndNewlines)
		}

		return try run(resolve(command: command), arguments)
	}
#endif
