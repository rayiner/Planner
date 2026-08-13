import Foundation

@MainActor
protocol OutlineNode: AnyObject {
    var uuid: UUID { get }
    var title: String { get set }
    var sortIndex: Int64 { get set }
    var outlineChildren: [OutlineNode] { get }
    var outlineParent: OutlineNode? { get }
}
