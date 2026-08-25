#if OUROCODE_GHOSTTY_METAL_SURFACE
  import Foundation
  import Metal

  enum OuroTerminalMetalLibraryError: LocalizedError {
    case noMetalDevice
    case runtimeCompilationForbidden
    case sourcePathMissing
    case sourceUnreadable(String)
    case metallibMissing
    case libraryCreation(String)
    case functionMissing(String)
    case pipelineCreation(String)

    var errorDescription: String? {
      switch self {
      case .noMetalDevice:
        return "This Mac does not expose a Metal device."
      case .runtimeCompilationForbidden:
        return "Runtime Metal source compilation is forbidden outside a debug build."
      case .sourcePathMissing:
        return "Debug Metal compilation accepts only the SwiftPM-tracked terminal shader resource."
      case .sourceUnreadable(let message):
        return "The debug Metal source could not be read: \(message)"
      case .metallibMissing:
        return "The packaged OuroTerminal.metallib resource is missing."
      case .libraryCreation(let message):
        return "The terminal Metal library could not be created: \(message)"
      case .functionMissing(let name):
        return "The terminal Metal library is missing \(name)."
      case .pipelineCreation(let message):
        return "The terminal Metal pipeline could not be created: \(message)"
      }
    }
  }

  enum OuroTerminalMetalResourcesError: LocalizedError {
    case commandQueueUnavailable
    case samplerUnavailable

    var errorDescription: String? {
      switch self {
      case .commandQueueUnavailable:
        return "Metal could not create the shared terminal command queue."
      case .samplerUnavailable:
        return "Metal could not create the shared terminal sampler."
      }
    }
  }

  /// Process-wide immutable Metal objects shared by every visible terminal
  /// pane. Renderers retain their own scene and lease state, but never create
  /// a command queue, shader pipeline, or sampler per pane.
  final class OuroTerminalMetalResources {
    let device: MTLDevice
    let library: OuroTerminalMetalLibrary
    let commandQueue: MTLCommandQueue
    let sampler: MTLSamplerState

    init(device: MTLDevice, bundle: Bundle = .main, sourceURL: URL? = nil) throws {
      let library = try OuroTerminalMetalLibrary(
        device: device,
        bundle: bundle,
        sourceURL: sourceURL
      )
      guard let commandQueue = device.makeCommandQueue() else {
        throw OuroTerminalMetalResourcesError.commandQueueUnavailable
      }
      let samplerDescriptor = MTLSamplerDescriptor()
      samplerDescriptor.minFilter = .linear
      samplerDescriptor.magFilter = .linear
      samplerDescriptor.sAddressMode = .clampToEdge
      samplerDescriptor.tAddressMode = .clampToEdge
      guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
        throw OuroTerminalMetalResourcesError.samplerUnavailable
      }
      commandQueue.label = "Ourocode shared terminal command queue"
      self.device = device
      self.library = library
      self.commandQueue = commandQueue
      self.sampler = sampler
    }
  }

  /// The only policy boundary allowed to create a Metal shader library.
  /// Debug builds may opt into compiling the tracked source at runtime. A
  /// packaged build has no source fallback and fails closed without a metallib.
  final class OuroTerminalMetalLibrary {
    let library: MTLLibrary
    let cellPipeline: MTLRenderPipelineState

    init(device: MTLDevice, bundle: Bundle = .main, sourceURL: URL? = nil) throws {
      library = try Self.loadLibrary(device: device, bundle: bundle, sourceURL: sourceURL)

      guard let vertex = library.makeFunction(name: "ouro_terminal_vertex") else {
        throw OuroTerminalMetalLibraryError.functionMissing("ouro_terminal_vertex")
      }
      guard let fragment = library.makeFunction(name: "ouro_terminal_fragment") else {
        throw OuroTerminalMetalLibraryError.functionMissing("ouro_terminal_fragment")
      }

      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.label = "Ourocode terminal cells"
      descriptor.vertexFunction = vertex
      descriptor.fragmentFunction = fragment
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
      descriptor.colorAttachments[0].isBlendingEnabled = true
      descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
      descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
      descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
      descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
      do {
        cellPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
      } catch {
        throw OuroTerminalMetalLibraryError.pipelineCreation(error.localizedDescription)
      }
    }

    private static func loadLibrary(
      device: MTLDevice,
      bundle: Bundle,
      sourceURL: URL?
    ) throws -> MTLLibrary {
      #if OUROCODE_METAL_RUNTIME_SOURCE
        #if DEBUG
          let trackedURLs = [
            Bundle.main.url(forResource: "OuroTerminalShaders", withExtension: "metal"),
            OurocodeResourceBundle.shared.url(
              forResource: "OuroTerminalShaders",
              withExtension: "metal"
            ),
          ].compactMap { $0?.standardizedFileURL }
          guard let sourceURL,
            trackedURLs.contains(sourceURL.standardizedFileURL)
          else {
            throw OuroTerminalMetalLibraryError.sourcePathMissing
          }
          let trackedURL = sourceURL.standardizedFileURL
          let source: String
          do {
            source = try String(contentsOf: trackedURL, encoding: .utf8)
          } catch {
            throw OuroTerminalMetalLibraryError.sourceUnreadable(error.localizedDescription)
          }
          do {
            let options = MTLCompileOptions()
            options.languageVersion = .version3_0
            return try device.makeLibrary(source: source, options: options)
          } catch {
            throw OuroTerminalMetalLibraryError.libraryCreation(error.localizedDescription)
          }
        #else
          throw OuroTerminalMetalLibraryError.runtimeCompilationForbidden
        #endif
      #else
        guard let url = bundle.url(forResource: "OuroTerminal", withExtension: "metallib") else {
          throw OuroTerminalMetalLibraryError.metallibMissing
        }
        do {
          return try device.makeLibrary(URL: url)
        } catch {
          throw OuroTerminalMetalLibraryError.libraryCreation(error.localizedDescription)
        }
      #endif
    }
  }
#endif
