//
//  Argo+RolloutList.swift
//  DriftDetector
//
//  Created by Peter van Rensburg on 8/29/25.
//

import Foundation
import SwiftkubeModel

// MARK: - argoproj.v1alpha1.RolloutList

extension argoproj.v1alpha1 {

  public struct RolloutList: KubernetesResource, KubernetesResourceList {
    public typealias Item = argoproj.v1alpha1.Rollout
    public let apiVersion: String = "argoproj.io/v1alpha1"
    public let kind: String = "RolloutList"
    public var metadata: meta.v1.ListMeta?
    public var items: [argoproj.v1alpha1.Rollout]

    public init(
      metadata: meta.v1.ListMeta? = nil,
      items: [argoproj.v1alpha1.Rollout]
    ) {
      self.metadata = metadata
      self.items = items
    }
  }
}

extension argoproj.v1alpha1.RolloutList {

  private enum CodingKeys: String, CodingKey {

    case apiVersion = "apiVersion"
    case kind = "kind"
    case metadata = "metadata"
    case items = "items"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.metadata = try container.decodeIfPresent(meta.v1.ListMeta.self, forKey: .metadata)
    self.items = try container.decode([argoproj.v1alpha1.Rollout].self, forKey: .items)
  }

  public func encode(to encoder: Encoder) throws {
    var encodingContainer = encoder.container(keyedBy: CodingKeys.self)

    try encodingContainer.encode(apiVersion, forKey: .apiVersion)
    try encodingContainer.encode(kind, forKey: .kind)
    try encodingContainer.encode(metadata, forKey: .metadata)
    try encodingContainer.encode(items, forKey: .items)
  }
}

// MARK: - argoproj.v1alpha1.RolloutList + Sequence

extension argoproj.v1alpha1.RolloutList: Sequence {

  public typealias Element = argoproj.v1alpha1.Rollout

  public func makeIterator() -> AnyIterator<argoproj.v1alpha1.Rollout> {
    AnyIterator(items.makeIterator())
  }
}
