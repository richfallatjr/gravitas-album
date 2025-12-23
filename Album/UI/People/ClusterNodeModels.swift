import Foundation

struct ClusterTreeNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case root
        case section
        case group
        case cluster
    }

    let id: String
    let kind: Kind
    let title: String
    let entry: FaceClusterDirectoryEntry?
    let faceIDs: [String]?
    var children: [ClusterTreeNode]?

    static func root(children: [ClusterTreeNode]) -> ClusterTreeNode {
        ClusterTreeNode(id: "people_root", kind: .root, title: "People", entry: nil, faceIDs: nil, children: children)
    }

    static func section(title: String, children: [ClusterTreeNode]) -> ClusterTreeNode {
        ClusterTreeNode(id: "people_section_\(title.lowercased())", kind: .section, title: title, entry: nil, faceIDs: nil, children: children)
    }

    static func group(id: String, title: String, faceIDs: [String], children: [ClusterTreeNode]) -> ClusterTreeNode {
        ClusterTreeNode(id: id, kind: .group, title: title, entry: nil, faceIDs: faceIDs, children: children)
    }

    static func cluster(entry: FaceClusterDirectoryEntry) -> ClusterTreeNode {
        ClusterTreeNode(id: "people_cluster_\(entry.faceID)", kind: .cluster, title: entry.displayName, entry: entry, faceIDs: [entry.faceID], children: nil)
    }
}
