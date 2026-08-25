import Foundation

enum DesktopMCPSourceRegistry {
    static let ouroborosID = MCPSourceID(rawValue: "ouroboros")!


    static func make(
        ouroborosAdapter: MCPSourceAdapter,
        localDescriptors: [LocalMCPSourceDescriptor] = [],
        includeCatalogDemoFixture: Bool
    ) -> MCPSourceRegistry {
        let primary = MCPSourceRegistration(
            id: ouroborosID,
            displayName: "Ouroboros",
            factory: { ouroborosAdapter }
        )
        var registrations = [primary]
        registrations.append(contentsOf: localDescriptors.compactMap { descriptor in
            guard let sourceID = descriptor.sourceID else { return nil }
            return MCPSourceRegistration(
                id: sourceID,
                displayName: descriptor.displayName,
                descriptor: descriptor,
                factory: { DescriptorMCPAdapter(descriptor: descriptor) }
            )
        })
        if includeCatalogDemoFixture {
            registrations.append(MCPV2CatalogDemoFixture.registration())
        }
        // Future optional-source mistakes must not remove or reorder the
        // trusted primary source. Registry validation rejects ambiguity and
        // this bounded fallback retains Ouroboros alone.
        return (try? MCPSourceRegistry(registrations))
            ?? (try! MCPSourceRegistry([primary]))
    }
}
