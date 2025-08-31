//
//  Argo+RolloutSpec.swift
//  DriftDetector
//
//  Created by Peter van Rensburg on 8/29/25.
//

import Foundation
import SwiftkubeModel

// MARK: - argoproj.v1alpha1.RolloutSpec

extension argoproj.v1alpha1 {

  public struct RolloutSpec: KubernetesResource {
    public var replicas: Int32?
    public var template: core.v1.PodTemplateSpec

    public init(
      template: core.v1.PodTemplateSpec
    ) {
      self.template = template
    }
  }
}

extension argoproj.v1alpha1.RolloutSpec {

  private enum CodingKeys: String, CodingKey {
    case replicas = "replicas"
    case template = "template"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.replicas = try container.decodeIfPresent(Int32.self, forKey: .replicas)
    self.template = try container.decode(core.v1.PodTemplateSpec.self, forKey: .template)
  }

  public func encode(to encoder: Encoder) throws {
    var encodingContainer = encoder.container(keyedBy: CodingKeys.self)

    try encodingContainer.encode(replicas, forKey: .replicas)
    try encodingContainer.encode(template, forKey: .template)
  }
}
