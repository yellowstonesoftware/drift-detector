//
//  Rollout.swift
//  DriftDetector
//
//  Created by Peter van Rensburg on 8/29/25.
//

import SwiftkubeModel

public enum argoproj {}

extension argoproj {
  public enum v1alpha1 {}
}

extension argoproj.v1alpha1 {
  public struct Rollout: KubernetesAPIResource, MetadataHavingResource {
    public typealias List = argoproj.v1alpha1.RolloutList
    public let apiVersion: String = "argoproj.io/v1alpha1"
    public let kind: String = "Rollout"
    public var metadata: meta.v1.ObjectMeta?
    public var spec: argoproj.v1alpha1.RolloutSpec?
    public var status: argoproj.v1alpha1.RolloutStatus?

    public init(
      metadata: meta.v1.ObjectMeta? = nil,
      spec: argoproj.v1alpha1.RolloutSpec? = nil,
      status: argoproj.v1alpha1.RolloutStatus? = nil
    ) {
      self.metadata = metadata
      self.spec = spec
      self.status = status
    }
  }

}

extension argoproj.v1alpha1.Rollout {

  private enum CodingKeys: String, CodingKey {

    case apiVersion = "apiVersion"
    case kind = "kind"
    case metadata = "metadata"
    case spec = "spec"
    case status = "status"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.metadata = try container.decodeIfPresent(meta.v1.ObjectMeta.self, forKey: .metadata)
    self.spec = try container.decodeIfPresent(argoproj.v1alpha1.RolloutSpec.self, forKey: .spec)
    self.status = try container.decodeIfPresent(argoproj.v1alpha1.RolloutStatus.self, forKey: .status)
  }

  public func encode(to encoder: Encoder) throws {
    var encodingContainer = encoder.container(keyedBy: CodingKeys.self)

    try encodingContainer.encode(apiVersion, forKey: .apiVersion)
    try encodingContainer.encode(kind, forKey: .kind)
    try encodingContainer.encode(metadata, forKey: .metadata)
    try encodingContainer.encode(spec, forKey: .spec)
    try encodingContainer.encode(status, forKey: .status)
  }
}
